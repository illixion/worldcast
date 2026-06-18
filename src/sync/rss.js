import Parser from 'rss-parser';
import { readFile, stat } from 'node:fs/promises';
import { now } from '../db.js';
import { log } from '../util/log.js';
import { fileURLToPath, resolveEnclosureUrl } from '../util/local.js';
import { ensureCachedImage } from '../util/artwork-cache.js';

const parser = new Parser({
  customFields: {
    feed: [
      ['itunes:image', 'itunesImage', { keepArray: false }],
      ['itunes:author', 'itunesAuthor']
    ],
    item: [
      ['itunes:image', 'itunesImage'],
      ['itunes:duration', 'itunesDuration'],
      ['enclosure', 'enclosure']
    ]
  }
});

function parseItunesDuration(s) {
  if (!s) return null;
  if (typeof s === 'number') return s;
  s = String(s).trim();
  if (/^\d+$/.test(s)) return Number(s);
  const parts = s.split(':').map(Number);
  if (parts.some(isNaN)) return null;
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  return null;
}

function extractItemArtwork(item, feedArtworkUrl) {
  if (item.itunesImage) {
    if (typeof item.itunesImage === 'string') return item.itunesImage;
    if (item.itunesImage.href) return item.itunesImage.href;
    if (item.itunesImage.$ && item.itunesImage.$.href) return item.itunesImage.$.href;
  }
  if (item.image && item.image.url) return item.image.url;
  return feedArtworkUrl || null;
}

function extractFeedArtwork(feed) {
  if (feed.itunesImage) {
    if (typeof feed.itunesImage === 'string') return feed.itunesImage;
    if (feed.itunesImage.href) return feed.itunesImage.href;
    if (feed.itunesImage.$ && feed.itunesImage.$.href) return feed.itunesImage.$.href;
  }
  if (feed.image && feed.image.url) return feed.image.url;
  return null;
}

/**
 * Returns { xml, etag, lastModified, notModified } or throws.
 * Dispatches to HTTP or fs based on the feed URL scheme.
 */
async function loadFeedSource(feed) {
  if (feed.url.startsWith('file://')) {
    let filePath;
    try { filePath = fileURLToPath(feed.url); }
    catch { throw new Error(`malformed file URL: ${feed.url}`); }
    let st;
    try { st = await stat(filePath); }
    catch (e) {
      const err = new Error(`local feed file missing or unreadable: ${filePath} (${e.code})`);
      err.code = e.code;
      throw err;
    }
    const mtimeKey = String(st.mtimeMs);
    if (feed.last_modified === mtimeKey) return { notModified: true };
    const xml = await readFile(filePath, 'utf8');
    return { xml, etag: null, lastModified: mtimeKey, notModified: false };
  }

  const headers = { 'User-Agent': 'worldcast/0.1 (+podcast PWA)' };
  if (feed.last_etag) headers['If-None-Match'] = feed.last_etag;
  if (feed.last_modified) headers['If-Modified-Since'] = feed.last_modified;
  const res = await fetch(feed.url, { headers, redirect: 'follow' });
  if (res.status === 304) return { notModified: true };
  if (!res.ok) throw new Error(`HTTP ${res.status} fetching ${feed.url}`);
  const etag = res.headers.get('etag') || null;
  const lastModified = res.headers.get('last-modified') || null;
  const xml = await res.text();
  return { xml, etag, lastModified, notModified: false };
}

export async function syncFeedById(ctx, feedId) {
  const { db } = ctx;
  const feed = db.prepare('SELECT * FROM feeds WHERE id = ?').get(feedId);
  if (!feed) throw new Error('feed not found');

  const src = await loadFeedSource(feed);
  if (src.notModified) {
    db.prepare('UPDATE feeds SET last_synced_at = ? WHERE id = ?').run(now(), feedId);
    // Still try to fill in any artwork that's missing on disk (e.g. cache
    // was cleared) — won't re-download anything already present.
    await cacheArtworkForFeed(ctx, feedId);
    return { newEpisodeIds: [], notModified: true };
  }

  const parsed = await parser.parseString(src.xml);
  const feedArtwork = extractFeedArtwork(parsed);

  db.prepare(`
    UPDATE feeds
    SET title = COALESCE(?, title),
        author = COALESCE(?, author),
        description = COALESCE(?, description),
        artwork_url = COALESCE(?, artwork_url),
        last_etag = ?, last_modified = ?, last_synced_at = ?
    WHERE id = ?
  `).run(
    parsed.title || null,
    parsed.itunesAuthor || parsed.creator || null,
    parsed.description || null,
    feedArtwork,
    src.etag, src.lastModified, now(),
    feedId
  );

  const insert = db.prepare(`
    INSERT INTO episodes
      (feed_id, guid, title, description, audio_url, audio_length, audio_type,
       duration_seconds, pub_date, artwork_url, chapters_status, created_at)
    VALUES
      (@feed_id, @guid, @title, @description, @audio_url, @audio_length, @audio_type,
       @duration_seconds, @pub_date, @artwork_url, 'pending', @created_at)
    ON CONFLICT(feed_id, guid) DO NOTHING
  `);

  const newIds = [];
  let skipped = 0;
  const tx = db.transaction((items) => {
    for (const item of items) {
      const enc = item.enclosure || {};
      const audio_url = resolveEnclosureUrl(enc.url, feed.url);
      if (!audio_url) { skipped++; continue; }
      const guid = item.guid || item.id || audio_url;
      const pub = item.isoDate || item.pubDate;
      const pub_date = pub ? Date.parse(pub) : null;
      const row = {
        feed_id: feedId,
        guid,
        title: item.title || '(untitled)',
        description: item.contentSnippet || item.content || item.summary || null,
        audio_url,
        audio_length: enc.length ? Number(enc.length) : null,
        audio_type: enc.type || null,
        duration_seconds: parseItunesDuration(item.itunesDuration),
        pub_date: pub_date || null,
        artwork_url: extractItemArtwork(item, feedArtwork),
        created_at: now()
      };
      const info = insert.run(row);
      if (info.changes === 1) newIds.push(Number(info.lastInsertRowid));
    }
  });
  tx(parsed.items || []);

  await cacheArtworkForFeed(ctx, feedId);

  log.info(`feed ${feedId} (${parsed.title || feed.url}) → ${newIds.length} new of ${parsed.items?.length || 0}${skipped ? `, skipped ${skipped} (bad/outside-library URLs)` : ''}`);
  return { newEpisodeIds: newIds, notModified: false };
}

// Cache the feed's own artwork + every episode under it that's still missing
// a local copy. Episodes whose remote URL matches an already-cached URL
// (typically the feed-level fallback) reuse the existing file rather than
// re-downloading. Failures are non-fatal — we'll try again on the next sync.
async function cacheArtworkForFeed(ctx, feedId) {
  const { db, dataDir } = ctx;
  const f = db.prepare(
    'SELECT id, artwork_url, artwork_path, artwork_mime FROM feeds WHERE id = ?'
  ).get(feedId);
  if (!f) return;

  const byUrl = new Map();
  if (f.artwork_url) {
    const r = await ensureCachedImage({
      dataDir, kind: 'feed', id: f.id,
      remoteUrl: f.artwork_url, currentPath: f.artwork_path, currentMime: f.artwork_mime,
    });
    if (r) {
      if (r.changed) {
        db.prepare('UPDATE feeds SET artwork_path=?, artwork_mime=? WHERE id=?')
          .run(r.path, r.mime, f.id);
      }
      byUrl.set(f.artwork_url, { path: r.path, mime: r.mime });
    }
  }

  const eps = db.prepare(
    `SELECT id, artwork_url, artwork_path, artwork_mime
     FROM episodes
     WHERE feed_id = ? AND artwork_path IS NULL AND artwork_url IS NOT NULL`
  ).all(feedId);
  const epUpdate = db.prepare(
    'UPDATE episodes SET artwork_path=?, artwork_mime=? WHERE id=?'
  );
  for (const ep of eps) {
    let entry = byUrl.get(ep.artwork_url);
    if (!entry) {
      const r = await ensureCachedImage({
        dataDir, kind: 'episode', id: ep.id,
        remoteUrl: ep.artwork_url, currentPath: null, currentMime: null,
      });
      if (!r) continue;
      entry = { path: r.path, mime: r.mime };
      byUrl.set(ep.artwork_url, entry);
    }
    epUpdate.run(entry.path, entry.mime, ep.id);
  }
}

export async function syncAllFeeds(ctx) {
  const feeds = ctx.db.prepare('SELECT id, url FROM feeds').all();
  const allNew = [];
  for (const f of feeds) {
    try {
      const r = await syncFeedById(ctx, f.id);
      allNew.push(...r.newEpisodeIds);
    } catch (e) {
      log.warn(`feed ${f.id} sync failed: ${e.message}`);
    }
    if (!f.url.startsWith('file://')) {
      // polite jitter between HTTP fetches only
      await new Promise(r => setTimeout(r, 2000 + Math.random() * 3000));
    }
  }
  return allNew;
}

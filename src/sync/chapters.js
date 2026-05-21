import NodeID3 from 'node-id3';
import { writeFileSync, mkdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fetchId3TagBytes, extToMime } from '../util/id3.js';
import { safeFileUrlToPath } from '../util/local.js';
import { log } from '../util/log.js';

function pickTitle(t) {
  if (!t) return null;
  if (typeof t === 'string') return t;
  if (t.text) return t.text;
  return null;
}

/**
 * node-id3 returns chapters with shape:
 *   { elementID, startTimeMs, endTimeMs, startOffsetBytes, endOffsetBytes,
 *     tags: { title, userDefinedUrl?: [{...}], image?: { mime, type, description, imageBuffer } } }
 * Some versions place sub-frames slightly differently; we accept both
 * `tags.image` and `image` as fallbacks.
 */
function normalizeChapter(ch) {
  const tags = ch.tags || {};
  const title = pickTitle(tags.title) || pickTitle(ch.title) || null;
  const image = tags.image || ch.image || null;
  const url = (tags.userDefinedUrl && tags.userDefinedUrl[0] && tags.userDefinedUrl[0].url)
    || (tags.url && (tags.url.url || tags.url))
    || null;
  return {
    title,
    start_ms: Number(ch.startTimeMs) || 0,
    end_ms:   Number.isFinite(ch.endTimeMs) ? Number(ch.endTimeMs) : null,
    url,
    image
  };
}

export async function extractChaptersForEpisode(ctx, episodeId) {
  const { db, dataDir } = ctx;
  const ep = db.prepare('SELECT id, audio_url FROM episodes WHERE id = ?').get(episodeId);
  if (!ep) return;

  // Up-front existence check for file:// audio so a deleted/missing archive
  // gets flagged as unavailable instead of just chapter-errored.
  if (ep.audio_url && ep.audio_url.startsWith('file://')) {
    const p = safeFileUrlToPath(ep.audio_url);
    if (!p) {
      db.prepare(`UPDATE episodes SET audio_available=0, chapters_status='error', chapters_error=? WHERE id=?`)
        .run('outside library', episodeId);
      return;
    }
    let st;
    try { st = statSync(p); }
    catch (e) {
      if (e.code === 'ENOENT') {
        db.prepare(`UPDATE episodes SET audio_available=0, chapters_status='error', chapters_error=? WHERE id=?`)
          .run('audio file missing', episodeId);
        return;
      }
      // Other fs error — surface it but don't flip availability.
      db.prepare(`UPDATE episodes SET chapters_status='error', chapters_error=? WHERE id=?`)
        .run(`stat: ${e.message}`, episodeId);
      return;
    }
    if (!st.isFile()) {
      log.warn(`chapter extract ep ${episodeId}: audio path is not a regular file: ${p}`);
      db.prepare(`UPDATE episodes SET audio_available=0, chapters_status='error', chapters_error=? WHERE id=?`)
        .run('audio path is not a regular file', episodeId);
      return;
    }
    // File is here — make sure availability flag is on.
    db.prepare(`UPDATE episodes SET audio_available=1 WHERE id=? AND audio_available=0`).run(episodeId);
  }

  try {
    const fetched = await fetchId3TagBytes(ep.audio_url);
    if (!fetched) {
      db.prepare(`UPDATE episodes SET chapters_status='error', chapters_error=? WHERE id=?`)
        .run('fetch failed', episodeId);
      return;
    }
    if (!fetched.hasTag) {
      db.prepare(`UPDATE episodes SET chapters_status='none', chapters_error=NULL WHERE id=?`)
        .run(episodeId);
      return;
    }

    const tags = NodeID3.read(fetched.buffer);
    const rawChapters = Array.isArray(tags.chapter) ? tags.chapter : [];
    if (rawChapters.length === 0) {
      db.prepare(`UPDATE episodes SET chapters_status='none', chapters_error=NULL WHERE id=?`)
        .run(episodeId);
      return;
    }

    const sorted = rawChapters
      .map(normalizeChapter)
      .sort((a, b) => a.start_ms - b.start_ms);

    const epDir = join(dataDir, 'artwork', String(episodeId));
    mkdirSync(epDir, { recursive: true });

    const insert = db.prepare(`
      INSERT INTO chapters (episode_id, ordinal, title, start_ms, end_ms, url, artwork_path, artwork_mime)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    const wipe = db.prepare(`DELETE FROM chapters WHERE episode_id = ?`);
    const mark = db.prepare(`UPDATE episodes SET chapters_status='done', chapters_error=NULL WHERE id=?`);

    const tx = db.transaction(() => {
      wipe.run(episodeId);
      sorted.forEach((ch, idx) => {
        let artPath = null;
        let artMime = null;
        if (ch.image && ch.image.imageBuffer && ch.image.imageBuffer.length > 0) {
          const mime = ch.image.mime || 'image/jpeg';
          const ext = extToMime(mime);
          const rel = join(String(episodeId), `${idx}.${ext}`);
          const abs = join(dataDir, 'artwork', rel);
          writeFileSync(abs, ch.image.imageBuffer);
          artPath = rel;
          artMime = mime;
        }
        insert.run(episodeId, idx, ch.title, ch.start_ms, ch.end_ms, ch.url, artPath, artMime);
      });
      mark.run(episodeId);
    });
    tx();
    log.info(`chapters ep ${episodeId}: ${sorted.length} chapter(s)`);
  } catch (e) {
    log.warn(`chapter extract ep ${episodeId} failed: ${e.message} (audio_url=${ep.audio_url})`);
    db.prepare(`UPDATE episodes SET chapters_status='error', chapters_error=? WHERE id=?`)
      .run(e.message || String(e), episodeId);
  }
}

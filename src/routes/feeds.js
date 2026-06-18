import { syncFeedById } from '../sync/rss.js';
import { enqueueExtraction } from '../sync/scheduler.js';
import { now } from '../db.js';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { log } from '../util/log.js';

// Rewrite a feed row so the client never sees the remote artwork URL: drop
// it and substitute the cached server-relative path. Returns null when the
// image hasn't been cached yet so the client falls back to its local icon.
function privatizeFeed(f) {
  if (!f) return f;
  f.artwork_url = f.artwork_path ? `artwork/feed/${f.id}` : null;
  delete f.artwork_path;
  delete f.artwork_mime;
  return f;
}

export function mountFeedRoutes(api, { db, dataDir }) {
  api.get('/feeds', (req, res) => {
    const rows = db.prepare(`
      SELECT f.*,
        (SELECT COUNT(*) FROM episodes e WHERE e.feed_id = f.id) AS episode_count,
        (SELECT COUNT(*) FROM episodes e WHERE e.feed_id = f.id AND e.played = 0) AS unplayed_count
      FROM feeds f
      ORDER BY LOWER(f.title) ASC
    `).all();
    for (const r of rows) privatizeFeed(r);
    res.json({ feeds: rows });
  });

  api.post('/feeds', async (req, res) => {
    const url = (req.body && req.body.url || '').trim();
    if (!url || !/^https?:\/\//i.test(url)) {
      return res.status(400).json({ error: 'invalid url' });
    }
    const existing = db.prepare('SELECT * FROM feeds WHERE url = ?').get(url);
    if (existing) return res.status(409).json({ error: 'already subscribed', feed: existing });

    const info = db.prepare('INSERT INTO feeds (url, created_at) VALUES (?, ?)')
      .run(url, now());
    const id = info.lastInsertRowid;
    try {
      const result = await syncFeedById({ db, dataDir }, id);
      for (const epId of result.newEpisodeIds) enqueueExtraction(epId);
      const feed = db.prepare('SELECT * FROM feeds WHERE id = ?').get(id);
      res.status(201).json({ feed: privatizeFeed(feed), newEpisodes: result.newEpisodeIds.length });
    } catch (e) {
      log.error('initial sync failed', e);
      db.prepare('DELETE FROM feeds WHERE id = ?').run(id);
      res.status(502).json({ error: 'feed fetch failed: ' + (e.message || String(e)) });
    }
  });

  api.delete('/feeds/:id', (req, res) => {
    const id = Number(req.params.id);
    // Collect cached artwork files to delete BEFORE the DELETE so we still
    // know which episodes belonged to the feed.
    const epRows = db.prepare(
      'SELECT id, artwork_path FROM episodes WHERE feed_id = ?'
    ).all(id);
    const feedRow = db.prepare(
      'SELECT artwork_path FROM feeds WHERE id = ?'
    ).get(id);

    const ok = db.prepare('DELETE FROM feeds WHERE id = ?').run(id);

    const rm = (p) => { if (p) { try { rmSync(p, { recursive: true, force: true }); } catch {} } };
    if (feedRow && feedRow.artwork_path) rm(join(dataDir, 'artwork', feedRow.artwork_path));
    for (const ep of epRows) {
      if (ep.artwork_path) rm(join(dataDir, 'artwork', ep.artwork_path));
      // Per-chapter APIC dump dir keyed by episode id.
      rm(join(dataDir, 'artwork', String(ep.id)));
    }
    res.json({ deleted: ok.changes });
  });

  api.post('/feeds/:id/sync', async (req, res) => {
    const id = Number(req.params.id);
    try {
      const result = await syncFeedById({ db, dataDir }, id);
      for (const epId of result.newEpisodeIds) enqueueExtraction(epId);
      res.json({ ok: true, newEpisodes: result.newEpisodeIds.length, notModified: result.notModified });
    } catch (e) {
      res.status(502).json({ error: e.message || String(e) });
    }
  });
}

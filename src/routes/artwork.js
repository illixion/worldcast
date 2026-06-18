import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

// All artwork — chapter, episode, and feed — is served from the local cache
// under dataDir/artwork. The client never sees the upstream URL, so the
// podcast CDN can't track when (or whether) the user views any episode.
export function mountArtworkRoutes(router, { db, dataDir }) {
  const artworkRoot = resolve(dataDir, 'artwork');

  function send(res, relPath, mime) {
    if (!relPath) return res.status(404).end();
    const abs = resolve(artworkRoot, relPath);
    if (!abs.startsWith(artworkRoot)) return res.status(400).end();
    if (!existsSync(abs)) return res.status(404).end();
    res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
    if (mime) res.type(mime);
    res.sendFile(abs);
  }

  router.get('/chapter/:id', (req, res) => {
    const row = db.prepare(
      'SELECT artwork_path, artwork_mime FROM chapters WHERE id = ?'
    ).get(Number(req.params.id));
    if (!row) return res.status(404).end();
    send(res, row.artwork_path, row.artwork_mime);
  });

  router.get('/feed/:id', (req, res) => {
    const row = db.prepare(
      'SELECT artwork_path, artwork_mime FROM feeds WHERE id = ?'
    ).get(Number(req.params.id));
    if (!row) return res.status(404).end();
    send(res, row.artwork_path, row.artwork_mime);
  });

  router.get('/episode/:id', (req, res) => {
    const row = db.prepare(
      `SELECT
         COALESCE(e.artwork_path, f.artwork_path) AS artwork_path,
         COALESCE(e.artwork_mime, f.artwork_mime) AS artwork_mime
       FROM episodes e JOIN feeds f ON f.id = e.feed_id
       WHERE e.id = ?`
    ).get(Number(req.params.id));
    if (!row) return res.status(404).end();
    send(res, row.artwork_path, row.artwork_mime);
  });
}

import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

export function mountArtworkRoutes(router, { db, dataDir }) {
  router.get('/chapter/:id', (req, res) => {
    const id = Number(req.params.id);
    const row = db.prepare('SELECT artwork_path, artwork_mime FROM chapters WHERE id = ?').get(id);
    if (!row || !row.artwork_path) return res.status(404).end();
    const abs = resolve(dataDir, 'artwork', row.artwork_path);
    if (!abs.startsWith(resolve(dataDir, 'artwork'))) return res.status(400).end();
    if (!existsSync(abs)) return res.status(404).end();
    res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
    if (row.artwork_mime) res.type(row.artwork_mime);
    res.sendFile(abs);
  });
}

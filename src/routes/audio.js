import { createReadStream, statSync } from 'node:fs';
import { extname } from 'node:path';
import { safeFileUrlToPath } from '../util/local.js';

const EXT_MIME = {
  '.mp3':  'audio/mpeg',
  '.m4a':  'audio/mp4',
  '.m4b':  'audio/mp4',
  '.aac':  'audio/aac',
  '.ogg':  'audio/ogg',
  '.oga':  'audio/ogg',
  '.opus': 'audio/ogg',
  '.flac': 'audio/flac',
  '.wav':  'audio/wav',
  '.m4v':  'video/mp4',
  '.mov':  'video/quicktime',
  '.webm': 'video/webm'
};

// .mp4 is intentionally absent — the container is ambiguous (audio-only or
// video). Trust the feed-declared MIME when present; fall back to video/mp4
// since that's the common case for podcasts that ship .mp4 enclosures.
function guessMime(p, fallback) {
  const m = EXT_MIME[extname(p).toLowerCase()];
  if (m) return m;
  if (fallback) return fallback;
  if (extname(p).toLowerCase() === '.mp4') return 'video/mp4';
  return 'application/octet-stream';
}

export function mountAudioRoutes(api, { db }) {
  // Streams a local audio file for an episode whose audio_url is file://.
  // The browser cannot load file:// directly, so the PWA points <audio src>
  // at this route; same-origin cookie auth handles credentials.
  api.get('/audio/:id', (req, res) => {
    const id = Number(req.params.id);
    const ep = db.prepare('SELECT audio_url, audio_type FROM episodes WHERE id = ?').get(id);
    if (!ep) return res.status(404).end();
    if (!ep.audio_url || !ep.audio_url.startsWith('file://')) {
      return res.status(400).json({ error: 'episode audio is not local' });
    }
    const path = safeFileUrlToPath(ep.audio_url);
    if (!path) return res.status(403).json({ error: 'audio outside library' });

    let st;
    try { st = statSync(path); }
    catch {
      db.prepare(`UPDATE episodes SET audio_available=0 WHERE id=?`).run(id);
      return res.status(404).end();
    }
    if (!st.isFile()) {
      db.prepare(`UPDATE episodes SET audio_available=0 WHERE id=?`).run(id);
      return res.status(404).end();
    }

    const total = st.size;
    const mime = guessMime(path, ep.audio_type);
    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Content-Type', mime);
    res.setHeader('Cache-Control', 'private, max-age=0');

    const range = req.headers.range;
    if (!range) {
      res.setHeader('Content-Length', String(total));
      if (req.method === 'HEAD') return res.end();
      createReadStream(path).pipe(res);
      return;
    }
    // Single-range only — Safari/iOS never asks for multi-range.
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) { res.status(416).setHeader('Content-Range', `bytes */${total}`); return res.end(); }
    let start = m[1] === '' ? null : parseInt(m[1], 10);
    let end   = m[2] === '' ? null : parseInt(m[2], 10);
    if (start == null && end != null) { start = Math.max(0, total - end); end = total - 1; }
    if (start == null) start = 0;
    if (end == null)   end   = total - 1;
    if (start > end || start >= total) {
      res.status(416).setHeader('Content-Range', `bytes */${total}`);
      return res.end();
    }
    end = Math.min(end, total - 1);
    res.status(206);
    res.setHeader('Content-Range', `bytes ${start}-${end}/${total}`);
    res.setHeader('Content-Length', String(end - start + 1));
    if (req.method === 'HEAD') return res.end();
    createReadStream(path, { start, end }).pipe(res);
  });
}

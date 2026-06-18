import { now } from '../db.js';
import { enqueueExtraction } from '../sync/scheduler.js';

function safeParse(s) { try { return JSON.parse(s); } catch { return null; } }

function readJsonBody(req) {
  if (typeof req.body === 'string') return safeParse(req.body) || {};
  return req.body || {};
}

// Browsers refuse to load file:// from a page served over http(s), so any
// local-library episode's audio_url has to be served back to the client as a
// proxied route. The path is relative so it composes with <base href="./">.
function publicAudioUrl(ep) {
  if (ep && ep.audio_url && ep.audio_url.startsWith('file://')) {
    return `api/audio/${ep.id}`;
  }
  return ep ? ep.audio_url : null;
}

// True when the enclosure is a video container (mp4/m4v/mov/webm). Trusts the
// feed-declared MIME first; only falls back to extension sniffing of the
// original URL when audio_type is missing. The .mp4 extension is *not*
// authoritative on its own — some podcasts ship audio-only as .mp4.
function isVideoEpisode(ep) {
  if (!ep) return false;
  const t = (ep.audio_type || '').toLowerCase();
  if (t.startsWith('video/')) return true;
  if (t.startsWith('audio/')) return false;
  const url = (ep.audio_url || '').toLowerCase();
  return /\.(m4v|mov|webm)(\?|#|$)/.test(url);
}

// Replace remote artwork URLs with our server-relative cached paths. The
// client never sees the upstream URL, so the podcast host can't observe
// when/whether the user views any episode. Returns null if the image hasn't
// been cached yet (the client already falls back to a bundled icon).
function privatizeArtwork(ep) {
  // Episode-level art: cached when artwork_path is set; otherwise fall back
  // to the feed-level art (which the /artwork/episode/:id route mirrors).
  const epHasOwn = ep.artwork_path != null;
  const feedHasOwn = ep.feed_artwork_path != null;
  ep.artwork_url = (epHasOwn || feedHasOwn) ? `artwork/episode/${ep.id}` : null;
  ep.feed_artwork_url = feedHasOwn ? `artwork/feed/${ep.feed_id}` : null;
  delete ep.artwork_path;
  delete ep.artwork_mime;
  delete ep.feed_artwork_path;
}

// Decorate a DB row for the client: virtualize audio_url and stamp is_video.
function decorate(ep) {
  if (!ep) return ep;
  ep.is_video = isVideoEpisode(ep) ? 1 : 0;
  ep.audio_url = publicAudioUrl(ep);
  privatizeArtwork(ep);
  return ep;
}

export function mountEpisodeRoutes(api, { db }) {
  api.get('/episodes', (req, res) => {
    const feed = req.query.feed ? Number(req.query.feed) : null;
    const unplayed = req.query.unplayed === '1';
    const limit = Math.min(200, Math.max(1, parseInt(req.query.limit || '50', 10)));
    const before = req.query.before ? Number(req.query.before) : null;

    const conds = [];
    const params = [];
    if (feed != null) { conds.push('e.feed_id = ?'); params.push(feed); }
    if (unplayed)     { conds.push('e.played = 0'); }
    if (before != null) { conds.push('e.pub_date < ?'); params.push(before); }
    const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';

    const rows = db.prepare(`
      SELECT
        e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.audio_type,
        e.duration_seconds, e.pub_date, e.artwork_url, e.artwork_path,
        e.chapters_status, e.audio_available, e.position_seconds, e.played, e.played_at,
        f.title AS feed_title, f.artwork_url AS feed_artwork_url, f.artwork_path AS feed_artwork_path, f.artwork_path AS feed_artwork_path,
        (SELECT COUNT(*) FROM chapters c WHERE c.episode_id = e.id) AS chapter_count
      FROM episodes e
      JOIN feeds f ON f.id = e.feed_id
      ${where}
      ORDER BY e.pub_date DESC, e.id DESC
      LIMIT ?
    `).all(...params, limit);

    for (const r of rows) decorate(r);
    res.json({ episodes: rows });
  });

  // Recently played: anything with a last_played_at timestamp, newest first.
  // Registered before /episodes/:id so "recent" isn't captured as an id.
  api.get('/episodes/recent', (req, res) => {
    const limit = Math.min(50, Math.max(1, parseInt(req.query.limit || '3', 10)));
    const rows = db.prepare(`
      SELECT
        e.id, e.feed_id, e.title, e.audio_url, e.audio_type, e.duration_seconds, e.pub_date,
        e.artwork_url, e.artwork_path, e.audio_available, e.position_seconds, e.played, e.last_played_at,
        f.title AS feed_title, f.artwork_url AS feed_artwork_url, f.artwork_path AS feed_artwork_path,
        (SELECT COUNT(*) FROM chapters c WHERE c.episode_id = e.id) AS chapter_count
      FROM episodes e
      JOIN feeds f ON f.id = e.feed_id
      WHERE e.last_played_at IS NOT NULL
      ORDER BY e.last_played_at DESC
      LIMIT ?
    `).all(limit);
    for (const r of rows) decorate(r);
    res.json({ episodes: rows });
  });

  // Single random never-started episode (played=0 AND last_played_at IS NULL).
  api.get('/episodes/random-unplayed', (req, res) => {
    const row = db.prepare(`
      SELECT
        e.id, e.feed_id, e.title, e.audio_url, e.audio_type, e.duration_seconds, e.pub_date,
        e.artwork_url, e.artwork_path, e.audio_available,
        f.title AS feed_title, f.artwork_url AS feed_artwork_url, f.artwork_path AS feed_artwork_path
      FROM episodes e
      JOIN feeds f ON f.id = e.feed_id
      WHERE e.played = 0
        AND e.last_played_at IS NULL
        AND e.audio_available = 1
      ORDER BY RANDOM()
      LIMIT 1
    `).get();
    if (!row) return res.json({ episode: null });
    decorate(row);
    res.json({ episode: row });
  });

  api.get('/episodes/:id', (req, res) => {
    const id = Number(req.params.id);
    const episode = db.prepare(`
      SELECT
        e.*,
        f.title AS feed_title, f.artwork_url AS feed_artwork_url, f.artwork_path AS feed_artwork_path
      FROM episodes e JOIN feeds f ON f.id = e.feed_id
      WHERE e.id = ?
    `).get(id);
    if (!episode) return res.status(404).json({ error: 'not found' });
    decorate(episode);

    const chapters = db.prepare(`
      SELECT id, ordinal, title, start_ms, end_ms, url, artwork_mime,
             CASE WHEN artwork_path IS NOT NULL THEN 'artwork/chapter/' || id ELSE NULL END AS artwork_url
      FROM chapters WHERE episode_id = ? ORDER BY ordinal ASC
    `).all(id);
    res.json({ episode, chapters });
  });

  api.post('/episodes/:id/position', (req, res) => {
    const id = Number(req.params.id);
    const body = readJsonBody(req);
    const pos = Number(body.position);
    if (!Number.isFinite(pos) || pos < 0) return res.status(400).json({ error: 'invalid position' });
    // Client clock (epoch ms) when this position was observed. Optional for
    // backward compat; when present it orders writes across devices/beacons.
    const clientTs = Number(body.client_ts);
    const hasTs = Number.isFinite(clientTs) && clientTs > 0;
    const ep = db.prepare('SELECT id, duration_seconds, played, position_seconds, position_client_ts FROM episodes WHERE id = ?').get(id);
    if (!ep) return res.status(404).json({ error: 'not found' });
    // Reject stale/out-of-order writes: a beacon that was observed strictly
    // before the position we already have (e.g. device A's backgrounding
    // beacon arriving after device B advanced past it) must not clobber. Equal
    // timestamps fall through to last-write-wins, which is harmless.
    if (hasTs && ep.position_client_ts != null && clientTs < ep.position_client_ts) {
      return res.json({ ok: true, position: ep.position_seconds, stale: true });
    }
    const dur = ep.duration_seconds || 0;
    const clamped = dur > 0 ? Math.min(pos, dur + 5) : pos;
    db.prepare('UPDATE episodes SET position_seconds = ?, last_played_at = ?, position_client_ts = ? WHERE id = ?')
      .run(clamped, now(), hasTs ? clientTs : ep.position_client_ts, id);
    res.json({ ok: true, position: clamped });
  });

  api.post('/episodes/:id/played', (req, res) => {
    const id = Number(req.params.id);
    const body = readJsonBody(req);
    const played = body.played ? 1 : 0;
    const t = played ? now() : null;
    const info = db.prepare(`
      UPDATE episodes
      SET played = ?, played_at = ?,
          position_seconds = CASE WHEN ? = 1 THEN 0 ELSE position_seconds END
      WHERE id = ?
    `).run(played, t, played, id);
    if (info.changes === 0) return res.status(404).json({ error: 'not found' });
    res.json({ ok: true });
  });

  // Next playable episode in the same feed, ordered chronologically forward
  // (next-newer). Skips unavailable and already-played episodes — used by
  // the player to auto-advance on `ended`.
  api.get('/episodes/:id/next', (req, res) => {
    const id = Number(req.params.id);
    const cur = db.prepare('SELECT feed_id, pub_date FROM episodes WHERE id = ?').get(id);
    if (!cur) return res.status(404).json({ error: 'not found' });
    const next = db.prepare(`
      SELECT id FROM episodes
      WHERE feed_id = ?
        AND audio_available = 1
        AND played = 0
        AND id <> ?
        AND (pub_date IS NULL OR pub_date > COALESCE(?, 0))
      ORDER BY pub_date ASC, id ASC
      LIMIT 1
    `).get(cur.feed_id, id, cur.pub_date);
    res.json({ next: next ? next.id : null });
  });

  api.post('/episodes/:id/rechapter', (req, res) => {
    const id = Number(req.params.id);
    const ep = db.prepare('SELECT id FROM episodes WHERE id = ?').get(id);
    if (!ep) return res.status(404).json({ error: 'not found' });
    db.prepare('DELETE FROM chapters WHERE episode_id = ?').run(id);
    db.prepare('UPDATE episodes SET chapters_status = ?, chapters_error = NULL WHERE id = ?').run('pending', id);
    enqueueExtraction(id);
    res.json({ ok: true });
  });
}

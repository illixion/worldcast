import { setLoginCookie, clearLoginCookie, COOKIE_NAME } from '../auth.js';

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function providedToken(req) {
  const auth = req.headers['authorization'];
  if (auth && auth.startsWith('Bearer ')) return auth.slice(7).trim();
  return parseCookies(req.headers['cookie'])[COOKIE_NAME] || null;
}

export function mountAuthRoutes(router, { token, cookiePath }) {
  router.post('/api/login', (req, res) => {
    const body = typeof req.body === 'string' ? safeParse(req.body) : (req.body || {});
    const provided = body && body.token;
    if (provided !== token) return res.status(401).json({ error: 'invalid token' });
    setLoginCookie(res, token, cookiePath);
    res.json({ ok: true });
  });

  router.post('/api/logout', (req, res) => {
    clearLoginCookie(res, cookiePath);
    res.json({ ok: true });
  });

  router.get('/api/whoami', (req, res) => {
    res.json({ authenticated: providedToken(req) === token });
  });
}

function safeParse(s) { try { return JSON.parse(s); } catch { return null; } }

const COOKIE_NAME = 'pcast_token';

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

function getProvidedToken(req) {
  const auth = req.headers['authorization'];
  if (auth && auth.startsWith('Bearer ')) return auth.slice(7).trim();
  const cookies = parseCookies(req.headers['cookie']);
  return cookies[COOKIE_NAME] || null;
}

export function makeAuthMiddleware(expectedToken) {
  return (req, res, next) => {
    const t = getProvidedToken(req);
    if (t && t === expectedToken) return next();
    res.status(401).json({ error: 'unauthorized' });
  };
}

export function setLoginCookie(res, token, path = '/') {
  const year = 60 * 60 * 24 * 365;
  res.setHeader('Set-Cookie',
    `${COOKIE_NAME}=${encodeURIComponent(token)}; Max-Age=${year}; Path=${path}; SameSite=Strict`);
}

export function clearLoginCookie(res, path = '/') {
  res.setHeader('Set-Cookie', `${COOKIE_NAME}=; Max-Age=0; Path=${path}; SameSite=Strict`);
}

export { COOKIE_NAME };

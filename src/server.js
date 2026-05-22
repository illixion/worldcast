import 'dotenv/config';
import express from 'express';
import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { openDb } from './db.js';
import { log } from './util/log.js';
import { setLibraryRoot, getLibraryRoot } from './util/local.js';
import { mountFeedRoutes } from './routes/feeds.js';
import { mountEpisodeRoutes } from './routes/episodes.js';
import { mountSyncRoutes } from './routes/sync.js';
import { mountArtworkRoutes } from './routes/artwork.js';
import { mountAudioRoutes } from './routes/audio.js';
import { startScheduler } from './sync/scheduler.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

const PORT = parseInt(process.env.PORT || '8080', 10);
const TOKEN = process.env.PCAST_TOKEN;
const DATA_DIR = resolve(ROOT, process.env.DATA_DIR || './data');
const SYNC_INTERVAL_MS = parseInt(process.env.SYNC_INTERVAL_MS || `${60 * 60 * 1000}`, 10);

const BASE_PATH = (process.env.BASE_PATH || '').replace(/\/+$/, '');
if (BASE_PATH && !/^\/[A-Za-z0-9._~\-/]+$/.test(BASE_PATH)) {
  log.error(`Invalid BASE_PATH: ${JSON.stringify(BASE_PATH)}`);
  process.exit(1);
}
// The whole app mounts under <BASE_PATH>/<TOKEN>/. The token IS the access
// control — any request whose path doesn't begin with the right token gets
// a 404. No cookies, no login page, no session: the URL is the secret.
// Tradeoff: anyone with the URL has full access; treat it like a bearer
// token and only share over trusted transport (Tailscale serve here).
// The home-screen PWA install bakes this URL into start_url, so cold launches
// after iOS Safari backgrounding always re-enter with the token intact.

// Local library: any *.xml file under here is auto-imported as a feed at
// every sync, and file:// audio URLs inside those feeds are allowed if they
// resolve under this directory. Default is ./data/library, auto-created.
const LOCAL_LIBRARY_DIR = process.env.LOCAL_LIBRARY_DIR === ''
  ? null
  : resolve(ROOT, process.env.LOCAL_LIBRARY_DIR || './data/library');

if (!TOKEN || TOKEN.length < 8) {
  log.error('PCAST_TOKEN must be set in environment (at least 8 chars). See .env.example');
  process.exit(1);
}
// Token doubles as a URL path segment — restrict to URL-safe characters so
// we don't have to worry about percent-encoding / mismatched normalization
// between client and server.
if (!/^[A-Za-z0-9._~-]+$/.test(TOKEN)) {
  log.error('PCAST_TOKEN must contain only URL-safe characters [A-Za-z0-9._~-]');
  process.exit(1);
}
const TOKEN_PREFIX = `${BASE_PATH}/${TOKEN}`;

mkdirSync(DATA_DIR, { recursive: true });
mkdirSync(join(DATA_DIR, 'artwork'), { recursive: true });
if (LOCAL_LIBRARY_DIR) {
  mkdirSync(LOCAL_LIBRARY_DIR, { recursive: true });
  setLibraryRoot(LOCAL_LIBRARY_DIR);
  log.info(`local library: ${LOCAL_LIBRARY_DIR}`);
}

const db = openDb(join(DATA_DIR, 'pcast.db'));
log.info(`db open at ${join(DATA_DIR, 'pcast.db')}`);

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '1mb' }));
app.use(express.text({ type: ['text/plain', 'application/octet-stream'], limit: '64kb' }));

const root = express.Router();

root.use(express.static(join(ROOT, 'public'), {
  index: false,
  setHeaders(res, p) {
    if (p.endsWith('.webmanifest')) res.type('application/manifest+json');
    if (p.endsWith('sw.js')) res.setHeader('Cache-Control', 'no-cache');
  }
}));

root.get('/', (req, res) => res.sendFile(join(ROOT, 'public', 'index.html')));

const ctx = { db, dataDir: DATA_DIR };

const api = express.Router();
mountFeedRoutes(api, ctx);
mountEpisodeRoutes(api, ctx);
mountSyncRoutes(api, ctx);
mountAudioRoutes(api, ctx);
root.use('/api', api);

const artwork = express.Router();
mountArtworkRoutes(artwork, ctx);
root.use('/artwork', artwork);

root.use('/api', (req, res) => res.status(404).json({ error: 'not found' }));

// Path-gate: only requests under <BASE_PATH>/<TOKEN>/ reach the app router.
// Anything else (wrong token, bare /, scanners) gets a flat 404.
app.use(TOKEN_PREFIX, root);
app.use((req, res) => res.status(404).send('not found'));

app.use((err, req, res, _next) => {
  log.error('unhandled', err);
  if (res.headersSent) return;
  res.status(500).json({ error: err.message || 'server error' });
});

const server = app.listen(PORT, () => {
  log.info(`listening on http://localhost:${PORT}${TOKEN_PREFIX}/`);
  if (BASE_PATH) {
    log.info(`tailscale: tailscale serve --bg --https=443 --set-path=${BASE_PATH} http://localhost:${PORT}${BASE_PATH}`);
  } else {
    log.info(`tailscale: tailscale serve --bg --https=443 http://localhost:${PORT}`);
  }
});

startScheduler({ db, dataDir: DATA_DIR, intervalMs: SYNC_INTERVAL_MS });

function shutdown(sig) {
  log.info(`${sig} → closing`);
  server.close(() => { db.close(); process.exit(0); });
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

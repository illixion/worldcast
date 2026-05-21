# CLAUDE.md

Quick orientation for Claude working in this repo. README is for humans; this
file flags the non-obvious stuff. Read it before editing.

## What this is

Single-user, Safari-installable PWA podcast listener with a small Node/Express
backend. Designed to run behind Tailscale serve on a home server. The
load-bearing pieces:

- **Hourly RSS sync** of HTTP feeds + a local-library mode that auto-imports
  XML files dropped into `./data/library/`.
- **ID3 CHAP/APIC chapter extraction** — server-side, Range-fetched from HTTP
  audio or read via `fs` from `file://` audio. Per-chapter artwork stored at
  `data/artwork/<episode_id>/<ordinal>.<ext>`.
- **MediaSession-driven lockscreen** — chapter boundary crossings rewrite
  `navigator.mediaSession.metadata` so iOS lockscreen artwork + title swap at
  each chapter. Pattern proven out in `docs/example.html` — keep that file as
  the canonical reference if MediaSession behavior gets weird.
- **Synced playback state** in SQLite (better-sqlite3). Server is source of
  truth. Position sync from the client is quiet: only on
  `pause` / `seeked` / `visibilitychange→hidden` / `pagehide` via
  `navigator.sendBeacon`. Never periodic.

## Stack

Node ≥ 20, ESM (`"type": "module"`). `express`, `better-sqlite3`,
`rss-parser`, `node-id3`, `dotenv`. No frontend framework — vanilla JS module
in `public/app.js`. No TypeScript. No test suite yet.

## Running / inspecting

```sh
npm start                                   # production-ish
SYNC_INTERVAL_MS=999999999 npm start        # disable hourly sync for testing
sqlite3 data/pcast.db                       # inspect state
```

Auth: every request needs either `Authorization: Bearer $PCAST_TOKEN` or the
`pcast_token` cookie. Static shell + manifest + SW + login page are public
so the PWA can install before login.

## Architecture cheat-sheet

```
Browser ──HTTPS via Tailscale──► Express (src/server.js)
                                   ├── /          → public/index.html
                                   ├── /login     → public/login.html
                                   ├── /api/login, /api/logout, /api/whoami
                                   ├── /api/*     → requireAuth → feeds/episodes/sync/audio
                                   └── /artwork/* → requireAuth → chapter PNG/JPEG
                                 │
                                 ├── better-sqlite3 → data/pcast.db
                                 ├── fs            → data/artwork/<ep>/<n>.<ext>
                                 └── fs (file://)  → data/library/**/*.xml + audio
```

Everything lives on a single `root` express.Router mounted at
`BASE_PATH || '/'`. The mount-prefix story matters; see "Gotchas" below.

Client uses a `Player` class (`public/app.js`) that adapts the
`docs/example.html` pattern against real chapter data from the API.

## Critical conventions — don't break these

1. **Relative URLs everywhere.** HTML has `<base href="./">`; all asset refs
   are relative (`app.js`, `styles.css`, `icons/icon-180.png`). JS uses
   `const BASE = new URL('.', document.baseURI).href` plus `u(path)` and
   `resolveArt(raw)` helpers. API responses return relative paths too
   (`artwork/chapter/123`, `api/audio/42`). This is what lets the app work
   under any path prefix without server-side templating.

2. **API audio_url is virtualized.** DB stores the canonical URL (HTTP or
   `file://`). The episodes routes call `publicAudioUrl(ep)` which rewrites
   `file://` to `api/audio/:id` before returning. Don't expose DB
   `audio_url` directly to the client.

3. **`sendBeacon` cannot set headers**, so cookie auth on `/api/*` is
   load-bearing for position sync. Don't switch position sync to
   bearer-only.

4. **Service worker never intercepts `/api/*`, `/artwork/*`, or audio Range
   requests.** Safari's audio element does its own Range handling; SW
   interception breaks seeking. The SW skip-check is scope-relative
   (`SCOPE_PATH + 'api/'`) so it works under any prefix.

5. **`file://` paths are path-traversal-checked.** `safeFileUrlToPath()` in
   `src/util/local.js` requires the resolved path to be inside
   `LOCAL_LIBRARY_DIR`. Symlinks *are* followed during traversal; the user
   is trusted not to symlink sensitive paths into the library. If you add a
   new place that reads file:// from feeds, run it through this helper.

6. **DB migrations** go in `src/db.js#migrate()` as idempotent
   `ALTER TABLE … ADD COLUMN` guarded by `PRAGMA table_info`. Also update
   `src/init.sql` so fresh DBs match. Existing example:
   `audio_available INTEGER NOT NULL DEFAULT 1`.

7. **Position-sync model:** never add periodic position pushes. The
   contract with the user is "no chatter" — pause / seek / hide /
   beforeunload only. Local UI updates fire off `timeupdate` and never hit
   the server.

8. **Auto-advance** uses `GET /api/episodes/:id/next`, which returns the
   chronologically forward (`pub_date ASC`) next episode in the same feed
   filtered by `audio_available=1 AND played=0`. Client calls it from both
   `audio` `ended` and `error` events. If you change the ordering, do it
   server-side so behavior stays single-sourced.

## Gotchas

- **Don't add a bare-root redirect** when `BASE_PATH` is set. Stripping
  proxies (Tailscale serve `--set-path`) send `/` to the backend; a
  redirect to `/pod/` becomes an infinite loop. This used to exist and was
  removed — there's a load-bearing comment in `server.js` saying so.

- **`BASE_PATH` is for non-stripping proxies only.** Tailscale serve
  strips. Set `BASE_PATH=""` (default) with Tailscale serve `--set-path`;
  the browser-side prefix is handled entirely by `<base href="./">` +
  relative URLs.

- **Cookie path tracks `BASE_PATH`.** `auth.js#setLoginCookie(res, token,
  path)`. If `BASE_PATH=/pod`, the cookie's `Path=/pod` — it won't be sent
  to bare-path requests. That's intentional.

- **node-id3 chapter shape varies slightly between versions.** The
  normalizer in `src/sync/chapters.js#normalizeChapter` accepts both
  `tags.image` and `image` placements. Don't tighten it.

- **iOS Safari requires user gesture for first `audio.play()`.** Player
  expects to be initiated from a tap. Auto-advance works after first play
  because the AudioContext is "unlocked" once the user has played anything
  in the session.

- **`<audio>` `error` event also fires** when `/api/audio/:id` 404s
  (file vanished mid-stream). Player auto-advances on error too — don't
  treat it as a fatal stop.

- **Local feed mtime caching:** `feeds.last_modified` stores the file's
  `mtimeMs` as a string for `file://` feeds, and the HTTP `Last-Modified`
  header for HTTP feeds. Conditional-GET path branches on URL scheme in
  `src/sync/rss.js#loadFeedSource`.

- **Library scan follows symlinked subdirs** (Node's `readdir({recursive:
  true})` does not), with a realpath-based cycle guard in
  `src/sync/scheduler.js#scanLocalLibrary`. If you switch to Node's native
  recursive readdir, you lose symlink-dir traversal.

## Where things live

```
src/server.js                 # Express entrypoint, single root router mounted at BASE_PATH
src/db.js + src/init.sql      # SQLite open + idempotent migrations
src/auth.js                   # bearer-or-cookie middleware + cookie helpers
src/routes/auth.js            # /api/login, /api/logout, /api/whoami
src/routes/feeds.js           # CRUD for feeds; POST triggers an immediate sync
src/routes/episodes.js        # list/detail/position/played/next/rechapter; rewrites audio_url
src/routes/sync.js            # POST /api/sync (fire and forget); GET /api/sync/status
src/routes/artwork.js         # serves cached chapter JPEG/PNG
src/routes/audio.js           # Range-streams local file:// audio
src/sync/rss.js               # rss-parser based feed sync; handles file:// + http
src/sync/chapters.js          # ID3 CHAP/APIC extractor; up-front statSync for file://
src/sync/scheduler.js         # runs every SYNC_INTERVAL_MS; library scan + reconcile + extract queue
src/util/local.js             # file:// helpers + isInsideLibrary path-safety
src/util/id3.js               # fetchId3TagBytes — HTTP Range or fs.open by URL scheme
src/util/log.js               # tiny timestamped logger

public/index.html             # PWA shell, <base href="./">, MediaSession-using app.js
public/login.html             # one-input token form, POSTs /api/login
public/app.js                 # Player class + library/episode views
public/styles.css
public/sw.js                  # caches shell only; never /api/, /artwork/, audio
public/manifest.webmanifest   # start_url=".", scope="."
public/icons/                 # icon-180/192/512.png (regenerate via npm run make-icons)

tools/make-icons.mjs          # pure-Node PNG generator, no deps
docs/example.html             # original MediaSession lockscreen test page — canonical reference

data/                         # gitignored
├── pcast.db                  # SQLite (WAL mode)
├── artwork/<ep>/<n>.<ext>    # extracted per-chapter APIC images
└── library/**/*.xml          # local feed XMLs (LOCAL_LIBRARY_DIR)
```

## Common tasks

**Add a DB column.** Update `init.sql` (so fresh DBs match) AND add an
idempotent block to `db.js#migrate()` (so existing DBs upgrade). Don't
rely on schema_version — we use feature detection via `PRAGMA table_info`.

**Add an API endpoint.** Inside one of the `mountXxxRoutes(api, ctx)`
functions. Use mount-relative paths (`api.get('/feeds', …)`, NOT
`/api/feeds`). Auth routes (`/api/login` etc.) are the exception — they
live on the `root` router with fully-qualified paths.

**Touch the client URL story.** Don't introduce absolute paths. Funnel
everything through `u(path)` for general URLs and `resolveArt(raw)` for
artwork URLs that may be HTTP or relative. The `api()` helper auto-strips
leading slashes, so `api('/api/foo')` and `api('api/foo')` both work.

**Verify a change end-to-end.** Use a provided local feed under `data/library/` with relative + absolute `file://`
enclosures (tests local mode + path-safety).

Smoke-test with `curl` against `/api/whoami`, `/api/feeds`,
`/api/episodes/:id`, and `/api/audio/:id` (try `Range: bytes=0-9999`,
`Range: bytes=-1024`, and an out-of-range to confirm 416). `sqlite3
data/pcast.db` is faster than scripting for state inspection.

**Add a UI feature on the player.** Re-read `docs/example.html` first.
The MediaSession + chapter-boundary pattern there is the spec; deviating
breaks iOS lockscreen behavior in subtle ways.

# Worldcast

A single-user, Safari-installable PWA podcast listener with a Node.js backend.

- **Hourly RSS sync** of subscribed feeds.
- **Server-side ID3 chapter extraction**, including per-chapter `APIC` artwork — extracted by Range-fetching just the ID3 tag from each episode's audio URL, no full download.
- **MediaSession lockscreen integration** with chapter-aware artwork + title swaps, mirroring `docs/example.html`.
- **Synced playback state** (positions + played flags) so any device hitting the same server resumes consistently. Position updates are quiet: sent only on pause / seek / pagehide.
- Audio streams directly from the podcast origin — the server doesn't proxy audio.

## Running

```sh
npm install
cp .env.example .env
# edit .env: set PCAST_TOKEN to a long random string
npm start
```

Server listens on `PORT` (default `8080`).

### Expose to your phone

Default — single app at the origin root:

```sh
tailscale serve --bg --https=443 http://localhost:8080
```

Behind a path prefix (e.g. sharing the same Tailscale serve cert with other apps):

```sh
# Leave BASE_PATH empty in .env — tailscale serve --set-path STRIPS the
# prefix before forwarding, so the backend should listen at root.
npm start
tailscale serve --bg --https=443 --set-path=/pod http://localhost:8080
```

This works because the PWA's HTML uses `<base href="./">` and relative URLs
everywhere: the browser loads the page at `https://host/pod/`, resolves
`app.js` to `https://host/pod/app.js`, Tailscale strips `/pod` and forwards
`/app.js` to the backend at root. The service worker derives its scope from
its own URL, so its precache + fetch-skip logic line up automatically.

#### When to set `BASE_PATH`

Only set `BASE_PATH=/pod` if your reverse proxy **preserves** the path prefix
on the forwarded request (some nginx setups, traefik with `PathPrefix` without
`StripPrefix`). Tailscale serve does not — it strips. Setting `BASE_PATH` on
a stripping proxy produces a 404 (or worse, a loop if you also have a
redirect helper in front of the app).

Open the Tailscale-served HTTPS URL on the iPhone, sign in with the token, then **Share → Add to Home Screen** to install the PWA. Lockscreen Now Playing controls only behave reliably when the app is installed (standalone display mode).

## Local library (drop-folder for archives)

Drop XML feed files into `./data/library/` (or whatever `LOCAL_LIBRARY_DIR`
points at) and the server imports them on the next sync. Each XML is just an
RSS feed — `<channel>`, `<item>`, `<enclosure>` — but with two extras:

- The XML's own location is the feed identifier; no URL needed.
- `<enclosure url>` can be a `file://` URL **or** a relative path
  (`./ep01.mp3`, `episodes/ep01.mp3`, `../shared/foo.mp3`). Relative paths
  resolve against the XML file's directory.

Suggested layout:

```
data/library/
├── my-archive/
│   ├── feed.xml          # <enclosure url="ep001.mp3"/>, etc.
│   ├── ep001.mp3
│   └── ep002.mp3
└── old-shows/
    └── feed.xml          # <enclosure url="file:///Volumes/big-disk/foo.mp3"/>
```

Safety: every audio path is resolved and required to be **inside**
`LOCAL_LIBRARY_DIR`. `../etc/passwd` is rejected. Symlinks *are* supported —
the library root, subdirectories, feed XMLs, and audio files may all be
symlinks (the scanner follows symlinked directories with a cycle guard).
The path check happens before symlink resolution, so it's on you not to
symlink anything sensitive into the library.

Browsers can't load `file://` from an HTTPS page, so the PWA's `<audio src>`
points at `GET /api/audio/:id`, which streams the local file with proper
Range support and same-origin cookie auth. ID3 chapter extraction reads
`file://` audio directly via `fs` — no HTTP roundtrip.

Removing an XML file does **not** auto-delete the feed; episodes, positions,
and played flags are preserved (same as HTTP feeds that 404). Delete via the
UI if you want it gone.

## Project layout

```
src/
├── server.js              # Express entrypoint
├── db.js / init.sql       # better-sqlite3 + schema
├── auth.js                # Bearer + cookie middleware
├── routes/                # feeds, episodes, sync, artwork, auth
├── sync/
│   ├── rss.js             # RSS fetch + episode upsert
│   ├── chapters.js        # ID3 CHAP/APIC extractor (Range-fetched)
│   └── scheduler.js       # hourly sync + chapter extraction queue
└── util/                  # id3 byte ops, logging
public/                    # PWA shell (index.html, app.js, sw.js, manifest, icons)
docs/example.html          # original MediaSession reference
tools/make-icons.mjs       # pure-Node PNG icon generator (run via `npm run make-icons`)
data/                      # SQLite DB + cached chapter artwork (gitignored)
```

## Notes / non-goals

- **No offline audio caching.** Audio is streamed from origin every time. The service worker only caches the app shell.
- **ID3 chapters only.** Podlove Simple Chapters (`<podcast:chapters>` JSON via the podcast namespace) is not yet implemented — many modern podcasts ship chapters that way instead, and adding that extractor is the obvious next step.
- **Single user, single device at a time.** Concurrent playback isn't reconciled; whichever device pushes the last position wins.
- **Tailscale gates the origin.** The bearer token is secondary defense.

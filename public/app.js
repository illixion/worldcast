// Worldcast — PWA podcast listener.
// Single-tab single-user. Audio streams directly from the podcast origin.
// MediaSession-driven lockscreen artwork + title updates at each chapter boundary,
// mirroring the pattern proven out in docs/example.html.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

// document.baseURI honors <base href="./">, so `new URL('.', baseURI)` is
// the absolute root of this app whether it's mounted at "/" or at "/pod".
// All API and artwork URLs are constructed off this so the same code works
// under any path prefix.
const BASE = new URL('.', document.baseURI).href;
function u(path) { return new URL(path, BASE).href; }
// Resolve an artwork URL that may be absolute (RSS CDN), relative
// ("artwork/chapter/123"), or missing. Returns null on missing.
function resolveArt(raw) {
  if (!raw) return null;
  if (/^https?:/i.test(raw)) return raw;
  return u(raw.replace(/^\//, ''));
}

// Auth is path-based: the URL the page was loaded from already contains the
// token (mounted under <BASE_PATH>/<TOKEN>/ on the server). Every relative
// request inherits that prefix via <base href="./">, so there is no cookie,
// no whoami, no login page. A wrong URL just 404s before reaching the app.

// -------- helpers --------
function fmtTime(s) {
  if (!isFinite(s) || s < 0) return '0:00';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = Math.floor(s % 60).toString().padStart(2, '0');
  return h > 0 ? `${h}:${m.toString().padStart(2,'0')}:${sec}` : `${m}:${sec}`;
}
function fmtDate(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}
async function api(path, opts = {}) {
  // Accept both "api/x" and "/api/x" — normalize through u().
  const r = await fetch(u(path.replace(/^\//, '')), { credentials: 'same-origin', ...opts });
  if (!r.ok) throw new Error(`${r.status} ${path}`);
  return r.json();
}

// -------- player --------
const SPEED_STEPS = [1, 1.25, 1.5, 1.75, 2, 0.75];
const SPEED_KEY = 'worldcast.playbackRate';

class Player {
  constructor(audio, video) {
    // `this.audio` is whichever media element is currently active (audio for
    // podcast episodes, video for video episodes). It's swapped in load();
    // event handlers always read through this.audio so the rest of the class
    // doesn't need to know which one is live.
    this._audioEl = audio;
    this._videoEl = video;
    this.audio = audio;
    this.episode = null;
    this.chapters = [];
    this.currentChapterIdx = -1;
    this.positionInterval = null;
    this.scrubbing = false;
    // Default 1x; restore last user choice if any (clamped to known steps).
    const saved = parseFloat(localStorage.getItem(SPEED_KEY));
    this.playbackRate = SPEED_STEPS.includes(saved) ? saved : 1;
    this.audio.playbackRate = this.playbackRate;
    this._bind();
    this._bindMediaSession();
    this._renderSpeed();
  }

  // Make `el` the live media element, detaching listeners from the previous
  // one so its own timeupdate/error events don't fire into the player.
  _setActiveMedia(el) {
    if (el === this.audio) return;
    try { this.audio.pause(); } catch {}
    this._detach(this.audio);
    try { this.audio.removeAttribute('src'); this.audio.load(); } catch {}
    this.audio = el;
    this._attach(el);
    el.playbackRate = this.playbackRate;
  }

  cycleSpeed() {
    const i = SPEED_STEPS.indexOf(this.playbackRate);
    this.playbackRate = SPEED_STEPS[(i + 1) % SPEED_STEPS.length];
    this.audio.playbackRate = this.playbackRate;
    try { localStorage.setItem(SPEED_KEY, String(this.playbackRate)); } catch {}
    this._renderSpeed();
    this._updatePositionState();
  }

  _renderSpeed() {
    const btn = $('#speedBtn');
    if (!btn) return;
    const r = this.playbackRate;
    btn.textContent = (Number.isInteger(r) ? r : r.toFixed(2).replace(/0+$/, '').replace(/\.$/, '')) + '×';
  }

  hasEpisode() { return Boolean(this.episode); }

  async load(episodeId, autoplay = true) {
    const { episode, chapters } = await api(`/api/episodes/${episodeId}`);
    this.episode  = episode;
    this.chapters = chapters || [];
    this.currentChapterIdx = -1;

    // Pick which media element drives playback. Video episodes use the
    // <video> sitting inside the artwork wrap so it doubles as visual output.
    const useVideo = !!episode.is_video;
    this._setActiveMedia(useVideo ? this._videoEl : this._audioEl);
    const wrap = $('.artwork-wrap');
    if (wrap) wrap.classList.toggle('is-video', useVideo);
    if (this._videoEl) this._videoEl.hidden = !useVideo;
    const artEl = $('#playerArtwork');
    if (artEl) artEl.hidden = useVideo;
    // Use the episode artwork as a poster so the video frame isn't black
    // before metadata loads.
    if (useVideo && this._videoEl) {
      this._videoEl.poster = resolveArt(episode.artwork_url || episode.feed_artwork_url) || '';
    }

    this.audio.src = episode.audio_url;
    // Some browsers reset playbackRate when src changes — reapply.
    this.audio.playbackRate = this.playbackRate;
    const startAt = Number(episode.position_seconds) || 0;
    // Wait for metadata before seeking so iOS accepts currentTime.
    const seekWhenReady = () => {
      if (startAt > 0 && isFinite(this.audio.duration) && this.audio.duration > 0) {
        try { this.audio.currentTime = Math.min(startAt, this.audio.duration - 1); } catch {}
      } else if (startAt > 0) {
        try { this.audio.currentTime = startAt; } catch {}
      }
      this.audio.removeEventListener('loadedmetadata', seekWhenReady);
    };
    this.audio.addEventListener('loadedmetadata', seekWhenReady);

    this._renderPlayerView();
    // Force the next _applyChapter to run even if chapter index is unchanged
    // (e.g. -1 for an episode without chapters) so the mini-player + media
    // session metadata reflect the new episode.
    this.currentChapterIdx = Number.NaN;
    this._applyChapter(this._chapterAt(startAt));
    this._preloadArtwork();

    if (autoplay) {
      try { await this.audio.play(); } catch (e) { console.warn('autoplay blocked', e.message); }
    }
    showMiniPlayer();
    navigate('playerView');
    // Refresh the library's "Recently played" so it reflects the new episode
    // without waiting for a manual reload. Fire-and-forget.
    renderRecent().catch(() => {});
  }

  _chapterAt(timeSec) {
    if (this.chapters.length === 0) return -1;
    const ms = timeSec * 1000;
    let idx = -1;
    for (let i = 0; i < this.chapters.length; i++) {
      if (ms >= this.chapters[i].start_ms) idx = i;
      else break;
    }
    return idx;
  }

  _bind() {
    // Handlers are stored on `this` so they can be reattached when the
    // active media element switches between audio and video.
    this._handlers = {
      timeupdate:     () => this._onTimeUpdate(),
      loadedmetadata: () => this._renderTimes(),
      durationchange: () => this._renderTimes(),
      play:           () => this._onPlay(),
      pause:          () => this._onPause(),
      seeked:         () => this._pushPosition(),
      ended:          () => this._onEnded(),
      // If the active media element errors (e.g. /api/audio/:id 404s because
      // the local file vanished mid-stream), try to advance past it.
      error:          () => this._onAudioError(),
    };
    this._attach(this.audio);

    // Position sync only on pause / seek / hide / unload — never periodic.
    // Both visibility edges push: 'hidden' captures the position at the moment
    // of backgrounding; 'visible' captures any position reached while the page
    // was frozen on the lock screen (e.g. listening then pausing there), since
    // a frozen context can't beacon at that instant. audio.currentTime is still
    // accurate on thaw, so this reconciles a lock-screen pause before another
    // device could resume past it. Edge-triggered, so the no-chatter contract
    // (CLAUDE.md rule 7) still holds.
    document.addEventListener('visibilitychange', () => {
      this._pushPosition();
      if (document.visibilityState === 'visible') this._reconcileOnForeground();
    });
    window.addEventListener('pagehide', () => this._pushPosition());
    window.addEventListener('beforeunload', () => this._pushPosition());
  }

  _attach(el) { for (const [k, fn] of Object.entries(this._handlers)) el.addEventListener(k, fn); }
  _detach(el) { for (const [k, fn] of Object.entries(this._handlers)) el.removeEventListener(k, fn); }

  _bindMediaSession() {
    if (!('mediaSession' in navigator)) return;
    const ms = navigator.mediaSession;
    const safe = (name, fn) => {
      try { ms.setActionHandler(name, fn); } catch (e) { console.warn(`handler ${name}: ${e.message}`); }
    };
    safe('play',  () => this.audio.play().catch(() => {}));
    safe('pause', () => this.audio.pause());
    safe('previoustrack', () => this.jumpChapter(-1));
    safe('nexttrack',     () => this.jumpChapter(+1));
    safe('seekbackward', (d) => this.seekBy(-(d.seekOffset || 15)));
    safe('seekforward',  (d) => this.seekBy(  d.seekOffset || 30));
    safe('seekto', (d) => { if (typeof d.seekTime === 'number') this.audio.currentTime = d.seekTime; });
  }

  _applyChapter(idx) {
    if (idx === this.currentChapterIdx) return;
    this.currentChapterIdx = idx;
    const ch = this.chapters[idx];
    const fallbackArt = this._episodeArtworkSrc();
    const artSrc  = resolveArt(ch && ch.artwork_url) || fallbackArt;
    const artType = (ch && ch.artwork_mime) || 'image/jpeg';

    if ('mediaSession' in navigator) {
      const meta = {
        title:  (ch && ch.title) || this.episode.title,
        artist: this.episode.feed_title || '',
        album:  this.episode.title || '',
        artwork: artSrc ? [{ src: artSrc, sizes: '512x512', type: artType }] : []
      };
      try { navigator.mediaSession.metadata = new MediaMetadata(meta); } catch (e) {}
    }

    // UI updates
    const titleEl   = $('#playerChapter');
    const metaEl    = $('#playerEpisode');
    const artEl     = $('#playerArtwork');
    const miniArtEl = $('#miniArtwork');
    const miniTitle = $('#miniTitle');
    const miniMeta  = $('#miniMeta');
    if (titleEl) titleEl.textContent = (ch && ch.title) || this.episode.title || '—';
    if (metaEl) {
      const which = idx >= 0 ? `ch ${idx + 1}/${this.chapters.length} · ${this.episode.feed_title}` : (this.episode.feed_title || '');
      metaEl.textContent = which;
    }
    // For video episodes the on-page artwork is hidden in favor of the video
    // surface; don't touch artEl.src so we don't trigger image loads that
    // would compete with the video for layout space.
    if (artEl && artSrc && !this.episode.is_video) artEl.src = artSrc;
    if (miniArtEl && artSrc) miniArtEl.src = artSrc;
    if (miniTitle) miniTitle.textContent = (ch && ch.title) || this.episode.title || '—';
    if (miniMeta) miniMeta.textContent = this.episode.feed_title || '';
    this._highlightChapterRow(idx);
  }

  _episodeArtworkSrc() {
    return resolveArt(this.episode.artwork_url || this.episode.feed_artwork_url)
        || u('icons/icon-512.png');
  }

  _preloadArtwork() {
    for (const ch of this.chapters) {
      const src = resolveArt(ch.artwork_url);
      if (src) { const i = new Image(); i.src = src; }
    }
  }

  _onTimeUpdate() {
    const t = this.audio.currentTime;
    const idx = this._chapterAt(t);
    if (idx !== this.currentChapterIdx) this._applyChapter(idx);
    this._renderScrub(t);
    this._updatePositionState();
  }

  _onPlay() {
    this._intendPlaying = true;
    $('#playBtn').textContent = 'Pause';
    $('#miniPlayBtn').textContent = '❚❚';
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
    this._updatePositionState();
    if (!this.positionInterval) {
      this.positionInterval = setInterval(() => this._updatePositionState(), 1000);
    }
  }

  _onPause() {
    this._intendPlaying = false;
    $('#playBtn').textContent = 'Play';
    $('#miniPlayBtn').textContent = '▶';
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
    if (this.positionInterval) { clearInterval(this.positionInterval); this.positionInterval = null; }
    this._pushPosition();
  }

  // When the PWA is foregrounded, iOS may have left the media element in a
  // desynced state: the clock display is frozen at the position it had when
  // the page was suspended, even though the element is "playing" — the user
  // currently has to manually pause/unpause to unstick it. Reconcile here:
  // repaint the UI from the element's real state, and if we intended to be
  // playing but the element is paused, re-issue play() (now allowed — the page
  // is foreground again). Best-effort; the iOS suspend/resume behavior here is
  // not fully specified, so treat this as a mitigation, not a guarantee.
  _reconcileOnForeground() {
    if (!this.episode) return;
    // Repaint scrub + chapter from the element's actual currentTime, in case
    // timeupdate didn't fire across the suspend boundary.
    this._renderScrub(this.audio.currentTime || 0);
    this._updatePositionState();
    if ('mediaSession' in navigator) {
      navigator.mediaSession.playbackState = this.audio.paused ? 'paused' : 'playing';
    }
    if (this._intendPlaying && this.audio.paused) {
      this.audio.play().catch(() => {/* stays paused; UI already reflects it */});
    }
  }

  async _onEnded() {
    if (!this.episode) return;
    const finishedId = this.episode.id;
    try {
      await api(`api/episodes/${finishedId}/played`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ played: true })
      });
    } catch {}
    this._advance(finishedId);
  }

  async _onAudioError() {
    if (!this.episode) return;
    // Most "vanished file" errors land here as a MEDIA_ERR_SRC_NOT_SUPPORTED
    // after a 404 from /api/audio/:id. Skip to the next episode rather than
    // leaving the player stuck.
    const err = this.audio.error;
    const code = err && err.code;
    // Ignore transient errors before a src is set.
    if (!this.audio.src) return;
    console.warn('audio error code=', code, err && err.message);
    this._advance(this.episode.id);
  }

  async _advance(fromId) {
    try {
      const { next } = await api(`api/episodes/${fromId}/next`);
      if (next) { this.load(next); return; }
    } catch (e) { console.warn('next-lookup failed', e); }
    // Nothing to advance to — stop cleanly.
    this.audio.pause();
    $('#syncStatus').textContent = 'No newer unplayed episode in this feed.';
  }

  _renderTimes() {
    const dur = this.episode?.duration_seconds || this.audio.duration || 0;
    $('#durTime').textContent = fmtTime(dur);
    this._renderScrub(this.audio.currentTime);
    this._renderChapterMarks();
  }

  _renderScrub(t) {
    if (this.scrubbing) return;
    const dur = this.audio.duration || this.episode?.duration_seconds || 0;
    const pct = dur > 0 ? (t / dur) * 100 : 0;
    const fill = $('#scrubFill');
    if (fill) fill.style.width = pct + '%';
    const cur = $('#curTime');
    if (cur) cur.textContent = fmtTime(t);
  }

  _renderChapterMarks() {
    const marks = $('#scrubMarks');
    if (!marks) return;
    marks.innerHTML = '';
    const dur = this.audio.duration || this.episode?.duration_seconds || 0;
    if (dur <= 0 || this.chapters.length < 2) return;
    for (const ch of this.chapters) {
      const pct = (ch.start_ms / 1000 / dur) * 100;
      if (pct <= 0 || pct >= 100) continue;
      const i = document.createElement('i');
      i.style.left = pct + '%';
      marks.appendChild(i);
    }
  }

  _renderPlayerView() {
    if (!this.episode.is_video) $('#playerArtwork').src = this._episodeArtworkSrc();
    $('#playerChapter').textContent = this.episode.title || '—';
    $('#playerEpisode').textContent = this.episode.feed_title || '';
    const list = $('#chapterList');
    list.innerHTML = '';
    const wrap = $('#chapterListWrap');
    if (wrap) wrap.hidden = this.chapters.length === 0;
    this.chapters.forEach((ch, i) => {
      const li = document.createElement('li');
      const img = document.createElement('img');
      img.src = resolveArt(ch.artwork_url) || this._episodeArtworkSrc();
      img.alt = '';
      const div = document.createElement('div');
      div.className = 'ch-text';
      const t = document.createElement('div'); t.className = 'ch-title'; t.textContent = ch.title || `Chapter ${i + 1}`;
      const tm = document.createElement('div'); tm.className = 'ch-time'; tm.textContent = fmtTime(ch.start_ms / 1000);
      div.append(t, tm);
      li.append(img, div);
      li.dataset.idx = i;
      li.addEventListener('click', () => { this.audio.currentTime = ch.start_ms / 1000; });
      list.appendChild(li);
    });
    this._renderTimes();
  }

  _highlightChapterRow(idx) {
    $$('#chapterList li').forEach((li, i) => li.classList.toggle('active', i === idx));
  }

  _updatePositionState() {
    if (!('mediaSession' in navigator) || !('setPositionState' in navigator.mediaSession)) return;
    const dur = this.audio.duration || this.episode?.duration_seconds || 0;
    if (!dur || !isFinite(dur)) return;
    try {
      navigator.mediaSession.setPositionState({
        duration: dur,
        playbackRate: this.audio.playbackRate || 1,
        position: Math.max(0, Math.min(this.audio.currentTime || 0, dur))
      });
    } catch (e) { /* iOS occasionally throws on rapid updates */ }
  }

  _pushPosition() {
    if (!this.episode) return;
    const pos = this.audio.currentTime || 0;
    // client_ts lets the server order this write against other devices and
    // late-arriving beacons (see /episodes/:id/position). Date.now() is the
    // moment we observed the position, not when the request lands.
    const body = JSON.stringify({ position: pos, client_ts: Date.now() });
    const url = u(`api/episodes/${this.episode.id}/position`);
    try {
      const blob = new Blob([body], { type: 'application/json' });
      if (navigator.sendBeacon(url, blob)) return;
    } catch {}
    // Fallback: fire-and-forget fetch (keepalive lets it survive page navigation).
    fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      credentials: 'same-origin',
      body,
      keepalive: true
    }).catch(() => {});
  }

  jumpChapter(dir) {
    if (this.chapters.length === 0) {
      this.seekBy(dir * 30);
      return;
    }
    const cur = this._chapterAt(this.audio.currentTime);
    const next = Math.max(0, Math.min(this.chapters.length - 1, (cur < 0 ? 0 : cur) + dir));
    this.audio.currentTime = this.chapters[next].start_ms / 1000;
  }

  seekBy(delta) {
    const dur = this.audio.duration || this.episode?.duration_seconds || Infinity;
    this.audio.currentTime = Math.max(0, Math.min(this.audio.currentTime + delta, dur));
  }

  toggle() {
    if (this.audio.paused) this.audio.play().catch(e => console.warn(e));
    else this.audio.pause();
  }
}

// -------- view routing --------
// We synthesize a history stack inside the SPA so the browser/PWA back button
// moves between views (library → episodes → player) instead of escaping the
// app scope. The library view is the root entry (replaceState on boot); every
// other view is a pushState on top of it. popstate replays whatever state is
// on top without pushing again.
function showView(id) {
  $$('.view').forEach(v => v.classList.toggle('active', v.id === id));
  $('#navLibrary').classList.toggle('active', id !== 'playerView');
  $('#navNowPlaying').classList.toggle('active', id === 'playerView');
}

// Navigate to a view, pushing a new history entry unless we're already on it.
// `payload` is stored on the history state so popstate can restore context
// (e.g. which feed the episodes view was showing).
function navigate(view, payload = {}) {
  const cur = history.state || {};
  if (cur.view === view && cur.feedId === payload.feedId && cur.episodeId === payload.episodeId) {
    showView(view);
    return;
  }
  history.pushState({ view, ...payload }, '');
  showView(view);
}

let cachedFeedsById = new Map();

async function restoreFromState(state) {
  const view = (state && state.view) || 'libraryView';
  if (view === 'episodesView' && state.feedId != null) {
    let feed = cachedFeedsById.get(state.feedId);
    if (!feed) {
      try {
        const { feeds } = await api('/api/feeds');
        for (const f of feeds) cachedFeedsById.set(f.id, f);
        feed = cachedFeedsById.get(state.feedId);
      } catch {}
    }
    if (feed) { await renderEpisodes(feed, { push: false }); return; }
    // Feed gone — fall through to library.
  }
  if (view === 'detailsView' && state.episodeId != null) {
    await renderEpisodeDetails(state.episodeId, { push: false });
    return;
  }
  if (view === 'playerView' && player && player.hasEpisode()) {
    showView('playerView');
    return;
  }
  showView('libraryView');
}

function showMiniPlayer() { $('#miniPlayer').hidden = false; }

// -------- recently-played UI --------
let recentExpanded = false;
const RECENT_COLLAPSED = 3;
const RECENT_EXPANDED = 20;

function renderRecentRow(ep) {
  const li = document.createElement('li');
  const unavailable = ep.audio_available === 0;
  li.className = 'episode-row'
    + (ep.played ? ' played' : '')
    + (unavailable ? ' unavailable' : '');

  const img = document.createElement('img');
  img.className = 'recent-art';
  img.src = resolveArt(ep.artwork_url) || resolveArt(ep.feed_artwork_url) || u('icons/icon-192.png');
  img.alt = '';

  const text = document.createElement('div'); text.className = 'text';
  const title = document.createElement('div'); title.className = 't-title'; title.textContent = ep.title;
  if (unavailable) {
    const tag = document.createElement('span'); tag.className = 'tag-missing'; tag.textContent = 'missing';
    title.appendChild(tag);
  }
  if (ep.is_video) {
    const tag = document.createElement('span'); tag.className = 'tag-video'; tag.textContent = 'video';
    title.appendChild(tag);
  }
  const meta = document.createElement('div'); meta.className = 't-meta';
  const dur = ep.duration_seconds ? ` · ${fmtTime(ep.duration_seconds)}` : '';
  meta.textContent = `${ep.feed_title || ''}${dur}`;
  text.append(title, meta);

  if (ep.duration_seconds && ep.position_seconds > 0 && !ep.played) {
    const pbar = document.createElement('div'); pbar.className = 'pbar';
    const fill = document.createElement('i');
    fill.style.width = Math.min(100, (ep.position_seconds / ep.duration_seconds) * 100) + '%';
    pbar.appendChild(fill);
    text.appendChild(pbar);
  }

  li.append(img, text);
  if (!unavailable) {
    const play = document.createElement('button');
    play.className = 'play-btn';
    play.title = 'Play';
    play.textContent = '▶';
    play.addEventListener('click', (e) => { e.stopPropagation(); player.load(ep.id); });
    li.appendChild(play);
  }
  li.addEventListener('click', () => renderEpisodeDetails(ep));
  return li;
}

async function renderRecent() {
  const section = $('#recentSection');
  const list = $('#recentList');
  const toggle = $('#recentToggle');
  const limit = recentExpanded ? RECENT_EXPANDED : RECENT_COLLAPSED;
  let episodes = [];
  try {
    const r = await api(`/api/episodes/recent?limit=${limit + 1}`);
    episodes = r.episodes || [];
  } catch { /* ignore */ }
  if (episodes.length === 0) { section.hidden = true; return; }
  section.hidden = false;
  const hasMore = !recentExpanded && episodes.length > RECENT_COLLAPSED;
  const shown = episodes.slice(0, limit);
  list.innerHTML = '';
  for (const ep of shown) list.appendChild(renderRecentRow(ep));
  toggle.hidden = !hasMore && !recentExpanded;
  toggle.textContent = recentExpanded ? 'Show less' : 'Show all';
}

async function playRandomUnplayed() {
  const btn = $('#playRandomBtn');
  const status = $('#syncStatus');
  btn.disabled = true;
  try {
    const { episode } = await api('/api/episodes/random-unplayed');
    if (!episode) { status.textContent = 'No never-played episodes available.'; return; }
    await player.load(episode.id);
  } catch (e) {
    status.textContent = `Random play failed: ${e.message}`;
  } finally {
    btn.disabled = false;
  }
}

// -------- library / episodes UI --------
// -------- background poll --------
// PWA standalone mode swallows the pull-to-refresh gesture, so the UI never
// gets a chance to pick up server-side changes (hourly RSS sync, chapter
// extraction completing, or another device updating playback state). Poll
// while the tab is visible: sync status + recent list always, full feed
// list only when the library view is active so we don't fight with the
// player view's own rendering.
const POLL_MS = 15000;
let pollTimer = null;

async function pollRefresh() {
  if (document.visibilityState !== 'visible') return;
  try {
    const ss = await api('/api/sync/status');
    $('#syncStatus').textContent = ss.chaptersPending > 0
      ? `extracting chapters for ${ss.chaptersPending} episode(s)…`
      : (ss.lastFeedSyncAt ? `synced ${fmtDate(ss.lastFeedSyncAt)}` : '');
  } catch { /* network blip — try again next tick */ }
  renderRecent().catch(() => {});
  const onLibrary = $('#libraryView').classList.contains('active');
  if (onLibrary) renderFeedsOnly().catch(() => {});
}

function startPolling() {
  if (pollTimer) return;
  pollTimer = setInterval(pollRefresh, POLL_MS);
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') pollRefresh();
});
// pageshow with persisted=true fires when iOS restores from the bfcache /
// app switcher — treat it like a wake-up.
window.addEventListener('pageshow', (e) => { if (e.persisted) pollRefresh(); });

// Re-render just the feed cards (badges + counts) without disturbing the
// rest of the library DOM or kicking the status indicator.
async function renderFeedsOnly() {
  const { feeds } = await api('/api/feeds');
  const list = $('#feedList');
  // Skip if the user is mid-interaction (e.g. confirm() open) — list missing
  // children is a sign the view is being rebuilt.
  if (!list) return;
  list.innerHTML = '';
  if (feeds.length === 0) {
    const li = document.createElement('li');
    li.className = 'muted small';
    li.textContent = 'No feeds yet. Add one with the + button.';
    list.appendChild(li);
    return;
  }
  for (const f of feeds) list.appendChild(renderFeedCard(f));
}

function renderFeedCard(f) {
  const li = document.createElement('li');
  li.className = 'feed-card';
  const img = document.createElement('img');
  img.className = 'art';
  img.src = resolveArt(f.artwork_url) || u('icons/icon-192.png');
  img.alt = '';
  const text = document.createElement('div');
  text.style.flex = '1';
  text.style.minWidth = '0';
  const name = document.createElement('div'); name.className = 'name'; name.textContent = f.title || f.url;
  const meta = document.createElement('div'); meta.className = 'meta';
  meta.textContent = `${f.episode_count} episodes${f.unplayed_count > 0 ? ` · ${f.unplayed_count} new` : ''}`;
  text.append(name, meta);
  li.append(img, text);
  if (f.unplayed_count > 0) {
    const b = document.createElement('span'); b.className = 'badge'; b.textContent = f.unplayed_count;
    li.appendChild(b);
  }
  const del = document.createElement('button');
  del.className = 'del';
  del.textContent = '×';
  del.title = 'Unsubscribe';
  del.addEventListener('click', async (e) => {
    e.stopPropagation();
    if (!confirm(`Unsubscribe from ${f.title || f.url}?`)) return;
    await api(`/api/feeds/${f.id}`, { method: 'DELETE' });
    renderLibrary();
  });
  li.appendChild(del);
  li.addEventListener('click', () => renderEpisodes(f));
  cachedFeedsById.set(f.id, f);
  return li;
}

async function renderLibrary() {
  const status = $('#syncStatus');
  status.textContent = 'loading…';
  renderRecent();
  const { feeds } = await api('/api/feeds');
  const list = $('#feedList');
  list.innerHTML = '';
  if (feeds.length === 0) {
    const li = document.createElement('li');
    li.className = 'muted small';
    li.textContent = 'No feeds yet. Add one with the + button.';
    list.appendChild(li);
  }
  for (const f of feeds) list.appendChild(renderFeedCard(f));
  const ss = await api('/api/sync/status');
  status.textContent = ss.chaptersPending > 0
    ? `extracting chapters for ${ss.chaptersPending} episode(s)…`
    : (ss.lastFeedSyncAt ? `synced ${fmtDate(ss.lastFeedSyncAt)}` : '');
}

async function renderEpisodes(feed, { push = true } = {}) {
  cachedFeedsById.set(feed.id, feed);
  if (push) navigate('episodesView', { feedId: feed.id });
  else showView('episodesView');
  const header = $('#feedHeader');
  header.innerHTML = '';
  const img = document.createElement('img');
  img.src = resolveArt(feed.artwork_url) || u('icons/icon-192.png');
  img.alt = '';
  const text = document.createElement('div');
  text.innerHTML = `<div class="title">${escapeHtml(feed.title || feed.url)}</div>
                    <div class="meta">${feed.author ? escapeHtml(feed.author) + ' · ' : ''}${feed.episode_count} episodes</div>`;
  header.append(img, text);

  const list = $('#episodeList');
  list.innerHTML = '<li class="muted small">loading…</li>';
  const { episodes } = await api(`/api/episodes?feed=${feed.id}&limit=200`);
  list.innerHTML = '';
  for (const ep of episodes) {
    const li = document.createElement('li');
    const unavailable = ep.audio_available === 0;
    li.className = 'episode-row'
      + (ep.played ? ' played' : '')
      + (unavailable ? ' unavailable' : '');
    const text = document.createElement('div'); text.className = 'text';
    const title = document.createElement('div'); title.className = 't-title'; title.textContent = ep.title;
    if (unavailable) {
      const tag = document.createElement('span'); tag.className = 'tag-missing'; tag.textContent = 'missing';
      title.appendChild(tag);
    }
    if (ep.chapter_count > 0) {
      const tag = document.createElement('span'); tag.className = 'tag-ch'; tag.textContent = `${ep.chapter_count} ch`;
      title.appendChild(tag);
    }
    if (ep.is_video) {
      const tag = document.createElement('span'); tag.className = 'tag-video'; tag.textContent = 'video';
      title.appendChild(tag);
    }
    const meta = document.createElement('div'); meta.className = 't-meta';
    const dur = ep.duration_seconds ? ` · ${fmtTime(ep.duration_seconds)}` : '';
    meta.textContent = `${fmtDate(ep.pub_date)}${dur}`;
    text.append(title, meta);

    if (ep.duration_seconds && ep.position_seconds > 0 && !ep.played) {
      const pbar = document.createElement('div'); pbar.className = 'pbar';
      const fill = document.createElement('i');
      fill.style.width = Math.min(100, (ep.position_seconds / ep.duration_seconds) * 100) + '%';
      pbar.appendChild(fill);
      text.appendChild(pbar);
    }

    const check = document.createElement('button');
    check.className = 'check';
    check.textContent = ep.played ? '✓' : ' ';
    check.title = ep.played ? 'Mark unplayed' : 'Mark played';
    check.addEventListener('click', async (e) => {
      e.stopPropagation();
      await api(`/api/episodes/${ep.id}/played`, {
        method: 'POST',
        headers: {'content-type':'application/json'},
        body: JSON.stringify({ played: !ep.played })
      });
      renderEpisodes(feed);
    });

    const play = document.createElement('button');
    play.className = 'play-btn';
    play.title = 'Play';
    play.textContent = '▶';
    play.addEventListener('click', (e) => { e.stopPropagation(); player.load(ep.id); });

    li.append(text, play, check);
    if (unavailable) {
      li.addEventListener('click', (e) => {
        e.preventDefault();
        $('#syncStatus').textContent = `“${ep.title}” — audio file missing on server`;
      });
    } else {
      li.addEventListener('click', () => renderEpisodeDetails(ep));
    }
    list.appendChild(li);
  }
}

// -------- HTML sanitizer for episode descriptions --------
// Allowlist-based: parse into a detached <template>, walk the tree, strip
// any tag not in ALLOWED_TAGS, drop event handlers and javascript: URLs,
// and only keep a small set of attributes. Runs entirely client-side — the
// parsed nodes are never attached to the live document until after scrubbing,
// so inline <script>/<img onerror> never execute.
const ALLOWED_TAGS = new Set([
  'A','P','BR','HR','STRONG','EM','B','I','U','S','SMALL','SUP','SUB',
  'UL','OL','LI','BLOCKQUOTE','CODE','PRE',
  'H1','H2','H3','H4','H5','H6','SPAN','DIV','IMG'
]);
const ALLOWED_ATTRS = new Set(['href','src','alt','title','target','rel']);
function sanitizeHtml(raw, { allowRemoteMedia = false } = {}) {
  const tpl = document.createElement('template');
  tpl.innerHTML = String(raw || '');
  const scrub = (node) => {
    for (const el of Array.from(node.children)) {
      if (!ALLOWED_TAGS.has(el.tagName)) {
        while (el.firstChild) el.parentNode.insertBefore(el.firstChild, el);
        el.remove();
        continue;
      }
      for (const attr of Array.from(el.attributes)) {
        const n = attr.name.toLowerCase();
        const v = attr.value || '';
        if (!ALLOWED_ATTRS.has(n)) { el.removeAttribute(attr.name); continue; }
        if ((n === 'href' || n === 'src') && /^\s*(javascript|data|vbscript):/i.test(v)) {
          el.removeAttribute(attr.name);
        }
      }
      if (el.tagName === 'A') {
        el.setAttribute('target', '_blank');
        el.setAttribute('rel', 'noopener noreferrer');
      }
      // Privacy gate: defer remote <img> loads. Move src → data-src and
      // replace the element with a placeholder. The browser never fetches
      // anything off-origin until the user opts in. When the user toggles
      // remote media on, we re-serialize the original description with
      // allowRemoteMedia=true rather than mutating in place.
      if (el.tagName === 'IMG' && !allowRemoteMedia) {
        const src = el.getAttribute('src') || '';
        const ph = document.createElement('span');
        ph.className = 'img-placeholder';
        ph.setAttribute('data-src', src);
        ph.textContent = src ? `🖼 remote image hidden — ${src}` : '🖼 remote image hidden';
        el.replaceWith(ph);
        continue;
      }
      scrub(el);
    }
  };
  scrub(tpl.content);
  return tpl.innerHTML;
}

// -------- details view --------
const cachedEpisodesById = new Map();
let currentDetailsEpId = null;
const IMG_GATE_KEY = 'worldcast.allowRemoteImages';
let allowRemoteImages = (() => {
  try { return localStorage.getItem(IMG_GATE_KEY) === '1'; } catch { return false; }
})();
function setImgGateLabel() {
  const btn = $('#detailsImgBtn');
  if (btn) btn.textContent = allowRemoteImages ? '🖼 Images: on' : '🖼 Images: off';
}

async function renderEpisodeDetails(epOrId, { push = true } = {}) {
  const id = typeof epOrId === 'object' ? epOrId.id : Number(epOrId);
  currentDetailsEpId = id;
  if (push) navigate('detailsView', { episodeId: id });
  else showView('detailsView');

  const header = $('#detailsHeader');
  const descEl = $('#detailsDescription');
  const playBtn = $('#detailsPlayBtn');

  let cached = cachedEpisodesById.get(id);
  if (!cached && typeof epOrId === 'object') cached = epOrId;
  const renderFrom = (ep) => {
    header.innerHTML = '';
    const img = document.createElement('img');
    img.src = resolveArt(ep.artwork_url) || resolveArt(ep.feed_artwork_url) || u('icons/icon-192.png');
    img.alt = '';
    const text = document.createElement('div');
    text.style.flex = '1';
    text.style.minWidth = '0';
    const title = document.createElement('div');
    title.className = 'd-title';
    title.textContent = ep.title || '';
    const meta = document.createElement('div');
    meta.className = 'd-meta';
    const dur = ep.duration_seconds ? ` · ${fmtTime(ep.duration_seconds)}` : '';
    meta.textContent = `${ep.feed_title || ''} · ${fmtDate(ep.pub_date)}${dur}`;
    text.append(title, meta);
    header.append(img, text);

    descEl.innerHTML = ep.description
      ? sanitizeHtml(ep.description, { allowRemoteMedia: allowRemoteImages })
      : '<p class="muted small">No description.</p>';
    setImgGateLabel();

    playBtn.disabled = ep.audio_available === 0;
    playBtn.textContent = ep.audio_available === 0 ? 'Audio unavailable' : '▶ Play';
    playBtn.onclick = () => { if (ep.audio_available !== 0) player.load(ep.id); };
  };
  if (cached) renderFrom(cached);
  else descEl.innerHTML = '<p class="muted small">loading…</p>';

  try {
    const { episode } = await api(`/api/episodes/${id}`);
    cachedEpisodesById.set(id, episode);
    renderFrom(episode);
  } catch (e) {
    if (!cached) descEl.innerHTML = `<p class="err small">Could not load: ${escapeHtml(e.message)}</p>`;
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  }[c]));
}

// -------- scrub bar (tap-to-seek) --------
function initScrubBar() {
  const bar = $('#scrubBar');
  const seek = (clientX) => {
    const rect = bar.getBoundingClientRect();
    const pct = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    const dur = player.audio.duration || player.episode?.duration_seconds || 0;
    if (dur > 0) player.audio.currentTime = pct * dur;
  };
  bar.addEventListener('pointerdown', (e) => {
    player.scrubbing = true;
    bar.setPointerCapture(e.pointerId);
    seek(e.clientX);
  });
  bar.addEventListener('pointermove', (e) => {
    if (player.scrubbing) seek(e.clientX);
  });
  bar.addEventListener('pointerup', (e) => {
    player.scrubbing = false;
    bar.releasePointerCapture(e.pointerId);
  });
  bar.addEventListener('pointercancel', () => { player.scrubbing = false; });
}

// -------- boot --------
let player;
(async () => {
  player = new Player($('#audio'), $('#playerVideo'));
  initScrubBar();

  $('#navLibrary').addEventListener('click', () => navigate('libraryView'));
  $('#navNowPlaying').addEventListener('click', () => { if (player.hasEpisode()) navigate('playerView'); });
  // The "‹ Library" affordance should behave like the browser back button.
  $('#backToLib').addEventListener('click', () => {
    if (history.state && history.state.view && history.state.view !== 'libraryView') history.back();
    else navigate('libraryView');
  });

  // Seed the history stack with the library view so the very first back press
  // doesn't leave the PWA scope (which on Tailscale-served deployments lands
  // on the login redirect — the bug we're fixing).
  history.replaceState({ view: 'libraryView' }, '');
  window.addEventListener('popstate', (e) => { restoreFromState(e.state); });

  setImgGateLabel();
  $('#detailsImgBtn').addEventListener('click', () => {
    allowRemoteImages = !allowRemoteImages;
    try { localStorage.setItem(IMG_GATE_KEY, allowRemoteImages ? '1' : '0'); } catch {}
    setImgGateLabel();
    if (currentDetailsEpId != null) {
      const cached = cachedEpisodesById.get(currentDetailsEpId);
      if (cached) renderEpisodeDetails(cached, { push: false });
    }
  });
  $('#backFromDetails').addEventListener('click', () => {
    if (history.state && history.state.view === 'detailsView') history.back();
    else navigate('libraryView');
  });
  const openCurrentDetails = () => {
    if (player.hasEpisode()) renderEpisodeDetails(player.episode);
  };
  $('#playerChapter').addEventListener('click', openCurrentDetails);
  $('#playerChapter').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openCurrentDetails(); }
  });

  $('#playBtn').addEventListener('click', () => player.toggle());
  $('#miniPlayBtn').addEventListener('click', (e) => { e.stopPropagation(); player.toggle(); });
  $('#miniPlayer').addEventListener('click', () => { if (player.hasEpisode()) navigate('playerView'); });
  $('#prevChBtn').addEventListener('click', () => player.jumpChapter(-1));
  $('#nextChBtn').addEventListener('click', () => player.jumpChapter(+1));
  $('#seekBackBtn').addEventListener('click', () => player.seekBy(-15));
  $('#seekFwdBtn').addEventListener('click',  () => player.seekBy(+30));
  $('#speedBtn').addEventListener('click', () => player.cycleSpeed());

  $('#playRandomBtn').addEventListener('click', playRandomUnplayed);
  $('#recentToggle').addEventListener('click', () => {
    recentExpanded = !recentExpanded;
    renderRecent();
  });

  $('#syncBtn').addEventListener('click', async () => {
    $('#syncStatus').textContent = 'syncing…';
    await api('/api/sync', { method: 'POST' });
    setTimeout(renderLibrary, 1500);
  });

  $('#addFeedBtn').addEventListener('click', () => {
    $('#addFeedErr').hidden = true;
    $('#feedUrl').value = '';
    $('#addFeedDialog').showModal();
  });
  $('#addFeedDialog').addEventListener('close', async () => {
    if ($('#addFeedDialog').returnValue !== 'ok') return;
    const url = $('#feedUrl').value.trim();
    if (!url) return;
    try {
      await api('/api/feeds', {
        method: 'POST',
        headers: {'content-type':'application/json'},
        body: JSON.stringify({ url })
      });
      renderLibrary();
    } catch (e) {
      alert(`Could not add feed: ${e.message}`);
    }
  });

  await renderLibrary();
  startPolling();
})();

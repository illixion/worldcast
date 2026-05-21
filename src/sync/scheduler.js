import { readdir, realpath } from 'node:fs/promises';
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { log } from '../util/log.js';
import { syncAllFeeds } from './rss.js';
import { extractChaptersForEpisode } from './chapters.js';
import { getLibraryRoot, fileUrlFromPath, safeFileUrlToPath } from '../util/local.js';
import { now } from '../db.js';

const queue = [];
const inFlight = new Set();
let workerCount = 0;
const MAX_CONCURRENCY = 2;
let ctxRef = null;

export function enqueueExtraction(episodeId) {
  if (inFlight.has(episodeId) || queue.includes(episodeId)) return;
  queue.push(episodeId);
  spawnWorkers();
}

function spawnWorkers() {
  while (workerCount < MAX_CONCURRENCY && queue.length > 0) {
    workerCount++;
    runWorker().catch(() => {}).finally(() => { workerCount--; });
  }
}

async function runWorker() {
  while (queue.length > 0) {
    const id = queue.shift();
    if (id == null) return;
    if (inFlight.has(id)) continue;
    inFlight.add(id);
    try {
      await extractChaptersForEpisode(ctxRef, id);
    } catch (e) {
      log.warn(`worker err ep ${id}: ${e.message}`);
    } finally {
      inFlight.delete(id);
    }
  }
}

/**
 * Walk the library directory and register any new *.xml as feeds. Existing
 * feeds whose file is missing get a warning but are NOT deleted — same as
 * we treat HTTP feeds that 404.
 *
 * Symlinked subdirectories are followed (Node's recursive readdir does not),
 * with a realpath-based cycle guard so a symlink loop can't spin forever.
 */
export async function scanLocalLibrary(ctx) {
  const root = getLibraryRoot();
  if (!root) return;

  const insert = ctx.db.prepare('INSERT OR IGNORE INTO feeds (url, created_at) VALUES (?, ?)');
  let added = 0;
  const visited = new Set();

  async function walk(dir) {
    let real;
    try { real = await realpath(dir); } catch { return; }
    if (visited.has(real)) return;
    visited.add(real);

    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); }
    catch (e) { log.warn(`library scan ${dir} failed: ${e.message}`); return; }

    for (const ent of entries) {
      const abs = join(dir, ent.name);
      let isDir = ent.isDirectory();
      let isFile = ent.isFile();
      if (ent.isSymbolicLink()) {
        try {
          const st = statSync(abs);
          isDir = st.isDirectory();
          isFile = st.isFile();
        } catch { continue; }
      }
      if (isDir) {
        await walk(abs);
      } else if (isFile && /\.xml$/i.test(ent.name)) {
        const url = fileUrlFromPath(abs);
        const info = insert.run(url, now());
        if (info.changes === 1) {
          added++;
          log.info(`library: registered ${abs.slice(root.length + 1)}`);
        }
      }
    }
  }

  await walk(root);
  if (added > 0) log.info(`library scan: ${added} new feed(s) added`);
}

/**
 * Re-stat every file:// episode and reconcile audio_available. A file that
 * went missing flips to 0; a file that came back flips to 1 and gets
 * re-queued for chapter extraction.
 */
function reconcileLocalAudio(ctx) {
  const rows = ctx.db.prepare(
    `SELECT id, audio_url, audio_available FROM episodes WHERE audio_url LIKE 'file://%'`
  ).all();
  let nowMissing = 0, nowAvailable = 0;
  const setAvail   = ctx.db.prepare(`UPDATE episodes SET audio_available=1 WHERE id=?`);
  const setMissing = ctx.db.prepare(
    `UPDATE episodes SET audio_available=0, chapters_error=COALESCE(chapters_error,'audio file missing') WHERE id=?`
  );
  for (const r of rows) {
    const p = safeFileUrlToPath(r.audio_url);
    let exists = false;
    if (p) { try { exists = statSync(p).isFile(); } catch { exists = false; } }
    if (exists && r.audio_available === 0) {
      setAvail.run(r.id);
      enqueueExtraction(r.id);
      nowAvailable++;
    } else if (!exists && r.audio_available === 1) {
      setMissing.run(r.id);
      nowMissing++;
    }
  }
  if (nowMissing || nowAvailable) {
    log.info(`reconcile: ${nowMissing} now missing, ${nowAvailable} now available`);
  }
}

export async function runFullSync(ctx) {
  log.info('full sync: starting');
  await scanLocalLibrary(ctx);
  const newIds = await syncAllFeeds(ctx);
  reconcileLocalAudio(ctx);
  for (const id of newIds) enqueueExtraction(id);
  log.info(`full sync: ${newIds.length} new episode(s), chapter queue length = ${queue.length}`);
  return newIds;
}

export function startScheduler({ db, dataDir, intervalMs }) {
  ctxRef = { db, dataDir };

  // Re-queue any previously-pending episodes (server may have crashed mid-extract).
  const pending = db.prepare(
    `SELECT id FROM episodes WHERE chapters_status = 'pending' ORDER BY id ASC LIMIT 500`
  ).all();
  for (const row of pending) enqueueExtraction(row.id);
  if (pending.length > 0) log.info(`scheduler: re-queued ${pending.length} pending chapter extraction(s)`);

  // Kick off an immediate full sync 5s after boot.
  setTimeout(() => runFullSync(ctxRef).catch(e => log.error('initial sync', e)), 5000);

  // Hourly thereafter.
  setInterval(() => {
    runFullSync(ctxRef).catch(e => log.error('scheduled sync', e));
  }, intervalMs);

  log.info(`scheduler: interval ${intervalMs}ms`);
}

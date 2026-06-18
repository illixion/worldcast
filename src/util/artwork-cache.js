import { writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { log } from './log.js';
import { extToMime } from './id3.js';

// Privacy goal: any remote image (feed/episode artwork) is fetched exactly
// once when first seen, written under data/artwork/, and from then on the
// browser only ever loads it from this server. The remote URL is never
// exposed to the client.

async function fetchRemoteImage(url) {
  if (!url || !/^https?:/i.test(url)) return null;
  try {
    const res = await fetch(url, {
      redirect: 'follow',
      headers: { 'User-Agent': 'worldcast/0.1 (+podcast PWA)' }
    });
    if (!res.ok) { log.warn(`artwork fetch ${url} → ${res.status}`); return null; }
    const mime = (res.headers.get('content-type') || 'image/jpeg').split(';')[0].trim();
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length === 0) return null;
    return { buf, mime };
  } catch (e) {
    log.warn(`artwork fetch ${url} failed: ${e.message}`);
    return null;
  }
}

/**
 * Ensure a cached copy of `remoteUrl` exists on disk for the given
 * (kind, id) pair. Returns { path, mime, changed } where `path` is relative
 * to data/artwork/, or null if nothing could be cached.
 *
 * Once cached we never refetch — the only condition that triggers a fetch
 * is currentPath being NULL or the on-disk file being gone.
 */
export async function ensureCachedImage({ dataDir, kind, id, remoteUrl, currentPath, currentMime }) {
  if (currentPath) {
    const abs = join(dataDir, 'artwork', currentPath);
    if (existsSync(abs)) {
      return { path: currentPath, mime: currentMime, changed: false };
    }
  }
  const fetched = await fetchRemoteImage(remoteUrl);
  if (!fetched) return null;
  const ext = extToMime(fetched.mime);
  const rel = join(kind, `${id}.${ext}`);
  const abs = join(dataDir, 'artwork', rel);
  await mkdir(dirname(abs), { recursive: true });
  await writeFile(abs, fetched.buf);
  return { path: rel, mime: fetched.mime, changed: true };
}

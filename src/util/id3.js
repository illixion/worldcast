import { open as fsOpen } from 'node:fs/promises';
import { log } from './log.js';
import { safeFileUrlToPath } from './local.js';

async function fetchRange(url, start, end, opts = {}) {
  const headers = { Range: `bytes=${start}-${end}` };
  const res = await fetch(url, { headers, redirect: 'follow', ...opts });
  if (!res.ok && res.status !== 206) {
    log.warn(`fetchRange ${url} ${start}-${end} → ${res.status}`);
    return null;
  }
  const ab = await res.arrayBuffer();
  return Buffer.from(ab);
}

function decodeSynchsafe(b0, b1, b2, b3) {
  return ((b0 & 0x7f) << 21) | ((b1 & 0x7f) << 14) | ((b2 & 0x7f) << 7) | (b3 & 0x7f);
}

const MAX_FALLBACK_BYTES = 8 * 1024 * 1024;

async function fetchId3FromHttp(audioUrl) {
  const head = await fetchRange(audioUrl, 0, 9);
  if (!head || head.length < 10) {
    log.warn('id3: could not fetch header bytes');
    return null;
  }
  if (head.toString('ascii', 0, 3) !== 'ID3') {
    return { buffer: head, hasTag: false };
  }
  const flags = head[5];
  const hasFooter = (flags & 0x10) !== 0;
  const tagSize = decodeSynchsafe(head[6], head[7], head[8], head[9]);
  const totalNeeded = 10 + tagSize + (hasFooter ? 10 : 0);
  const buf = await fetchRange(audioUrl, 0, totalNeeded - 1);
  if (!buf) {
    log.warn(`id3: range refused for ${audioUrl}, falling back to capped GET`);
    const fallback = await fetchRange(audioUrl, 0, MAX_FALLBACK_BYTES - 1);
    if (!fallback) return null;
    return { buffer: fallback, hasTag: true };
  }
  return { buffer: buf, hasTag: true };
}

async function fetchId3FromFile(audioUrl) {
  const p = safeFileUrlToPath(audioUrl);
  if (!p) {
    log.warn(`id3: refusing file:// audio outside library: ${audioUrl}`);
    return null;
  }
  let fd;
  try { fd = await fsOpen(p, 'r'); }
  catch (e) { log.warn(`id3: open ${p} failed: ${e.message}`); return null; }
  try {
    const head = Buffer.alloc(10);
    const { bytesRead } = await fd.read(head, 0, 10, 0);
    if (bytesRead < 10) return { buffer: head.slice(0, bytesRead), hasTag: false };
    if (head.toString('ascii', 0, 3) !== 'ID3') return { buffer: head, hasTag: false };
    const flags = head[5];
    const hasFooter = (flags & 0x10) !== 0;
    const tagSize = decodeSynchsafe(head[6], head[7], head[8], head[9]);
    const totalNeeded = 10 + tagSize + (hasFooter ? 10 : 0);
    const buf = Buffer.alloc(totalNeeded);
    await fd.read(buf, 0, totalNeeded, 0);
    return { buffer: buf, hasTag: true };
  } finally {
    await fd.close();
  }
}

export async function fetchId3TagBytes(audioUrl) {
  if (!audioUrl) return null;
  if (audioUrl.startsWith('file://')) return fetchId3FromFile(audioUrl);
  return fetchId3FromHttp(audioUrl);
}

export function extToMime(mime) {
  if (!mime) return 'jpg';
  const m = mime.toLowerCase();
  if (m.includes('png')) return 'png';
  if (m.includes('jpeg') || m.includes('jpg')) return 'jpg';
  if (m.includes('webp')) return 'webp';
  if (m.includes('gif')) return 'gif';
  return 'bin';
}

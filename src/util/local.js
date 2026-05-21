// Helpers for the local-library mode: file:// URL conversion and path-safety
// checks. All file:// access from feeds is gated on being inside the
// configured library root.

import { pathToFileURL, fileURLToPath } from 'node:url';
import { resolve, sep, dirname } from 'node:path';

let libraryRoot = null;

export function setLibraryRoot(absDir) {
  libraryRoot = absDir ? resolve(absDir) : null;
}

export function getLibraryRoot() {
  return libraryRoot;
}

export function isLibraryEnabled() {
  return Boolean(libraryRoot);
}

/**
 * Returns true if `p` (resolved) is textually inside the library root.
 * Symlinks are intentionally allowed: the check runs before symlink
 * resolution so a symlinked file or directory under the root passes, and
 * the OS follows the link when reading. `..` traversal is still blocked.
 * The user is trusted not to point symlinks at sensitive paths.
 */
export function isInsideLibrary(p) {
  if (!libraryRoot) return false;
  const abs = resolve(p);
  return abs === libraryRoot || abs.startsWith(libraryRoot + sep);
}

/**
 * Convert a file:// URL to an absolute path, validating it's inside the
 * library. Returns null if not allowed.
 */
export function safeFileUrlToPath(url) {
  if (!url || !url.startsWith('file://')) return null;
  let p;
  try { p = fileURLToPath(url); } catch { return null; }
  return isInsideLibrary(p) ? p : null;
}

/**
 * Resolve an enclosure URL that may be:
 *   - absolute (http(s)://… or file://…) → returned as-is (file:// validated)
 *   - relative (./ep01.mp3, episodes/x.mp3, ../shared/foo.mp3) → resolved
 *     against the feed's location, then validated against the library.
 * Returns the canonical URL string, or null if invalid / outside the library.
 */
export function resolveEnclosureUrl(rawUrl, feedUrl) {
  if (!rawUrl) return null;
  if (/^[a-z][a-z0-9+.\-]*:/i.test(rawUrl)) {
    // Has a scheme.
    if (rawUrl.startsWith('file://')) {
      return safeFileUrlToPath(rawUrl) ? rawUrl : null;
    }
    return rawUrl;
  }
  // No scheme — only meaningful when the feed itself is local.
  if (!feedUrl || !feedUrl.startsWith('file://')) return null;
  const feedDir = dirname(fileURLToPath(feedUrl));
  const abs = resolve(feedDir, rawUrl);
  if (!isInsideLibrary(abs)) return null;
  return pathToFileURL(abs).href;
}

export function fileUrlFromPath(p) {
  return pathToFileURL(p).href;
}

export { fileURLToPath };

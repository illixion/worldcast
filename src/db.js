import Database from 'better-sqlite3';
import { readFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

export function openDb(dbPath) {
  mkdirSync(dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('synchronous = NORMAL');
  const initSql = readFileSync(join(__dirname, 'init.sql'), 'utf8');
  db.exec(initSql);
  migrate(db);
  return db;
}

function migrate(db) {
  // Idempotent column additions for DBs created before a column existed.
  const epCols = db.prepare("PRAGMA table_info(episodes)").all();
  const epHas = (name) => epCols.some(c => c.name === name);
  if (!epHas('audio_available')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN audio_available INTEGER NOT NULL DEFAULT 1`);
  }
  if (!epHas('last_played_at')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN last_played_at INTEGER`);
  }
  if (!epHas('artwork_path')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN artwork_path TEXT`);
  }
  if (!epHas('artwork_mime')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN artwork_mime TEXT`);
  }
  // Client clock (epoch ms) of the most recent accepted position write. Lets
  // the position route reject out-of-order writes from a different device or a
  // late-arriving beacon, instead of blindly last-write-wins. NULL = unknown
  // (legacy rows / writes from clients that don't send a timestamp).
  if (!epHas('position_client_ts')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN position_client_ts INTEGER`);
  }
  const fCols = db.prepare("PRAGMA table_info(feeds)").all();
  const fHas = (name) => fCols.some(c => c.name === name);
  if (!fHas('artwork_path')) {
    db.exec(`ALTER TABLE feeds ADD COLUMN artwork_path TEXT`);
  }
  if (!fHas('artwork_mime')) {
    db.exec(`ALTER TABLE feeds ADD COLUMN artwork_mime TEXT`);
  }
}

export function now() { return Date.now(); }

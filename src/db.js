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
  const cols = db.prepare("PRAGMA table_info(episodes)").all();
  const has = (name) => cols.some(c => c.name === name);
  if (!has('audio_available')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN audio_available INTEGER NOT NULL DEFAULT 1`);
  }
  if (!has('last_played_at')) {
    db.exec(`ALTER TABLE episodes ADD COLUMN last_played_at INTEGER`);
  }
}

export function now() { return Date.now(); }

CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS feeds (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL UNIQUE,
  title TEXT,
  author TEXT,
  description TEXT,
  artwork_url TEXT,
  artwork_path TEXT,
  artwork_mime TEXT,
  last_synced_at INTEGER,
  last_etag TEXT,
  last_modified TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS episodes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  guid TEXT NOT NULL,
  title TEXT,
  description TEXT,
  audio_url TEXT NOT NULL,
  audio_length INTEGER,
  audio_type TEXT,
  duration_seconds REAL,
  pub_date INTEGER,
  artwork_url TEXT,
  artwork_path TEXT,
  artwork_mime TEXT,
  chapters_status TEXT NOT NULL DEFAULT 'pending',
  chapters_error TEXT,
  audio_available INTEGER NOT NULL DEFAULT 1,
  position_seconds REAL NOT NULL DEFAULT 0,
  played INTEGER NOT NULL DEFAULT 0,
  played_at INTEGER,
  last_played_at INTEGER,
  position_client_ts INTEGER,
  created_at INTEGER NOT NULL,
  UNIQUE(feed_id, guid)
);

CREATE INDEX IF NOT EXISTS idx_episodes_feed_pub ON episodes(feed_id, pub_date DESC);
CREATE INDEX IF NOT EXISTS idx_episodes_chapters_status ON episodes(chapters_status);

CREATE TABLE IF NOT EXISTS chapters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  title TEXT,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER,
  url TEXT,
  artwork_path TEXT,
  artwork_mime TEXT,
  UNIQUE(episode_id, ordinal)
);

INSERT OR IGNORE INTO schema_version (version) VALUES (1);

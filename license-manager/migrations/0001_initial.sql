CREATE TABLE IF NOT EXISTS licences (
  id TEXT PRIMARY KEY,
  expires TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  token TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status TEXT NOT NULL DEFAULT 'active'
);
CREATE INDEX IF NOT EXISTS idx_licences_created_at ON licences(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_licences_fingerprint ON licences(fingerprint);

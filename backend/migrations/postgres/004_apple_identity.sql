CREATE TABLE IF NOT EXISTS apple_identities (subject TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS apple_identities_owner ON apple_identities(user_id);
CREATE TABLE IF NOT EXISTS apple_challenges (hash TEXT PRIMARY KEY, nonce TEXT NOT NULL, audience TEXT NOT NULL, expires_at BIGINT NOT NULL, flow_hash TEXT);

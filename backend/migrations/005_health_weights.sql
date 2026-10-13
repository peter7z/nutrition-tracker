CREATE TABLE health_weight_consent (user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, enabled INTEGER NOT NULL, version INTEGER NOT NULL);
CREATE TABLE health_weights (user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, sample_id TEXT NOT NULL, version INTEGER NOT NULL, payload TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(user_id,sample_id));

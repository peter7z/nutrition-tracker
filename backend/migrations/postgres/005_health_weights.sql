CREATE TABLE health_weight_consent (user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, enabled INTEGER NOT NULL, version INTEGER NOT NULL);
CREATE TABLE health_weights (user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, sample_id TEXT NOT NULL, version INTEGER NOT NULL, payload TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(user_id,sample_id));
ALTER TABLE health_weight_consent ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_weights ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON health_weight_consent, health_weights FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN REVOKE ALL ON health_weight_consent, health_weights FROM anon; END IF;
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN REVOKE ALL ON health_weight_consent, health_weights FROM authenticated; END IF;
END $$;

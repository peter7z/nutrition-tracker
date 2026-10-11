-- Anonymous daily aggregate survives account deletion; no owner, prompt, image or health data.
CREATE TABLE IF NOT EXISTS global_spend (day TEXT PRIMARY KEY, amount DOUBLE PRECISION NOT NULL);
INSERT INTO global_spend(day,amount)
SELECT substr(created_at,1,10),SUM(CASE WHEN status='completed' THEN cost ELSE reserved END)
FROM ai_usage GROUP BY substr(created_at,1,10) ON CONFLICT(day) DO NOTHING;

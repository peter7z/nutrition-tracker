import hashlib
import json
import pathlib
import os
import sqlite3
from contextlib import contextmanager

class Store:
    def __init__(self, path):
        self.path = path
        pathlib.Path(path).parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with self.connect() as db:
            db.execute('CREATE TABLE IF NOT EXISTS migrations(version INTEGER PRIMARY KEY)')
            if not db.execute('SELECT 1 FROM migrations WHERE version=1').fetchone():
                db.executescript((pathlib.Path(__file__).parent.parent / 'migrations/001_initial.sql').read_text())
                db.execute('INSERT INTO migrations VALUES(1)')
            if not db.execute('SELECT 1 FROM migrations WHERE version=2').fetchone():
                db.executescript((pathlib.Path(__file__).parent.parent / 'migrations/002_global_spend.sql').read_text())
                db.execute('INSERT INTO migrations VALUES(2)')
        os.chmod(path,0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA secure_delete=ON')
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)

def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()

def state(db, owner):
    revision = db.execute('SELECT revision FROM users WHERE id=?', (owner,)).fetchone()['revision']
    records = [dict(id=r['id'],kind=r['kind'],version=r['version'],payload=json.loads(r['payload'])) for r in db.execute('SELECT * FROM records WHERE user_id=? AND deleted=0 ORDER BY id',(owner,))]
    messages = [dict(id=r['id'],request_id=r['request_id'],role=r['role'],content=r['content'],day=r['day'],created_at=r['created_at'],proposals=json.loads(r['proposals'])) for r in db.execute('SELECT * FROM messages WHERE user_id=? ORDER BY created_at,id',(owner,))]
    return dict(revision=revision, records=records, messages=messages)

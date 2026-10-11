import hashlib
import json
import pathlib
import os
import sqlite3
import psycopg
from psycopg.rows import dict_row

INTEGRITY_ERRORS = (sqlite3.IntegrityError, psycopg.IntegrityError)

class Record(dict):
    def __getitem__(self, key):
        return list(self.values())[key] if isinstance(key, int) else super().__getitem__(key)

def record_row(cursor):
    factory = dict_row(cursor)
    return lambda values: Record(factory(values))

class PostgresConnection:
    def __init__(self, connection):
        self.connection = connection

    def execute(self, query, parameters=()):
        if query == "BEGIN IMMEDIATE":
            return self.connection.execute("SELECT 1")
        return self.connection.execute(query.replace("?", "%s").replace("MAX(0,amount-", "GREATEST(0,amount-"), parameters)

from contextlib import contextmanager

class Store:
    def __init__(self, path):
        self.path = path
        self.postgres = path.startswith(('postgres://', 'postgresql://'))
        if self.postgres:
            with self.connect() as db:
                db.execute('CREATE TABLE IF NOT EXISTS migrations(version INTEGER PRIMARY KEY)')
                for version, name in ((1, '001_initial.sql'), (2, '002_global_spend.sql'), (3, '003_plugin_oauth.sql')):
                    if not db.execute('SELECT 1 FROM migrations WHERE version=?', (version,)).fetchone():
                        script = (pathlib.Path(__file__).parent.parent / 'migrations/postgres' / name).read_text()
                        db.connection.execute(script)
                        db.execute('INSERT INTO migrations VALUES(?)', (version,))
            return
        pathlib.Path(path).parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with self.connect() as db:
            db.execute('CREATE TABLE IF NOT EXISTS migrations(version INTEGER PRIMARY KEY)')
            if not db.execute('SELECT 1 FROM migrations WHERE version=1').fetchone():
                db.executescript((pathlib.Path(__file__).parent.parent / 'migrations/001_initial.sql').read_text())
                db.execute('INSERT INTO migrations VALUES(1)')
            if not db.execute('SELECT 1 FROM migrations WHERE version=2').fetchone():
                db.executescript((pathlib.Path(__file__).parent.parent / 'migrations/002_global_spend.sql').read_text())
                db.execute('INSERT INTO migrations VALUES(2)')
            if not db.execute('SELECT 1 FROM migrations WHERE version=3').fetchone():
                db.executescript((pathlib.Path(__file__).parent.parent / 'migrations/003_plugin_oauth.sql').read_text())
                db.execute('INSERT INTO migrations VALUES(3)')
        os.chmod(path,0o600)

    @contextmanager
    def connect(self):
        if self.postgres:
            with psycopg.connect(self.path, row_factory=record_row, connect_timeout=10) as connection:
                # Preserve SQLite's serialized write semantics for revisions, idempotency
                # and global budget reservations. Released on commit or rollback.
                connection.execute('SELECT pg_advisory_xact_lock(727410001)')
                yield PostgresConnection(connection)
            return
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

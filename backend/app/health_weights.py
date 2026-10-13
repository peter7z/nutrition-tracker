"""Explicitly consented HealthKit weight copy, isolated from manual tracking writes."""
import json
from datetime import datetime
from uuid import UUID,uuid5,NAMESPACE_URL
from fastapi import Depends
from pydantic import Field,field_validator,model_validator
from .models import StrictModel,Nutrition,EntryDraft
from .store import canonical,digest

class WeightConsent(StrictModel):
    enabled: bool = Field(strict=True)
    delete_data: bool = Field(default=False,strict=True)
    @model_validator(mode='after')
    def consistent(self):
        if self.enabled and self.delete_data: raise ValueError('disable before deleting')
        return self

class HealthWeight(StrictModel):
    sample_id: UUID
    recorded_at: datetime
    kilograms: float = Field(gt=0,lt=1000)
    @field_validator('kilograms',mode='before')
    @classmethod
    def numeric(cls,value): return Nutrition.numeric(value)
    @field_validator('recorded_at')
    @classmethod
    def timestamp(cls,value): return EntryDraft.timezone(value)

class WeightUpload(StrictModel):
    request_id: UUID
    consent_version: int = Field(ge=1,strict=True)
    samples: list[HealthWeight] = Field(max_length=500)
    deleted_ids: list[UUID] = Field(max_length=10000)
    @model_validator(mode='after')
    def unique(self):
        ids=[item.sample_id for item in self.samples]
        if len(set(ids))!=len(ids) or len(set(self.deleted_ids))!=len(self.deleted_ids): raise ValueError('duplicate IDs')
        return self

def weight_records(db,owner):
    return [{'id':str(uuid5(NAMESPACE_URL,'health-weight:'+row['sample_id'])),
        'kind':'weight','version':row['version'],'payload':json.loads(row['payload'])}
        for row in db.execute('SELECT * FROM health_weights WHERE user_id=? AND deleted=0 ORDER BY sample_id',(owner,))]

def consent(db,owner):
    row=db.execute('SELECT enabled,version FROM health_weight_consent WHERE user_id=?',(owner,)).fetchone()
    return {'enabled':bool(row['enabled']) if row else False,'version':row['version'] if row else 0}

def install_weight_routes(app,store,identity,APIError):
    @app.get('/v1/health/weight/consent')
    def get_consent(owner=Depends(identity)):
        with store.connect() as db: return consent(db,owner)

    @app.post('/v1/health/weight/consent')
    def set_consent(body:WeightConsent,owner=Depends(identity)):
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            previous=consent(db,owner)
            version=previous['version']+int(previous['enabled']!=body.enabled or body.delete_data or previous['version']==0)
            db.execute('INSERT INTO health_weight_consent VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET enabled=excluded.enabled,version=excluded.version',(owner,int(body.enabled),version))
            if body.delete_data:
                removed=db.execute('SELECT COUNT(*) FROM health_weights WHERE user_id=?',(owner,)).fetchone()[0]
                db.execute('DELETE FROM health_weights WHERE user_id=?',(owner,))
                db.execute("DELETE FROM requests WHERE user_id=? AND route='health-weight'",(owner,))
                if removed: db.execute('UPDATE users SET revision=revision+1 WHERE id=?',(owner,))
            return consent(db,owner)

    @app.post('/v1/health/weight/sync')
    def upload(body:WeightUpload,owner=Depends(identity)):
        wire=body.model_dump(mode='json');rid=str(body.request_id)
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            permission=consent(db,owner)
            if not permission['enabled'] or permission['version']!=body.consent_version: raise APIError('weight_consent_required',403)
            previous=db.execute("SELECT digest,result FROM requests WHERE user_id=? AND id=? AND route='health-weight'",(owner,rid)).fetchone()
            if previous:
                if previous['digest']!=digest(wire): raise APIError('idempotency_conflict',409)
                return json.loads(previous['result'])
            changed=False
            for sample in body.samples:
                sid=str(sample.sample_id)
                existing=db.execute('SELECT * FROM health_weights WHERE user_id=? AND sample_id=?',(owner,sid)).fetchone()
                if existing and existing['deleted']: continue  # A delayed device must not resurrect a deleted sample.
                payload={'id':str(uuid5(NAMESPACE_URL,'health-weight:'+sid)),'recordedAt':sample.recorded_at.isoformat(),
                    'kilograms':sample.kilograms,'source':'appleHealth','sourceSampleID':sid,'notes':'','importBatchID':None}
                encoded=canonical(payload)
                if existing and existing['payload']==encoded: continue
                version=existing['version']+1 if existing else 1
                db.execute('INSERT INTO health_weights VALUES(?,?,?,?,0) ON CONFLICT(user_id,sample_id) DO UPDATE SET version=excluded.version,payload=excluded.payload',(owner,sid,version,encoded));changed=True
            for sid in map(str,body.deleted_ids):
                existing=db.execute('SELECT * FROM health_weights WHERE user_id=? AND sample_id=?',(owner,sid)).fetchone()
                if existing and existing['deleted']: continue
                db.execute('INSERT INTO health_weights VALUES(?,?,?,?,1) ON CONFLICT(user_id,sample_id) DO UPDATE SET version=excluded.version,payload=excluded.payload,deleted=1',
                    (owner,sid,existing['version']+1 if existing else 1,'{}'));changed=True
            if changed: db.execute('UPDATE users SET revision=revision+1 WHERE id=?',(owner,))
            result={'saved':True,'request_id':rid,'revision':db.execute('SELECT revision FROM users WHERE id=?',(owner,)).fetchone()['revision']}
            db.execute('INSERT INTO requests VALUES(?,?,?,?,?)',(owner,rid,'health-weight',digest(wire),canonical(result)))
            return result

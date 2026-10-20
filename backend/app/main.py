import hashlib
import io
import json
import logging
import secrets
import time
import uuid
from collections import defaultdict,deque
from datetime import date,datetime,timedelta,timezone
from pathlib import Path
from zoneinfo import ZoneInfo
from fastapi import Depends,FastAPI,File,Request,UploadFile
from fastapi.responses import FileResponse,JSONResponse,Response
from fastapi.staticfiles import StaticFiles
from fastapi.exceptions import RequestValidationError
from PIL import Image,ImageOps,UnidentifiedImageError
from pydantic import ValidationError
from .config import Settings
from .store import INTEGRITY_ERRORS,Store,canonical,digest,state
from .models import AuthInput,SyncInput,ChatInput,EntryDraft,FoodBatchInput
from .nutrition import context_for,validate_payload,NUTRIENTS,NUTRIENT_UNITS
from .assistant import ResponsesClient,AIError,guard_output
from .food_logging import build_food_sync,is_hypothetical

Image.MAX_IMAGE_PIXELS=20_000_000
logger=logging.getLogger('nutrition')

def now(): return datetime.now(timezone.utc)
def stamp(): return now().isoformat()

class APIError(Exception):
    def __init__(self,code,status=400): self.code=code; self.status=status

def password_hash(password,salt=None):
    salt=salt or secrets.token_hex(16)
    return salt+':'+hashlib.scrypt(password.encode(),salt=bytes.fromhex(salt),n=16384,r=8,p=1).hex()

def create_app(settings=None,ai=None):
    settings=settings or Settings()
    store=Store(settings.database)
    provider=ai or ResponsesClient(settings)
    app=FastAPI(title='Bocado Log',version='1.0.0',docs_url='/docs' if settings.environment=='development' else None,redoc_url=None,openapi_url='/openapi.json' if settings.environment=='development' else None)
    app.state.store=store
    auth_attempts=defaultdict(deque)

    @app.exception_handler(APIError)
    async def error_handler(request,error):
        return JSONResponse(status_code=error.status,content={'error':{'code':error.code,'message':'Request could not be completed.'}})
    @app.exception_handler(RequestValidationError)
    async def validation_handler(request,error):
        # Default FastAPI errors can reflect sensitive input; keep errors generic.
        return JSONResponse(status_code=422,content={'error':{'code':'invalid_input','message':'Check the supplied fields.'}})

    @app.middleware('http')
    async def security(request,call_next):
        if settings.environment=='production' and request.url.scheme!='https' and request.url.path not in ('/healthz','/health'):
            return JSONResponse(status_code=400,content={'error':{'code':'https_required','message':'HTTPS required.'}})
        length=request.headers.get('content-length')
        if length and (not length.isdigit() or int(length)>11_000_000):
            return JSONResponse(status_code=413,content={'error':{'code':'request_too_large','message':'Request too large.'}})
        received=0
        original_receive=request._receive
        async def limited_receive():
            nonlocal received
            message=await original_receive()
            received+=len(message.get('body',b''))
            if received>11_000_000: raise APIError('request_too_large',413)
            return message
        request._receive=limited_receive
        response=await call_next(request)
        response.headers['Cache-Control']='no-store'
        response.headers['X-Content-Type-Options']='nosniff'
        return response

    def identity(request:Request):
        token=request.headers.get('authorization','')
        if not token.startswith('Bearer ') or len(token)>1000: raise APIError('authentication_required',401)
        hashed=hashlib.sha256(token[7:].encode()).hexdigest()
        with store.connect() as db:
            r=db.execute('SELECT user_id FROM sessions WHERE hash=? AND expires_at>?',(hashed,stamp())).fetchone()
        if not r: raise APIError('invalid_session',401)
        return r['user_id']

    def auth_limit(request):
        key=request.client.host if request.client else 'unknown'
        q=auth_attempts[key]
        while q and q[0]<time.monotonic()-60: q.popleft()
        if len(q)>=settings.auth_per_minute: raise APIError('auth_rate_limit',429)
        q.append(time.monotonic())
        # Limit untrusted unique-IP memory growth.
        if len(auth_attempts)>10000:
            for key in list(auth_attempts):
                if not auth_attempts[key] or auth_attempts[key][-1]<time.monotonic()-60: del auth_attempts[key]

    def make_session(db,owner):
        token=secrets.token_urlsafe(48)
        expiry=(now()+timedelta(days=settings.session_days)).isoformat()
        db.execute('INSERT INTO sessions VALUES(?,?,?)',(hashlib.sha256(token.encode()).hexdigest(),owner,expiry))
        return dict(token=token,user_id=owner,expires_at=expiry)

    @app.get('/health')
    @app.get('/healthz')
    def healthz():
        with store.connect() as db: db.execute('SELECT 1').fetchone()
        return {'status':'ok','schema_version':5}

    @app.post('/v1/auth/signup',status_code=201)
    def signup(body:AuthInput,request:Request):
        auth_limit(request)
        owner=str(uuid.uuid4())
        hashed=password_hash(body.password)
        try:
            with store.connect() as db:
                db.execute('INSERT INTO users(id,email,password,created_at) VALUES(?,?,?,?)',(owner,body.email,hashed,stamp()))
                return make_session(db,owner)
        except INTEGRITY_ERRORS: raise APIError('signup_unavailable',409) from None

    @app.post('/v1/auth/login')
    def login(body:AuthInput,request:Request):
        auth_limit(request)
        with store.connect() as db:
            user=db.execute('SELECT * FROM users WHERE email=?',(body.email,)).fetchone()
            saved=user['password'] if user else password_hash('dummy password for constant work',salt='00'*16)
            checked=password_hash(body.password,saved.split(':')[0])
            if not user or not secrets.compare_digest(checked,saved): raise APIError('invalid_credentials',401)
            return make_session(db,user['id'])

    @app.post('/v1/auth/logout')
    def logout(request:Request,owner=Depends(identity)):
        with store.connect() as db: db.execute('DELETE FROM sessions WHERE hash=?',(hashlib.sha256(request.headers['authorization'][7:].encode()).hexdigest(),))
        return {'ok':True}

    @app.delete('/v1/account')
    def delete_account(owner=Depends(identity)):
        with store.connect() as db: db.execute('DELETE FROM users WHERE id=?',(owner,))
        return {'ok':True}

    @app.get('/v1/state')
    def get_state(owner=Depends(identity)):
        with store.connect() as db: return state(db,owner)

    @app.get('/web',include_in_schema=False)
    @app.get('/',include_in_schema=False)
    def web_diary():
        return FileResponse(Path(__file__).parent/'web'/'index.html',headers={
            'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
            'Referrer-Policy':'no-referrer'})

    app.mount('/web/assets',StaticFiles(directory=Path(__file__).parent/'web'),name='web-assets')

    @app.get('/v1/diary')
    def get_diary(day:date | None=None,owner=Depends(identity)):
        from zoneinfo import ZoneInfo
        with store.connect() as db:
            if day is None:
                profile,_=context_for(db,owner,'1900-01-01')
                day=now().astimezone(ZoneInfo(profile['time_zone'])).date()
            context,_=context_for(db,owner,day.isoformat())
            for entry in context['entries']:
                draft=EntryDraft.model_validate(entry['draft'])
                entry['totals']={key:getattr(draft.nutrition,key)*draft.multiplier() if getattr(draft.nutrition,key) is not None else None for key in NUTRIENTS}
            revision=db.execute('SELECT revision FROM users WHERE id=?',(owner,)).fetchone()['revision']
        return {'revision':revision,**context}

    def replay(db,owner,request_id,route,body):
        old=db.execute('SELECT * FROM requests WHERE user_id=? AND id=? AND route=?',(owner,request_id,route)).fetchone()
        if old:
            if old['digest']!=digest(body): raise APIError('idempotency_conflict',409)
            result=json.loads(old['result'])
            if result.get('_pending'): raise APIError('request_in_progress',409)
            if result.get('_error'): raise APIError(result['_error'],result['_status'])
            return result
        return None

    def capture_day_snapshot(db,owner,day):
        """Append a correctable snapshot of the selected totals for a past day."""
        context,_=context_for(db,owner,day)
        rows=list(db.execute("SELECT * FROM records WHERE user_id=?",(owner,)))
        profile=next((json.loads(row['payload']) for row in rows if row['kind']=='profile' and not row['deleted']),{})
        from zoneinfo import ZoneInfo
        try: zone=ZoneInfo(profile.get('timeZoneIdentifier','America/Montevideo'))
        except Exception: zone=ZoneInfo('America/Montevideo')
        aggregate={key:{'known':0,'knownCount':0,'missingCount':0} for key in NUTRIENTS}
        entry_versions={}; entry_count=0
        for row in rows:
            if row['kind']!='entry': continue
            payload=json.loads(row['payload'])
            draft=EntryDraft.model_validate(payload.get('draft',payload))
            if draft.consumedAt.astimezone(zone).date().isoformat()!=day: continue
            entry_versions[payload.get('id',row['id'])]=payload.get('version',row['version'])
            if row['deleted']: continue
            entry_count+=1
            for key in NUTRIENTS:
                value=getattr(draft.nutrition,key)
                if value is None: aggregate[key]['missingCount']+=1
                else:
                    aggregate[key]['known']+=value*draft.multiplier()
                    aggregate[key]['knownCount']+=1
        historical=[json.loads(row['payload']) for row in rows if row['kind']=='historical' and not row['deleted'] and json.loads(row['payload']).get('dayID')==day]
        selected=context.get('intake_selection','manual')
        if selected=='health' or context.get('needs_reconciliation'):
            return False
        if selected=='historical' and len(historical)==1:
            nutrients=historical[0].get('nutrients',{})
            aggregate={key:{'known':nutrients.get(key) or 0,'knownCount':int(nutrients.get(key) is not None),'missingCount':int(nutrients.get(key) is None)} for key in NUTRIENTS}
            entry_count=0
        elif selected!='manual':
            aggregate={key:{'known':0,'knownCount':0,'missingCount':0} for key in NUTRIENTS}
            entry_count=0
        aggregate['entryCount']=entry_count
        matches=[]
        for row in db.execute("SELECT * FROM records WHERE user_id=? AND kind='day' AND deleted=0",(owner,)):
            payload=json.loads(row['payload'])
            if str(payload.get('date',payload.get('day',payload.get('id',''))))[:10]==day:
                matches.append((row,payload))
        has_entry_record=bool(entry_versions)
        has_prior_snapshot=bool(matches and matches[0][1].get('summaries'))
        if not entry_count and not historical and not has_entry_record and not has_prior_snapshot:
            return False
        goals=context.get('goals') or {}
        complete=bool(selected=='historical' and len(historical)==1 and historical[0].get('isComplete',historical[0].get('isClosed')) is True
            and all(historical[0].get('nutrients',{}).get(key) is not None for key in ('energy','protein','carbohydrates','fat')))
        summary={'id':str(uuid.uuid4()),'version':1,'closedAt':stamp(),
            'completeness':'complete' if complete else 'incomplete','intakeSource':selected,
            'goalVersionID':goals.get('id'),'totals':aggregate,'entryVersions':entry_versions}
        if matches:
            row,payload=matches[0]
            payload.pop('isClosed',None); payload.pop('status',None)
            summaries=list(payload.get('summaries',[]))
            if summaries and summaries[-1].get('totals')==aggregate and summaries[-1].get('entryVersions')==entry_versions:
                return False
            summary['version']=len(summaries)+1
            summaries.append(summary)
            payload.update({'id':day,'version':int(payload.get('version',1))+1,'summaries':summaries})
            db.execute('UPDATE records SET version=?,payload=? WHERE user_id=? AND id=?',(row['version']+1,canonical(payload),owner,row['id']))
        else:
            identifier=str(uuid.uuid5(uuid.NAMESPACE_URL,'closed-day:'+owner+':'+day))
            payload={'id':day,'version':1,'summaries':[summary]}
            db.execute('INSERT INTO records VALUES(?,?,?,?,?,0)',(owner,identifier,'day',1,canonical(payload)))
        return True

    @app.post('/v1/sync')
    def sync(body:SyncInput,owner=Depends(identity)):
        wire=body.model_dump(mode='json'); rid=str(body.request_id)
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=replay(db,owner,rid,'sync',wire)
            if old is not None: return old
            revision=db.execute('SELECT revision FROM users WHERE id=?',(owner,)).fetchone()['revision']
            if revision!=body.base_revision: raise APIError('revision_conflict',409)
            ack=[]; changed=False; affected_entry_days=set(); first_ingest_days=set()
            for op in body.operations:
                oid=str(op.operation_id); eid=str(op.id); od=digest(op.model_dump(mode='json'))
                prior=db.execute('SELECT digest FROM operations WHERE user_id=? AND id=?',(owner,oid)).fetchone()
                if prior:
                    if prior['digest']!=od: raise APIError('operation_id_conflict',409)
                    ack.append(oid); continue
                existing=db.execute('SELECT * FROM records WHERE user_id=? AND id=?',(owner,eid)).fetchone()
                version=existing['version'] if existing else 0
                if version!=op.expected_version or (existing and existing['kind']!=op.kind): raise APIError('version_conflict',409)
                if op.action=='delete' and (not existing or existing['deleted']): raise APIError('record_not_found',404)
                try:
                    if op.action=='upsert': draft=validate_payload(op.kind,op.payload,eid)
                    else: draft=EntryDraft.model_validate(json.loads(existing['payload']).get('draft',json.loads(existing['payload']))) if op.kind=='entry' else None
                except (ValueError,ValidationError,TypeError): raise APIError('invalid_record',422) from None
                if op.kind=='entry':
                    context,_=context_for(db,owner,'1900-01-01')
                    from zoneinfo import ZoneInfo
                    zone=ZoneInfo(context['time_zone'])
                    incoming_day=draft.consumedAt.astimezone(zone).date().isoformat()
                    affected=[incoming_day]
                    if existing:
                        prev=EntryDraft.model_validate(json.loads(existing['payload']).get('draft',json.loads(existing['payload'])))
                        previous_day=prev.consumedAt.astimezone(zone).date().isoformat()
                        affected.append(previous_day)
                    else: previous_day=None
                    affected_entry_days.update(affected)
                    if op.action=='upsert' and (not existing or existing['deleted'] or previous_day!=incoming_day):
                        others=list(db.execute("SELECT payload FROM records WHERE user_id=? AND kind='entry' AND deleted=0 AND id<>?",(owner,eid)))
                        has_existing_day=any(EntryDraft.model_validate(json.loads(row['payload']).get('draft',json.loads(row['payload']))).consumedAt.astimezone(zone).date().isoformat()==incoming_day for row in others)
                        if not has_existing_day and not (existing and not existing['deleted'] and previous_day==incoming_day): first_ingest_days.add(incoming_day)
                if existing and op.action=='upsert':
                    previous=json.loads(existing['payload'])
                    old_version=previous.get('version'); new_version=op.payload.get('version')
                    if old_version is not None and new_version is not None and (isinstance(new_version,bool) or not isinstance(new_version,int) or new_version<=old_version) and op.payload!=previous:
                        raise APIError('domain_version_conflict',409)
                outgoing=dict(op.payload)
                payload=canonical(outgoing) if op.action=='upsert' else existing['payload']
                db.execute('INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(user_id,id) DO UPDATE SET version=excluded.version,payload=excluded.payload,deleted=excluded.deleted',(owner,eid,op.kind,version+1,payload,int(op.action=='delete')))
                db.execute('INSERT INTO operations VALUES(?,?,?)',(owner,oid,od)); ack.append(oid); changed=True
            snapshot_days=set()
            for ingested_day in first_ingest_days:
                snapshot_days.add((date.fromisoformat(ingested_day)-timedelta(days=1)).isoformat())
            for affected_day in affected_entry_days:
                if affected_day<now().astimezone(zone).date().isoformat(): snapshot_days.add(affected_day)
                if db.execute("SELECT 1 FROM records WHERE user_id=? AND kind='day' AND deleted=0",(owner,)).fetchone():
                    if any(str(json.loads(row['payload']).get('id',''))[:10]==affected_day and json.loads(row['payload']).get('summaries') for row in db.execute("SELECT payload FROM records WHERE user_id=? AND kind='day' AND deleted=0",(owner,))):
                        snapshot_days.add(affected_day)
            for snapshot_day in sorted(snapshot_days):
                if capture_day_snapshot(db,owner,snapshot_day): changed=True
            if changed: db.execute('UPDATE users SET revision=revision+1 WHERE id=?',(owner,))
            result=state(db,owner); result.pop('messages'); result['acknowledged_operation_ids']=ack
            db.execute('INSERT INTO requests VALUES(?,?,?,?,?)',(owner,rid,'sync',digest(wire),canonical(result)))
            return result

    @app.post('/v1/foods')
    def record_foods(body:FoodBatchInput,owner=Depends(identity)):
        if is_hypothetical(body.consumption_text): raise APIError('hypothetical_not_recorded',422)
        wire=build_food_sync(body.operation_id,body.base_revision,body.foods)
        with store.connect() as db:
            profile,_=context_for(db,owner,body.foods[0].consumed_at.date().isoformat())
        zone=ZoneInfo(profile['time_zone'])
        local_days={food.consumed_at.astimezone(zone).date().isoformat() for food in body.foods}
        if len(local_days)!=1: raise APIError('foods_must_share_day',422)
        day=next(iter(local_days))
        result=sync(wire,owner)
        records_by_id={record['id']:record for record in result['records'] if record['kind']=='entry'}
        entries=[]
        for operation in wire.operations:
            record=records_by_id.get(str(operation.id))
            if not record: raise APIError('food_receipt_unavailable',500)
            draft=EntryDraft.model_validate(record['payload'].get('draft',record['payload']))
            entries.append({'id':record['id'],'version':record['payload'].get('version',record['version']),
                'draft':draft.model_dump(mode='json',exclude={'productID','productVersion','recipeID','recipeVersion'}),
                'totals':{key:getattr(draft.nutrition,key)*draft.multiplier() if getattr(draft.nutrition,key) is not None else None for key in NUTRIENTS}})
        with store.connect() as db:
            context,_=context_for(db,owner,day)
            revision=db.execute('SELECT revision FROM users WHERE id=?',(owner,)).fetchone()['revision']
        for entry in context['entries']:
            draft=EntryDraft.model_validate(entry['draft'])
            entry['totals']={key:getattr(draft.nutrition,key)*draft.multiplier() if getattr(draft.nutrition,key) is not None else None for key in NUTRIENTS}
        day_summary={key:context[key] for key in (
            'day','time_zone','totals','goals','needs_reconciliation','intake_selection','entries')}
        day_summary.update(nutrient_units=NUTRIENT_UNITS,revision=revision)
        return {'saved':True,'operation_id':str(body.operation_id),
            'entry_ids':[str(operation.id) for operation in wire.operations],
            'entries':entries,'revision':revision,'receipt':result['acknowledged_operation_ids'],
            'source':'nutrition-tracker-backend','day_summary':day_summary}

    @app.post('/v1/attachments',status_code=201)
    async def upload(file:UploadFile=File(...),owner=Depends(identity)):
        raw=await file.read(10_000_001)
        await file.close()
        if len(raw)>10_000_000: raise APIError('image_too_large',413)
        try:
            with Image.open(io.BytesIO(raw)) as im:
                if im.format not in ('JPEG','PNG','WEBP') or getattr(im,'n_frames',1)>1: raise ValueError()
                if im.width*im.height>20_000_000: raise ValueError()
                im=ImageOps.exif_transpose(im).convert('RGB')
                # New image removes metadata, thumbnails and ancillary chunks.
                clean=Image.new('RGB',im.size); clean.paste(im)
                clean.thumbnail((2048,2048))
                buf=io.BytesIO(); clean.save(buf,format='JPEG',quality=85)
                image=buf.getvalue(); width,height=clean.size
        except (ValueError,UnidentifiedImageError,OSError,Image.DecompressionBombError): raise APIError('unsupported_image',422) from None
        aid=str(uuid.uuid4())
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            usage=db.execute('SELECT COUNT(*),COALESCE(SUM(LENGTH(image)),0) FROM attachments WHERE user_id=?',(owner,)).fetchone()
            if usage[0]>=100 or usage[1]+len(image)>100_000_000: raise APIError('attachment_storage_limit',429)
            db.execute('INSERT INTO attachments VALUES(?,?,?,?,?)',(aid,owner,image,width,height))
        return dict(id=aid,media_type='image/jpeg',width=width,height=height)

    @app.get('/v1/attachments/{identifier}')
    def read_attachment(identifier:uuid.UUID,owner=Depends(identity)):
        with store.connect() as db: row=db.execute('SELECT image FROM attachments WHERE id=? AND user_id=?',(str(identifier),owner)).fetchone()
        if not row: raise APIError('attachment_not_found',404)
        return Response(row['image'],media_type='image/jpeg')

    @app.delete('/v1/attachments/{identifier}')
    def delete_attachment(identifier:uuid.UUID,owner=Depends(identity)):
        with store.connect() as db:
            result=db.execute('DELETE FROM attachments WHERE id=? AND user_id=?',(str(identifier),owner))
            if not result.rowcount: raise APIError('attachment_not_found',404)
        return {'ok':True}

    def perform_chat(body,owner,review=False):
        rid=str(body.request_id); route='review' if review else 'chat'; wire=body.model_dump(mode='json')
        if body.health_context and (body.health_context.day!=body.day or body.health_context.purpose!=('weekly_review' if review else 'chat')): raise APIError('health_consent_scope_mismatch',422)
        if body.health_review_context and (not review or body.health_review_context.end_day!=body.day): raise APIError('health_consent_scope_mismatch',422)
        started=time.monotonic(); usageid=str(uuid.uuid4())
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=replay(db,owner,rid,route,wire)
            if old is not None: return old
            context,records=context_for(db,owner,body.day.isoformat())
            context['nutrient_units']=NUTRIENT_UNITS
            image=None
            if body.attachment_id:
                attachment=db.execute('SELECT image FROM attachments WHERE id=? AND user_id=?',(str(body.attachment_id),owner)).fetchone()
                if not attachment: raise APIError('attachment_not_found',404)
                image=attachment['image']
            if body.health_context:
                context['health_context']=body.health_context.model_dump(mode='json')
                if context['intake_selection']=='health':
                    names={'energy':'dietary_kcal','protein':'protein_g','carbohydrates':'carbohydrates_g','fat':'fat_g'}
                    context['totals']={key:body.health_context.metrics.get(names.get(key,'')) for key in NUTRIENTS}
            if review:
                first=(body.day-timedelta(days=13)).isoformat()
                from zoneinfo import ZoneInfo
                zone=ZoneInfo(context['time_zone'])
                def record_day(payload):
                    value=payload.get('recordedAt',payload.get('date',payload.get('day',payload.get('id',''))))
                    try: return datetime.fromisoformat(str(value).replace('Z','+00:00')).astimezone(zone).date().isoformat()
                    except ValueError: return str(value)[:10]
                days=[r['payload'] for r in records if r['kind']=='day' and first<=str(r['payload'].get('date',r['payload'].get('day',r['payload'].get('id',''))))[:10]<=body.day.isoformat()]
                complete_dates={str(p.get('date',p.get('day',p.get('id',''))))[:10] for p in days if (p.get('isComplete',p.get('complete',False)) is True or (p.get('summaries') and p['summaries'][-1].get('intakeSource')=='historical' and p['summaries'][-1].get('completeness')=='complete'))}
                complete_dates.update(str(payload.get('dayID',''))[:10] for payload in (r['payload'] for r in records if r['kind']=='historical')
                    if first<=str(payload.get('dayID',''))[:10]<=body.day.isoformat()
                    and payload.get('isComplete',payload.get('isClosed')) is True
                    and all((payload.get('nutrients') or {}).get(key) is not None for key in ('energy','protein','carbohydrates','fat')))
                weights=[r['payload'] for r in records if r['kind']=='weight' and first<=record_day(r['payload'])<=body.day.isoformat()]
                activities=[r['payload'] for r in records if r['kind']=='activity' and first<=record_day(r['payload'])<=body.day.isoformat()]
                weight_values={record_day(w):w['kilograms'] for w in sorted(weights,key=lambda p:p['recordedAt'])}
                consented=body.health_review_context
                if consented:
                    for w in consented.weights: weight_values[w.day.isoformat()]=w.kilograms
                consent_nutrition={n.day.isoformat():n.model_dump(mode='json',exclude={'day','saturatedFat'}) for n in consented.daily_nutrition} if consented else {}
                daily=[]
                for offset in range(14):
                    date=(body.day-timedelta(days=13-offset)).isoformat()
                    day_context,_=context_for(db,owner,date)
                    totals=day_context['totals']
                    if day_context['intake_selection']=='health':
                        totals={k:consent_nutrition.get(date,{}).get(k) for k in NUTRIENTS}
                    daily.append({'day':date,'totals':totals,'entry_count':len(day_context['entries']),'intake_selection':day_context['intake_selection']})
                complete_dates.intersection_update(row['day'] for row in daily if all(row['totals'].get(k) is not None for k in ('energy','protein','carbohydrates','fat')))
                midpoint=(body.day-timedelta(days=6)).isoformat()
                complete_by_week=[sum(d<midpoint for d in complete_dates),sum(d>=midpoint for d in complete_dates)]
                weights_by_week=[sum(d<midpoint for d in weight_values),sum(d>=midpoint for d in weight_values)]
                complete=len(complete_dates); observed_days=len(weight_values)
                allowed=complete>=10 and observed_days>=6 and all(n>=3 for n in weights_by_week)
                limitations=[]
                if complete<10: limitations.append('Fewer than ten explicitly complete nutrition days in this fourteen-day window.')
                if any(n<3 for n in weights_by_week): limitations.append('At least three observed weight days are required in each seven-day week.')
                if any(any(v is None for k,v in row['totals'].items() if k not in ('saturatedFat','fiber')) for row in daily): limitations.append('Some daily nutrition values are unknown or require source reconciliation.')
                coverage={'window_days':14,'complete_days':complete,'weight_observed_days':observed_days,'complete_days_by_week':complete_by_week,'weight_days_by_week':weights_by_week,'goal_adjustment_allowed':allowed,'limitations':limitations}
                context['review']={**coverage,'daily_totals':daily,'weights':[{'day':d,'kilograms':v} for d,v in sorted(weight_values.items())],'activities':[{'day':record_day(a),'kind':a['kind'],'duration_minutes':a.get('durationMinutes'),'active_kcal':a.get('activeEnergy')} for a in activities[-100:]],'health_daily_activity':[a.model_dump(mode='json') for a in consented.daily_activity] if consented else [],'minimum_complete_days':10,'minimum_weight_days':6,'minimum_weight_days_per_week':3}
            if not settings.openai_key and isinstance(provider,ResponsesClient): raise APIError('ai_not_configured',503)
            if settings.input_price<=0 or settings.output_price<=0: raise APIError('ai_prices_not_configured',503)
            # Reserve conservative input bound (one token per UTF-8 byte + 15000 vision tokens) before request.
            reserve=((len(canonical(context).encode())+len(body.text.encode())+20000+(15000 if image else 0))*settings.input_price+settings.max_output_tokens*settings.output_price)/1_000_000
            recent=(now()-timedelta(hours=1)).isoformat(); startday=now().date().isoformat()
            count=db.execute('SELECT COUNT(*) FROM ai_usage WHERE user_id=? AND created_at>?',(owner,recent)).fetchone()[0]
            usercost=db.execute("SELECT COALESCE(SUM(CASE WHEN status='completed' THEN cost ELSE reserved END),0) FROM ai_usage WHERE user_id=? AND created_at>=?",(owner,startday)).fetchone()[0]
            globalrow=db.execute('SELECT amount FROM global_spend WHERE day=?',(startday,)).fetchone()
            globalcost=globalrow['amount'] if globalrow else 0
            if count>=settings.requests_per_hour: raise APIError('ai_rate_limit',429)
            if usercost+reserve>settings.daily_budget or globalcost+reserve>settings.global_budget: raise APIError('ai_budget_limit',429)
            db.execute('INSERT INTO ai_usage(id,user_id,created_at,reserved) VALUES(?,?,?,?)',(usageid,owner,stamp(),reserve))
            db.execute('INSERT INTO global_spend(day,amount) VALUES(?,?) ON CONFLICT(day) DO UPDATE SET amount=global_spend.amount+excluded.amount',(startday,reserve))
            # Hash health context for replay but never store actual values.
            db.execute('INSERT INTO requests VALUES(?,?,?,?,?)',(owner,rid,route,digest(wire),canonical({'_pending':True})))
            db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)',(str(uuid.uuid4()),owner,rid,'user',body.text,body.day.isoformat(),stamp(),'[]'))
        try:
            output,input_tokens,output_tokens=provider.analyze(context,body.text,image)
            output=guard_output(output,body.text,context,bool(image),review)
            # Stable proposal IDs across retry and don't trust provider-generated idempotency IDs.
            for index,p in enumerate(output.proposals): p.operation_id=uuid.uuid5(uuid.UUID(rid),str(index))
            latency=int((time.monotonic()-started)*1000)
            cost=(input_tokens*settings.input_price+output_tokens*settings.output_price)/1_000_000
            totals=context['totals']
            formatted_values=[]
            for key in NUTRIENTS:
                value=totals.get(key)
                nutrient_coverage=context.get('nutrient_coverage',{}).get(key,{})
                if value is not None:
                    formatted_values.append(f'{key}: {round(value,1)} {NUTRIENT_UNITS[key]}')
                else:
                    known=context.get('known_totals',{}).get(key)
                    missing_count=nutrient_coverage.get('missingCount',0)
                    if known is not None and missing_count:
                        formatted_values.append(f'{key} known (partial; missing in {missing_count} entr{"y" if missing_count==1 else "ies"}): {round(known,1)} {NUTRIENT_UNITS[key]}')
            formatted=' · '.join(formatted_values) or 'no nutrient totals available'
            message=output.message+'\n\nAcumulado real / Actual consumed: '+formatted
            result={'request_id':rid,'message':message,'intent':output.intent,'proposals':[p.model_dump(mode='json',exclude={'product_id','product_version','recipe_id','recipe_version'}) for p in output.proposals],'totals':totals,'known_totals':context.get('known_totals',{}),'nutrient_coverage':context.get('nutrient_coverage',{}),'usage':dict(input_tokens=input_tokens,output_tokens=output_tokens,estimated_cost_usd=cost,latency_ms=latency)}
            result['goal_proposal']=output.goal_proposal.model_dump(mode='json') if output.goal_proposal else None
            result['review_coverage']=coverage if review else None
            with store.connect() as db:
                # Account deletion during provider call must not resurrect data.
                if not db.execute('SELECT 1 FROM users WHERE id=?',(owner,)).fetchone(): raise APIError('account_deleted',401)
                db.execute('UPDATE global_spend SET amount=MAX(0,amount-?+?) WHERE day=?',(reserve,cost,startday))
                db.execute("UPDATE ai_usage SET input_tokens=?,output_tokens=?,cost=?,latency_ms=?,status='completed' WHERE id=?",(input_tokens,output_tokens,cost,latency,usageid))
                db.execute('UPDATE requests SET result=? WHERE user_id=? AND id=? AND route=?',(canonical(result),owner,rid,route))
                db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)',(str(uuid.uuid4()),owner,rid,'assistant',message,body.day.isoformat(),stamp(),canonical(result['proposals'])))
            logger.info('ai_request status=completed latency_ms=%d input_tokens=%d output_tokens=%d estimated_cost_usd=%.6f',latency,input_tokens,output_tokens,cost)
            return result
        except AIError as e:
            code,status=e.code,e.status
        except APIError: raise
        except Exception:
            code,status='ai_invalid_response',503
        latency=int((time.monotonic()-started)*1000)
        with store.connect() as db:
            db.execute("UPDATE ai_usage SET status='failed',latency_ms=? WHERE id=?",(latency,usageid))
            db.execute('UPDATE requests SET result=? WHERE user_id=? AND id=? AND route=?',(canonical({'_error':code,'_status':status}),owner,rid,route))
        logger.info('ai_request status=%s latency_ms=%d',code,latency)
        raise APIError(code,status)

    @app.get('/v1/chat/{request_id}')
    def cached_chat(request_id:uuid.UUID,owner=Depends(identity)):
        with store.connect() as db:
            rows=db.execute("SELECT result FROM requests WHERE user_id=? AND id=? AND route IN ('chat','review') ORDER BY route DESC",(owner,str(request_id))).fetchall()
            for row in rows:
                result=json.loads(row['result'])
                if not result.get('_pending') and not result.get('_error'): return result
        raise APIError('response_not_available',404)

    @app.post('/v1/chat')
    def chat(body:ChatInput,owner=Depends(identity)): return perform_chat(body,owner)
    @app.post('/v1/review')
    def review(body:ChatInput,owner=Depends(identity)): return perform_chat(body,owner,review=True)
    @app.get('/v1/usage')
    def usage(owner=Depends(identity)):
        with store.connect() as db:
            r=db.execute('SELECT COUNT(*) requests,COALESCE(SUM(input_tokens),0) input_tokens,COALESCE(SUM(output_tokens),0) output_tokens,COALESCE(SUM(cost),0) estimated_cost_usd FROM ai_usage WHERE user_id=?',(owner,)).fetchone()
        return dict(r)
    from .apple_auth import AppleIdentity
    apple = AppleIdentity(store, settings)
    app.state.apple_identity = apple
    apple.routes(app, make_session, identity, auth_limit)
    from .health_weights import install_weight_routes
    install_weight_routes(app,store,identity,APIError)
    from .plugin_mcp import install_plugin
    install_plugin(app, store, settings, sync, password_hash, auth_limit)
    return app

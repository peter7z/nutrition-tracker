import io
import os
import psycopg
import json
import uuid
from dataclasses import replace
from fastapi.testclient import TestClient
from PIL import Image
import pytest
from app.main import create_app
from app.config import Settings
from app.models import AssistantOutput
from app.assistant import AIError, structured_schema

def uid(): return str(uuid.uuid4())

def draft(amount=150,**fields):
    return dict(name='Banana',mealName='Lunch',consumedAt='2026-10-08T12:00:00-03:00',amount=amount,unit='gram',preparation='raw',nutrition=dict(energy=89,protein=1.1,carbohydrates=22.8,fat=0.3,saturatedFat=None),basis='per100Grams',source='manual',notes='',**fields)

def operation(kind='entry',payload=None,id=None,version=0,action='upsert',operation_id=None):
    return dict(operation_id=operation_id or uid(),action=action,kind=kind,id=id or uid(),expected_version=version,payload=payload if payload is not None else {'draft':draft()})

class FakeAI:
    def __init__(self): self.calls=[]; self.output=None; self.fail=None
    def analyze(self,context,text,image=None):
        self.calls.append((context,text,image))
        if self.fail: raise self.fail
        out=self.output or dict(message='Revisá esta propuesta.',intent='consumed',proposals=[dict(operation_id=uid(),action='add',entry_id=None,expected_version=None,name='Banana',quantity=150,unit='gram',state='raw',day='2026-10-08',nutrients=dict(energy=133.5,protein=1.65,carbohydrates=34.2,fat=0.45,saturatedFat=None),assumptions=['Estimated generic banana.'],requires_clarification=False)])
        return AssistantOutput.model_validate(out),100,200

@pytest.fixture(params=['sqlite'] + (['postgres'] if os.getenv('TEST_POSTGRES_URL') else []))
def setup(tmp_path, request):
    database = str(tmp_path/'db.sqlite')
    if request.param == 'postgres':
        database = os.environ['TEST_POSTGRES_URL']
        with psycopg.connect(database, autocommit=True) as db:
            db.execute('DROP SCHEMA public CASCADE')
            db.execute('CREATE SCHEMA public')
    ai=FakeAI(); settings=Settings(database=database,input_price=1,output_price=2,auth_per_minute=100)
    app=create_app(settings,ai); client=TestClient(app)
    a=client.post('/v1/auth/signup',json={'email':'a@example.com','password':'a very long password'}).json()
    b=client.post('/v1/auth/signup',json={'email':'b@example.com','password':'another long password'}).json()
    return client,ai,app,{'Authorization':'Bearer '+a['token']},{'Authorization':'Bearer '+b['token']}

def sync(client,headers,ops,revision=0,request_id=None):
    return client.post('/v1/sync',headers=headers,json=dict(request_id=request_id or uid(),base_revision=revision,operations=ops))

def chat(client,headers,text='Anotá 150 g de banana',**kwargs):
    return client.post('/v1/chat',headers=headers,json=dict(request_id=uid(),day='2026-10-08',text=text,**kwargs))

def test_auth_owner_isolation_revocation_and_password_storage(setup):
    c,ai,app,a,b=setup
    assert c.get('/v1/state').status_code==401
    entry=operation()
    assert sync(c,a,[entry]).status_code==200
    assert c.get('/v1/state',headers=b).json()['records']==[]
    stolen=operation(id=entry['id'],version=1,action='delete')
    assert sync(c,b,[stolen]).status_code==409
    assert len(c.get('/v1/state',headers=a).json()['records'])==1
    with app.state.store.connect() as db:
        password=db.execute('SELECT password FROM users').fetchone()[0]
        assert 'long password' not in password
        assert ':' in password
    assert c.post('/v1/auth/logout',headers=a).status_code==200
    assert c.get('/v1/state',headers=a).status_code==401
    login=c.post('/v1/auth/login',json={'email':'a@example.com','password':'a very long password'})
    assert login.status_code==200
    assert c.post('/v1/auth/login',json={'email':'a@example.com','password':'wrong long password'}).status_code==401

def test_idempotency_and_atomic_version_conflict(setup):
    c,ai,app,a,b=setup
    op=operation(); rid=uid()
    first=sync(c,a,[op],request_id=rid)
    assert first.status_code==200
    assert sync(c,a,[op],request_id=rid).json()==first.json()
    assert sync(c,a,[operation()],request_id=rid).status_code==409
    assert sync(c,a,[operation()],revision=0).status_code==409
    good=operation(id=op['id'],version=1,payload={'draft':draft(100)})
    bad=operation(id=uid(),version=8)
    assert sync(c,a,[good,bad],revision=1).status_code==409
    state=c.get('/v1/state',headers=a).json()
    assert state['revision']==1
    assert state['records'][0]['payload']['draft']['amount']==150
    assert sync(c,a,[good],revision=1).status_code==200
    assert sync(c,a,[good],revision=2).json()['revision']==2

def test_density_unknown_nutrients_and_label_energy_not_449(setup):
    c,ai,app,a,b=setup
    d=draft(100); d['nutrition']['energy']=400; d['nutrition']['fat']=10
    assert sync(c,a,[operation(payload={'draft':d})]).status_code==200
    response=chat(c,a).json()
    assert response['totals']['energy']==400
    assert response['totals']['saturatedFat'] is None
    d['unit']='milliliter'
    assert sync(c,a,[operation(payload={'draft':d})],1).status_code==422
    d['conversion']={'gramsPerMilliliter':1.2}
    assert sync(c,a,[operation(payload={'draft':d})],1).status_code==200
    assert chat(c,a).json()['totals']['energy']==880

@pytest.mark.parametrize('bad',[True,-1,'150',float('inf')])
def test_invalid_numbers_fail_closed(setup,bad):
    c,ai,app,a,b=setup; d=draft(); d['amount']=bad
    if isinstance(bad,float):
        # Pydantic directly protects IEEE edge cases unsupported by strict HTTP JSON clients.
        from app.models import EntryDraft
        with pytest.raises(Exception): EntryDraft.model_validate(d)
    else: assert sync(c,a,[operation(payload={'draft':d})]).status_code==422
    assert c.get('/v1/state',headers=a).json()['revision']==0

def test_closed_day_requires_explicit_reopen(setup):
    c,ai,app,a,b=setup; entry=operation(); day=operation(kind='day',payload={'id':'2026-10-08','isClosed':True,'version':1,'summaries':[]})
    assert sync(c,a,[entry,day]).status_code==200
    assert sync(c,a,[operation(id=entry['id'],version=1)],1).status_code==409
    reopened=operation(kind='day',id=day['id'],version=1,payload={'id':'2026-10-08','isClosed':False,'version':2,'summaries':[]})
    assert sync(c,a,[reopened],1).status_code==200
    assert sync(c,a,[operation(id=entry['id'],version=1,payload={'draft':draft(100)})],2).status_code==200

def test_chat_proposals_no_write_idempotent_and_owned_context(setup):
    c,ai,app,a,b=setup
    assert sync(c,a,[operation()]).status_code==200
    rid=uid(); body=dict(request_id=rid,day='2026-10-08',text='Anotá 150 g de banana')
    first=c.post('/v1/chat',headers=a,json=body)
    assert first.status_code==200
    assert len(first.json()['proposals'])==1
    assert c.post('/v1/chat',headers=a,json=body).json()==first.json()
    assert len(ai.calls)==1
    assert c.get('/v1/state',headers=a).json()['revision']==1
    assert len(c.get('/v1/state',headers=a).json()['messages'])==2
    assert chat(c,b).json()['totals']['energy'] is None
    assert ai.calls[-1][0]['entries']==[]
    assert c.get('/v1/state',headers=b).json()['records']==[]

@pytest.mark.parametrize('text',['¿Y si como una banana?','what if I eat banana?','Tengo pollo y boniato, ¿qué ceno?','Qué puedo comer hoy?'])
def test_hypothetical_text_cannot_mutate_even_if_provider_misclassifies(setup,text):
    c,ai,app,a,b=setup
    result=chat(c,a,text=text)
    assert result.status_code==200
    assert result.json()['proposals']==[]
    assert c.get('/v1/state',headers=a).json()['records']==[]

def test_ambiguous_correction_invalid_entry_or_version_requires_clarification(setup):
    c,ai,app,a,b=setup
    ai.output=dict(message='Eran 100 g.',intent='correction',proposals=[dict(operation_id=uid(),action='update',entry_id=uid(),expected_version=7,name='Banana',quantity=100,unit='gram',state='raw',day='2026-10-08',nutrients=None,assumptions=[],requires_clarification=False)])
    assert chat(c,a,text='Eran 100 g').json()['proposals'][0]['requires_clarification'] is True

def test_provider_persistence_assertion_is_not_relayed(setup):
    c,ai,app,a,b=setup
    ai.output=dict(message='Guardé la banana.',intent='consumed',proposals=[])
    message=chat(c,a).json()['message']
    assert 'Guardé' not in message
    assert 'No se modificaron' in message

def test_health_consent_scope_whitelist_and_no_generic_sync(setup):
    c,ai,app,a,b=setup
    health=dict(consent=True,purpose='chat',day='2026-10-08',metrics={'weight_kg':72,'steps':4000})
    assert chat(c,a,health_context=health).status_code==200
    assert ai.calls[-1][0]['health_context']['metrics']['weight_kg']==72
    state=c.get('/v1/state',headers=a).json()
    assert 'health_context' not in json.dumps(state)
    assert all(p.get('weight_kg') is None for m in state['messages'] for p in m['proposals'])
    health['consent']=False
    assert chat(c,a,health_context=health).status_code==422
    health['consent']=True; health['metrics']['raw_samples']=[]
    assert chat(c,a,health_context=health).status_code==422
    assert sync(c,a,[operation(kind='weight',payload={'kilograms':72,'source':'healthkit'})]).status_code==422
    assert sync(c,a,[operation(kind='profile',payload={'healthSamples':[]})]).status_code==422

def image_bytes():
    image=Image.new('RGB',(30,20),(0,100,0)); exif=Image.Exif(); exif[270]='location secret'
    buf=io.BytesIO(); image.save(buf,format='JPEG',exif=exif)
    return buf.getvalue()

def test_private_attachments_strip_metadata_delete_and_account_cleanup(setup):
    c,ai,app,a,b=setup
    uploaded=c.post('/v1/attachments',headers=a,files={'file':('photo.jpg',image_bytes(),'image/jpeg')})
    assert uploaded.status_code==201
    aid=uploaded.json()['id']; image=c.get('/v1/attachments/'+aid,headers=a)
    assert image.status_code==200
    assert dict(Image.open(io.BytesIO(image.content)).getexif())=={}
    assert c.get('/v1/attachments/'+aid,headers=b).status_code==404
    assert c.delete('/v1/attachments/'+aid,headers=b).status_code==404
    assert chat(c,b,attachment_id=aid).status_code==404
    assert chat(c,a,text='Analizá la foto',attachment_id=aid).status_code==200
    assert c.delete('/v1/account',headers=a).status_code==200
    with app.state.store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM attachments').fetchone()[0]==0
        assert db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==0
    assert c.get('/v1/state',headers=a).status_code==401
    assert c.get('/v1/state',headers=b).status_code==200

def test_unsupported_images_and_oversize(setup):
    c,ai,app,a,b=setup
    assert c.post('/v1/attachments',headers=a,files={'file':('p.heic',b'HEIC','image/heic')}).status_code==422
    assert c.post('/v1/attachments',headers=a,files={'file':('p.jpg',b'x'*10_000_001,'image/jpeg')}).status_code==413

def test_timeout_failure_is_idempotent_with_no_write(setup):
    c,ai,app,a,b=setup; ai.fail=AIError('ai_timeout_or_unavailable')
    body=dict(request_id=uid(),day='2026-10-08',text='Anotá banana')
    assert c.post('/v1/chat',headers=a,json=body).status_code==503
    assert c.post('/v1/chat',headers=a,json=body).status_code==503
    assert len(ai.calls)==1
    assert c.get('/v1/state',headers=a).json()['records']==[]

def test_rate_and_budget_limits(tmp_path):
    for changes,code in [({'requests_per_hour':1},'ai_rate_limit'),({'daily_budget':0.0001},'ai_budget_limit')]:
        ai=FakeAI(); s=replace(Settings(database=str(tmp_path/(code+'.sqlite')),input_price=1,output_price=2),**changes)
        c=TestClient(create_app(s,ai)); token=c.post('/v1/auth/signup',json={'email':'a@example.com','password':'long enough password'}).json()['token']; a={'Authorization':'Bearer '+token}
        if code=='ai_rate_limit': assert chat(c,a).status_code==200
        result=chat(c,a); assert result.status_code==429; assert result.json()['error']['code']==code

def test_real_provider_without_key_has_explicit_error(tmp_path):
    c=TestClient(create_app(Settings(database=str(tmp_path/'real.sqlite'),openai_key='')))
    a={'Authorization':'Bearer '+c.post('/v1/auth/signup',json={'email':'a@example.com','password':'long enough password'}).json()['token']}
    assert chat(c,a).json()['error']['code']=='ai_not_configured'

def test_review_never_changes_goals_and_reports_coverage(setup):
    c,ai,app,a,b=setup
    response=c.post('/v1/review',headers=a,json=dict(request_id=uid(),day='2026-10-08',text='Revisá semana'))
    assert response.status_code==200
    assert response.json()['proposals']==[]
    assert ai.calls[-1][0]['review']['goal_adjustment_allowed'] is False
    assert ai.calls[-1][0]['review']['complete_days']==0

def test_output_schema_requires_all_properties_and_no_extra_fields():
    schema=structured_schema()
    assert schema['additionalProperties'] is False
    assert set(schema['required'])==set(schema['properties'])
    assert schema['$defs']['Proposal']['additionalProperties'] is False

def test_uppercase_swift_uuid_and_full_entry_payload(setup):
    c,ai,app,a,b=setup
    identifier=uid()
    payload=dict(id=identifier.upper(),version=1,dayID='2026-10-08',draft=draft(productID=uid(),productVersion=1),deleted=False,createdAt='2026-10-08T12:00:00Z',updatedAt='2026-10-08T12:00:00Z')
    assert sync(c,a,[operation(id=identifier,payload=payload)]).status_code==200
    payload['draft']['amount']=100
    assert sync(c,a,[operation(id=identifier,version=1,payload=payload)],1).status_code==409
    payload['version']=2
    assert sync(c,a,[operation(id=identifier,version=1,payload=payload)],1).status_code==200

def test_bool_versions_are_invalid_input(setup):
    c,ai,app,a,b=setup
    op=operation();op['expected_version']=False
    assert sync(c,a,[op]).status_code==422

def test_migration_restart_and_database_backup_restore_preserve_owned_records(setup,tmp_path):
    import sqlite3
    from app.store import Store,state
    c,ai,app,a,b=setup
    assert sync(c,a,[operation()]).status_code==200
    path=app.state.store.path
    restarted=Store(path)
    with restarted.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM migrations').fetchone()[0]==2
        owner=db.execute("SELECT id FROM users WHERE email='a@example.com'").fetchone()[0]
        before=state(db,owner)
    if restarted.postgres:
        with restarted.connect() as db: assert state(db,owner)==before
        assert len(before['records'])==1
        return
    backup=tmp_path/'restored.sqlite'
    source=sqlite3.connect(path);destination=sqlite3.connect(backup)
    source.backup(destination);destination.close();source.close()
    restored=Store(str(backup))
    with restored.connect() as db: assert state(db,owner)==before
    assert len(before['records'])==1

def test_two_identity_chat_messages_usage_and_deletion_are_isolated(setup):
    c,ai,app,a,b=setup
    assert chat(c,a).status_code==200
    assert len(c.get('/v1/state',headers=a).json()['messages'])==2
    assert c.get('/v1/state',headers=b).json()['messages']==[]
    assert c.get('/v1/usage',headers=a).json()['requests']==1
    assert c.get('/v1/usage',headers=b).json()['requests']==0
    assert c.delete('/v1/account',headers=b).status_code==200
    assert len(c.get('/v1/state',headers=a).json()['messages'])==2

def test_closed_to_open_and_entry_update_same_atomic_batch(setup):
    c,ai,app,a,b=setup
    e=operation();d=operation(kind='day',payload={'id':'2026-10-08','version':1,'isClosed':True,'summaries':[]})
    assert sync(c,a,[e,d]).status_code==200
    reopen=operation(kind='day',id=d['id'],version=1,payload={'id':'2026-10-08','version':2,'isClosed':False,'summaries':[]})
    correction=operation(id=e['id'],version=1,payload={'draft':draft(100)})
    reclose=operation(kind='day',id=d['id'],version=2,payload={'id':'2026-10-08','version':3,'isClosed':True,'summaries':[]})
    response=sync(c,a,[reopen,correction,reclose],1)
    assert response.status_code==200
    assert response.json()['revision']==2
    assert chat(c,a).json()['totals']['energy']==89

def test_historical_totals_are_not_added_to_meals_and_resolution_is_explicit(setup):
    c,ai,app,a,b=setup
    historical=dict(id=uid(),dayID='2026-10-08',nutrients=dict(energy=1500,protein=100,carbohydrates=None,fat=None,saturatedFat=None),isClosed=True,notes='Original spreadsheet summary',importBatchID=uid(),sourceRow='Registro diario 4')
    assert sync(c,a,[operation(),operation(kind='historical',id=historical['id'],payload=historical)]).status_code==200
    result=chat(c,a)
    assert result.json()['totals']['energy'] is None
    assert ai.calls[-1][0]['needs_reconciliation'] is True
    resolution=operation(kind='resolution',payload=dict(dayID='2026-10-08',selection='historical'))
    assert sync(c,a,[resolution],1).status_code==200
    assert chat(c,a).json()['totals']['energy']==1500
    resolution=operation(kind='resolution',id=resolution['id'],version=1,payload=dict(dayID='2026-10-08',selection='manual'))
    assert sync(c,a,[resolution],2).status_code==200
    assert chat(c,a).json()['totals']['energy']==133.5

def test_health_intake_requires_specific_nutrition_context(setup):
    c,ai,app,a,b=setup
    resolution=operation(kind='resolution',payload=dict(dayID='2026-10-08',selection='health'))
    assert sync(c,a,[operation(),resolution]).status_code==200
    assert chat(c,a).json()['totals']['energy'] is None
    health=dict(consent=True,purpose='chat',day='2026-10-08',metrics={'dietary_kcal':1500,'protein_g':100})
    result=chat(c,a,health_context=health)
    assert result.json()['totals']['energy']==1500
    assert result.json()['totals']['fat'] is None
    assert 'dietary_kcal' not in json.dumps(c.get('/v1/state',headers=a).json())

def test_close_summary_is_recomputed_in_code_not_trusted_from_client(setup):
    c,ai,app,a,b=setup
    summary=dict(id=uid(),version=1,closedAt='2026-10-08T18:00:00Z',completeness='complete',totals={'energy':99999},entryVersions={})
    closed=operation(kind='day',payload=dict(id='2026-10-08',version=2,isClosed=True,summaries=[summary]))
    result=sync(c,a,[operation(),closed])
    assert result.status_code==200
    day=next(r for r in result.json()['records'] if r['kind']=='day')
    totals=day['payload']['summaries'][0]['totals']
    assert totals['energy']['known']==133.5
    assert totals['saturatedFat']['missingCount']==1
    assert totals['entryCount']==1

@pytest.mark.parametrize('text',['¿Qué tiene una banana?','Si me como una banana, ¿cuánto sumo?','How much protein is in a banana?'])
def test_general_queries_with_misclassified_provider_never_propose_consumption(setup,text):
    c,ai,app,a,b=setup
    assert chat(c,a,text=text).json()['proposals']==[]

def test_image_analysis_cannot_update_prior_consumed_entry_even_bad_provider_output(setup):
    c,ai,app,a,b=setup
    uploaded=c.post('/v1/attachments',headers=a,files={'file':('photo.jpg',image_bytes(),'image/jpeg')}).json()
    ai.output=dict(message='Read label',intent='query',proposals=[dict(operation_id=uid(),action='update',entry_id=uid(),expected_version=1,name='Previous banana',quantity=100,unit='gram',state='raw',day='2026-10-08',nutrients={'energy':400},assumptions=[],requires_clarification=False)])
    result=chat(c,a,text='Leé esta etiqueta',attachment_id=uploaded['id'])
    assert result.status_code==200
    assert result.json()['proposals']==[]

def test_cached_response_owner_isolation_and_no_replay_charge(setup):
    c,ai,app,a,b=setup
    rid=uid(); body=dict(request_id=rid,day='2026-10-08',text='Anotá 150 g de banana')
    assert c.get('/v1/chat/'+rid,headers=a).status_code==404
    completed=c.post('/v1/chat',headers=a,json=body)
    cached=c.get('/v1/chat/'+rid,headers=a)
    assert cached.status_code==200
    assert cached.json()==completed.json()
    assert len(ai.calls)==1
    assert c.get('/v1/chat/'+rid,headers=b).status_code==404
    assert c.get('/v1/chat/'+rid).status_code==401
    assert c.get('/v1/usage',headers=a).json()['requests']==1

def test_cached_weekly_review_and_failed_response_not_available(setup):
    c,ai,app,a,b=setup
    rid=uid(); body=dict(request_id=rid,day='2026-10-08',text='Revisión semanal')
    completed=c.post('/v1/review',headers=a,json=body)
    assert c.get('/v1/chat/'+rid,headers=a).json()==completed.json()
    ai.fail=AIError('ai_timeout_or_unavailable');failed=uid()
    c.post('/v1/chat',headers=a,json=dict(request_id=failed,day='2026-10-08',text='Anotá banana'))
    assert c.get('/v1/chat/'+failed,headers=a).status_code==404

def test_global_budget_cannot_reset_by_deleting_account(tmp_path):
    ai=FakeAI();s=Settings(database=str(tmp_path/'meter.sqlite'),input_price=.00001,output_price=1,max_output_tokens=512,daily_budget=1,global_budget=.0007,auth_per_minute=100)
    c=TestClient(create_app(s,ai))
    def account(email): return {'Authorization':'Bearer '+c.post('/v1/auth/signup',json={'email':email,'password':'synthetic long password'}).json()['token']}
    a=account('first@example.com'); assert chat(c,a).status_code==200
    assert c.delete('/v1/account',headers=a).status_code==200
    b=account('second@example.com');r=chat(c,b)
    assert r.status_code==429 and r.json()['error']['code']=='ai_budget_limit'
    assert c.get('/v1/usage',headers=b).json()['requests']==0

def test_typed_weight_activity_and_hypothetical_guard(setup):
    c,ai,app,a,b=setup
    proposal=dict(operation_id=uid(),action='add_weight',entry_id=None,expected_version=None,name=None,quantity=None,unit=None,state=None,day='2026-10-08',nutrients=None,weight_kg=72.5,recorded_at='2026-10-08T08:00:00-03:00',assumptions=[],requires_clarification=False)
    ai.output=dict(message='Revisá el peso.',intent='weight',proposals=[proposal])
    reply=chat(c,a,text='Me pesé 72.5 kg a las 8').json()
    assert reply['proposals'][0]['weight_kg']==72.5
    assert c.get('/v1/state',headers=a).json()['records']==[]
    assert chat(c,a,text='Y si peso 72.5 kg mañana?').json()['proposals']==[]
    proposal.update(action='add_activity',weight_kg=None,activity_kind='running',duration_minutes=30,active_kcal=None)
    ai.output=dict(message='Revisá actividad.',intent='activity',proposals=[proposal])
    assert chat(c,a,text='Corrí 30 minutos a las 8').json()['proposals'][0]['requires_clarification'] is False
    proposal['duration_minutes']=None
    assert chat(c,a,text='Corrí hoy').json()['proposals'][0]['requires_clarification'] is True
    proposal['active_kcal']=True
    assert chat(c,a,text='Corrí hoy').status_code==503


def test_review_health_aggregate_scope_and_goal_gate(setup):
    c,ai,app,a,b=setup
    health=dict(consent=True,purpose='weekly_review',start_day='2026-09-25',end_day='2026-10-08',weights=[dict(day=d,kilograms=72) for d in ['2026-09-25','2026-09-27','2026-09-29','2026-10-02','2026-10-04','2026-10-06']],daily_nutrition=[],daily_activity=[dict(day='2026-10-08',exercise_minutes=30)])
    goal=dict(energy=2000,protein=130,carbohydrates=None,fat=None,effective_day='2026-10-09',rationale='Review trend',assumptions=['Estimate'],requires_confirmation=True)
    ai.output=dict(message='Revisión.',intent='weekly_review',proposals=[],goal_proposal=goal)
    body=dict(request_id=uid(),day='2026-10-08',text='Revisá semana',health_review_context=health)
    reply=c.post('/v1/review',headers=a,json=body)
    assert reply.status_code==200
    assert reply.json()['goal_proposal'] is None
    assert reply.json()['review_coverage']['weight_days_by_week']==[3,3]
    assert ai.calls[-1][0]['review']['health_daily_activity'][0]['exercise_minutes']==30
    assert 'health_review_context' not in json.dumps(c.get('/v1/state',headers=a).json())
    assert chat(c,a,health_review_context=health).status_code==422
    health['consent']=1
    assert c.post('/v1/review',headers=a,json={**body,'request_id':uid()}).status_code==422
    health['consent']=True;health['weights'].append(health['weights'][0])
    assert c.post('/v1/review',headers=a,json={**body,'request_id':uid()}).status_code==422
    health['weights'].pop()
    # Seed valid owner-scoped closed days directly to isolate review eligibility policy.
    with app.state.store.connect() as db:
        owner=db.execute('SELECT id FROM users WHERE email=?',('a@example.com',)).fetchone()[0]
        for day in ['2026-09-25','2026-09-26','2026-09-27','2026-09-28','2026-09-29','2026-10-02','2026-10-03','2026-10-04','2026-10-05','2026-10-06']:
            db.execute('INSERT INTO records VALUES(?,?,?,?,?,?)',(owner,uid(),'day',1,json.dumps({'date':day,'isClosed':True,'isComplete':True,'summaries':[{'totals':{k:{'known':v,'knownCount':1,'missingCount':0} for k,v in dict(energy=2000,protein=130,carbohydrates=240,fat=60).items()}}]}),0))
    reply=c.post('/v1/review',headers=a,json={**body,'request_id':uid()}).json()
    assert reply['review_coverage']['goal_adjustment_allowed'] is True
    assert reply['review_coverage']['complete_days_by_week']==[5,5]
    assert reply['goal_proposal']['requires_confirmation'] is True
    other=c.post('/v1/review',headers=b,json={**body,'request_id':uid()}).json()
    assert other['review_coverage']['complete_days']==0 and other['goal_proposal'] is None

def test_closed_context_freezes_totals_source_and_goal_version(setup):
    from app.nutrition import context_for
    c,ai,app,a,b=setup
    assert sync(c,a,[operation()]).status_code==200
    with app.state.store.connect() as db:
        owner=db.execute('SELECT id FROM users WHERE email=?',('a@example.com',)).fetchone()[0]
        goal_id=uid();old_goal={'id':goal_id,'effectiveDay':'2026-10-01','energy':1900}
        db.execute('INSERT INTO records VALUES(?,?,?,?,?,?)',(owner,goal_id,'goal',1,json.dumps(old_goal),0))
        new_id=uid();db.execute('INSERT INTO records VALUES(?,?,?,?,?,?)',(owner,new_id,'goal',1,json.dumps({'id':new_id,'effectiveDay':'2026-10-02','energy':2500}),0))
        summary=dict(intakeSource='historical',goalVersionID=goal_id,totals={k:dict(known=v,knownCount=1,missingCount=0) for k,v in dict(energy=2100,protein=120,carbohydrates=240,fat=70,saturatedFat=10).items()})
        day_id=uid();db.execute('INSERT INTO records VALUES(?,?,?,?,?,?)',(owner,day_id,'day',1,json.dumps(dict(id='2026-10-08',isClosed=True,summaries=[summary])),0))
        context,_=context_for(db,owner,'2026-10-08')
        assert context['closed'] is True and context['totals']['energy']==2100
        assert context['goals']['energy']==1900 and context['intake_selection']=='historical'
        db.execute("UPDATE records SET deleted=1 WHERE user_id=? AND kind='entry'",(owner,))
        context,_=context_for(db,owner,'2026-10-08');assert context['totals']['energy']==2100
        summary['intakeSource']='health';summary['goalVersionID']=None
        db.execute('UPDATE records SET payload=? WHERE user_id=? AND id=?',(json.dumps(dict(id='2026-10-08',isClosed=True,summaries=[summary])),owner,day_id))
        context,_=context_for(db,owner,'2026-10-08')
        assert all(v is None for v in context['totals'].values()) and context['goals'] is None


def test_legacy_catalog_sync_preserved_but_not_in_active_assistant_context_or_schema(setup):
    c,ai,app,a,b=setup
    product_id=uid();product=dict(id=product_id,version=3,name='Legacy Yogur',brand='A',nutrition=dict(energy=123),basis='per100Grams',source='label',updatedAt='2026-10-08T12:00:00Z')
    recipe_id=uid();recipe=dict(id=recipe_id,version=2,name='Legacy recipe',ingredients=[draft(100)],servings=2,finalWeightGrams=100,updatedAt='2026-10-08T12:00:00Z')
    assert sync(c,a,[operation(kind='product',id=product_id,payload=product),operation(kind='recipe',id=recipe_id,payload=recipe),operation(payload={'draft':draft(productID=product_id,productVersion=3)})]).status_code==200
    proposal=dict(operation_id=uid(),action='add',entry_id=None,expected_version=None,name='Banana',quantity=150,unit='gram',state='raw',day='2026-10-08',nutrients=dict(energy=133.5,protein=1.65,carbohydrates=34.2,fat=.45),product_id=product_id,product_version=3,recipe_id=recipe_id,recipe_version=2,assumptions=['Estimated from described food'],requires_clarification=False)
    ai.output=dict(message='Estimación para revisar.',intent='consumed',proposals=[proposal])
    result=chat(c,a,text='Comí 150g de banana').json()
    assert result['proposals'][0]['nutrients']['energy']==133.5
    assert not any(k in result['proposals'][0] for k in ('product_id','product_version','recipe_id','recipe_version'))
    context=ai.calls[-1][0]
    assert 'products' not in context and 'recipes' not in context
    assert 'productID' not in context['entries'][0]['draft']
    schema=structured_schema()['$defs']['Proposal']['properties']
    assert not any(k in schema for k in ('product_id','product_version','recipe_id','recipe_version'))
    records=c.get('/v1/state',headers=a).json()['records']
    assert next(r['payload'] for r in records if r['kind']=='product')==product
    assert next(r['payload'] for r in records if r['kind']=='recipe')==recipe
    assert next(r['payload']['draft'] for r in records if r['kind']=='entry')['productID']==product_id


def test_spanish_food_estimate_correction_and_hypothetical_require_no_manual_macros_or_automatic_writes(setup):
    c,ai,app,a,b=setup
    estimated=chat(c,a,text='Comí una banana').json()
    p=estimated['proposals'][0]
    assert p['quantity']==150 and p['nutrients']['energy']==133.5 and p['nutrients']['protein']==1.65
    assert p['requires_clarification'] is False
    assert c.get('/v1/state',headers=a).json()['records']==[]
    entry=operation(payload={'draft':draft(150),'version':1})
    assert sync(c,a,[entry]).status_code==200
    ai.output=dict(message='Actualicé la estimación propuesta para 100g; revisá la cantidad.',intent='correction',proposals=[dict(operation_id=uid(),action='update',entry_id=entry['id'],expected_version=1,name='Banana',quantity=100,unit='gram',state='raw',day='2026-10-08',nutrients=dict(energy=89,protein=1.1,carbohydrates=22.8,fat=.3),assumptions=['Generic banana estimate, recalculated for the corrected amount'],requires_clarification=False)])
    corrected=chat(c,a,text='Eran 100 g de banana').json()['proposals'][0]
    assert corrected['action']=='update' and corrected['expected_version']==1
    assert corrected['quantity']==100 and corrected['nutrients']['energy']==89
    assert corrected['requires_clarification'] is False
    state=c.get('/v1/state',headers=a).json()
    assert state['revision']==1 and state['records'][0]['payload']['draft']['amount']==150
    # Even a provider accidentally returning a correction cannot turn planning into consumption.
    assert chat(c,a,text='¿Y si como 100 g de banana?').json()['proposals']==[]
    assert c.get('/v1/state',headers=a).json()['revision']==1


def test_sync_closed_metadata_preserves_frozen_history_until_explicit_reopen(setup):
    c,ai,app,a,b=setup
    entry=operation();day_id=uid()
    summary=dict(id=uid(),version=1,closedAt='2026-10-08T15:00:00Z',completeness='complete',intakeSource='manual',goalVersionID=None,totals={},entryVersions={})
    day=dict(id='2026-10-08',version=1,isClosed=True,summaries=[summary])
    reply=sync(c,a,[entry,operation(kind='day',id=day_id,payload=day)])
    assert reply.status_code==200
    frozen=next(r['payload'] for r in reply.json()['records'] if r['kind']=='day')
    original_totals=frozen['summaries'][0]['totals']
    # Source imports/observations do not rewrite an existing close snapshot.
    historic_id=uid(); historic=dict(id=historic_id,dayID='2026-10-08',nutrients=dict(energy=3000),isClosed=True,notes='',importBatchID=uid(),sourceRow='fixture')
    assert sync(c,a,[operation(kind='historical',id=historic_id,payload=historic)],revision=1).status_code==200
    metadata={**frozen,'version':2}
    reply=sync(c,a,[operation(kind='day',id=day_id,version=1,payload=metadata)],revision=2)
    assert reply.status_code==200
    closed=next(r['payload'] for r in reply.json()['records'] if r['kind']=='day')
    assert closed['summaries'][0]['totals']==original_totals
    tampered={**closed,'version':3,'summaries':[{**closed['summaries'][0],'intakeSource':'historical'}]}
    rejected=sync(c,a,[operation(kind='day',id=day_id,version=2,payload=tampered)],revision=3)
    assert rejected.status_code==409 and rejected.json()['error']['code']=='closed_summary_conflict'
    reopened={**closed,'version':3,'isClosed':False}
    next_summary={**summary,'id':uid(),'version':2,'intakeSource':'historical'}
    reclosed={**reopened,'version':4,'isClosed':True,'summaries':closed['summaries']+[next_summary]}
    reply=sync(c,a,[operation(kind='day',id=day_id,version=2,payload=reopened),operation(kind='day',id=day_id,version=3,payload=reclosed)],revision=3)
    assert reply.status_code==200
    result=next(r['payload'] for r in reply.json()['records'] if r['kind']=='day')
    assert result['summaries'][0]['totals']==original_totals
    assert result['summaries'][1]['totals']['energy']['known']==3000
    # Reopen can prepare a later close, but a new close may not rewrite older IDs/totals.
    open_again={**result,'isClosed':False,'version':5}
    wrong={**result,'version':6,'summaries':[{**result['summaries'][0],'goalVersionID':uid()},result['summaries'][1],{**next_summary,'id':uid(),'version':3}]}
    assert sync(c,a,[operation(kind='day',id=day_id,version=4,payload=open_again),operation(kind='day',id=day_id,version=5,payload=wrong)],revision=4).status_code==409
    assert c.get('/v1/state',headers=a).json()['revision']==4


def test_older_health_closure_values_cannot_be_hidden_in_sync_history(setup):
    c,ai,app,a,b=setup
    day={'id':'2026-10-08','version':1,'isClosed':True,'summaries':[{'intakeSource':'health','totals':{'energy':{'known':1500,'knownCount':1,'missingCount':0}}},{'intakeSource':'manual','totals':{}}]}
    assert sync(c,a,[operation(kind='day',payload=day)]).status_code==422
    assert c.get('/v1/state',headers=a).json()['records']==[]

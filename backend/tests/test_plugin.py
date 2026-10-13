import base64
import hashlib
import json
import os
import re
import uuid
from urllib.parse import parse_qs, urlsplit
import psycopg
import pytest
from fastapi.testclient import TestClient
from app.main import create_app
from app.config import Settings
from app.nutrition import NUTRIENTS

BASE='http://localhost:8000'
CALLBACK='https://chatgpt.com/connector_platform_oauth_redirect'
RESOURCE=BASE+'/mcp'

@pytest.fixture(params=['sqlite']+(['postgres'] if os.getenv('TEST_POSTGRES_URL') else []))
def client(tmp_path, request):
    database=str(tmp_path/'plugin.sqlite')
    if request.param=='postgres':
        database=os.environ['TEST_POSTGRES_URL']
        with psycopg.connect(database,autocommit=True) as db:
            db.execute('DROP SCHEMA public CASCADE');db.execute('CREATE SCHEMA public')
    app=create_app(Settings(database=database,environment='test',public_url=BASE,auth_per_minute=100))
    with TestClient(app,base_url=BASE) as client:
        yield client


def connect(client, email='plugin@example.com', scopes='tracking:read tracking:write', signup=True):
    metadata={'client_name':'ChatGPT test','redirect_uris':[CALLBACK],
        'token_endpoint_auth_method':'none','grant_types':['authorization_code','refresh_token'],
        'response_types':['code']}
    registration=client.post('/register',json=metadata)
    assert registration.status_code==201,registration.text
    client_id=registration.json()['client_id']
    verifier='v'*64
    challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    params={'client_id':client_id,'redirect_uri':CALLBACK,'response_type':'code','scope':scopes,
        'resource':RESOURCE,'code_challenge':challenge,'code_challenge_method':'S256','state':'test-state'}
    response=client.get('/authorize',params=params,follow_redirects=False)
    assert response.status_code==302,response.text
    page=client.get(response.headers['location'])
    assert page.status_code==200,page.text
    csrf=re.search(r'name="csrf" value="([^"]+)"',page.text)[1]
    flow=parse_qs(urlsplit(response.headers['location']).query)['flow'][0]
    response=client.post('/oauth/connect',data={'flow':flow,'csrf':csrf,'email':email,
        'password':'synthetic plugin password','action':'signup' if signup else 'login'},follow_redirects=False)
    assert response.status_code==303,response.text
    query=parse_qs(urlsplit(response.headers['location']).query)
    assert query['state']==['test-state'] and query['iss']==[BASE]
    form={'grant_type':'authorization_code','client_id':client_id,'code':query['code'][0],
        'redirect_uri':CALLBACK,'code_verifier':verifier,'resource':RESOURCE}
    token=client.post('/token',data=form)
    assert token.status_code==200,token.text
    return token.json(),client_id,form


def rpc(client,token,method,params=None):
    response=client.post('/mcp',headers={'Authorization':'Bearer '+token,
        'Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-06-18'},
        json={'jsonrpc':'2.0','id':1,'method':method,**({'params':params} if params is not None else {})})
    assert response.status_code==200,response.text
    return response.json()


def tool(client,token,name,args=None):
    return rpc(client,token,'tools/call',{'name':name,'arguments':args or {}})['result']


def food():
    return {'name':'Banana','meal':'Merienda','consumed_at':'2026-10-10T12:00:00-03:00',
        'portion_description':'Una banana, 150 g','source':'estimate','assumptions':'Peso estimado',
        'nutrients':{'energy':133.5,'protein':1.65,'carbohydrates':34.2,'fat':0.45,'saturatedFat':None,'fiber':3.9}}


def test_oauth_discovery_pkce_replay_refresh_and_revocation(client):
    metadata=client.get('/.well-known/oauth-authorization-server').json()
    assert metadata['issuer']==BASE and metadata['token_endpoint_auth_methods_supported']==['none']
    assert metadata['authorization_response_iss_parameter_supported'] is True
    response=client.post('/mcp',json={})
    assert response.status_code==401
    assert 'resource_metadata=' in response.headers['www-authenticate']
    assert client.get('/.well-known/oauth-protected-resource/mcp').json()['resource']==RESOURCE
    tokens,client_id,form=connect(client)
    assert client.post('/token',data=form).status_code==400
    assert client.post('/token',data=form|{'resource':'https://evil.example/mcp'}).json()['error']=='invalid_target'
    initialize=rpc(client,tokens['access_token'],'initialize',{'protocolVersion':'2025-06-18',
        'capabilities':{},'clientInfo':{'name':'test','version':'1'}})
    assert initialize['result']['serverInfo']['name']=='Bocado Log'
    profile=tool(client,tokens['access_token'],'get_profile')['structuredContent']
    assert profile['email']=='plugin@example.com'
    refresh={'grant_type':'refresh_token','client_id':client_id,'refresh_token':tokens['refresh_token'],'resource':RESOURCE}
    rotated=client.post('/token',data=refresh)
    assert rotated.status_code==200
    assert client.post('/token',data=refresh).status_code==400
    assert client.post('/mcp',headers={'Authorization':'Bearer '+tokens['access_token']},json={}).status_code==401
    current=rotated.json()
    assert client.post('/revoke',data={'client_id':client_id,'token':current['refresh_token'],'token_type_hint':'refresh_token'}).status_code==200
    assert client.post('/mcp',headers={'Authorization':'Bearer '+current['access_token']},json={}).status_code==401


def test_read_only_scope_and_owner_isolation(client):
    first,_,_=connect(client)
    read,_,_=connect(client,email='other@example.com',scopes='tracking:read')
    args={'operation_id':str(uuid.uuid4()),'base_revision':0,'consumption_text':'Comí una banana','food':food()}
    result=tool(client,read['access_token'],'record_food',args)
    assert result['isError'] and 'insufficient_scope' in result['content'][0]['text']
    assert 'tracking:write' in result['_meta']['mcp/www_authenticate'][0]
    assert tool(client,first['access_token'],'record_food',args)['structuredContent']['saved'] is True
    assert len(tool(client,read['access_token'],'get_day',{'day':'2026-10-10'})['structuredContent']['entries'])==0
    legacy=client.post('/v1/auth/login',json={'email':'plugin@example.com','password':'synthetic plugin password'}).json()['token']
    assert client.post('/mcp',headers={'Authorization':'Bearer '+legacy},json={}).status_code==401
    assert client.delete('/v1/account',headers={'Authorization':'Bearer '+legacy}).status_code==200
    assert client.post('/mcp',headers={'Authorization':'Bearer '+first['access_token']},json={}).status_code==401


def test_food_receipt_idempotency_correction_delete_and_server_totals(client):
    tokens,_,_=connect(client);token=tokens['access_token']
    tools=rpc(client,token,'tools/list')['result']['tools']
    assert {t['name'] for t in tools}=={'get_profile','get_day','show_day_summary','get_progress','open_tracker','record_food','update_food','delete_food','record_day_totals'}
    day_reader=next(t for t in tools if t['name']=='get_day')
    day_renderer=next(t for t in tools if t['name']=='show_day_summary')
    sidebar=next(t for t in tools if t['name']=='open_tracker')
    assert sidebar['title']=='Bocado Log'
    assert sidebar['_meta']['openai/ui']['entrypoints']==[{'type':'global'}]
    assert 'visibility' not in sidebar['_meta']['ui']
    opened=tool(client,token,'open_tracker')['structuredContent']
    assert opened['day'] and 'totals' in opened
    resource=rpc(client,token,'resources/read',{'uri':'ui://nutrition-tracker/day-summary-v1.html'})['result']
    html=resource['contents'][0]['text']
    assert 'renderBocadoLogSummary' in html and 'Nutrition Tracker' not in html
    assert '--day-text: light-dark(#202124, #f5f5f7)' in html and 'context?.styles?.variables' not in html
    assert 'notifyIntrinsicHeight' in html
    assert html.lstrip().lower().startswith('<!doctype html>')
    resources=rpc(client,token,'resources/list')['result']['resources']
    assert [r['uri'] for r in resources]==['ui://nutrition-tracker/day-summary-v1.html']
    for name in ('show_day_summary', 'record_food', 'update_food'):
        descriptor=next(t for t in tools if t['name']==name)
        assert descriptor['_meta']['ui']['resourceUri']=='ui://nutrition-tracker/day-summary-v1.html'
        assert 'visibility' not in descriptor['_meta']['ui']
    assert 'ui' not in day_reader['_meta']
    assert day_renderer['_meta']['ui']['resourceUri']=='ui://nutrition-tracker/day-summary-v1.html'
    for descriptor in tools:
        assert descriptor['_meta']['securitySchemes'][0]['type']=='oauth2'
        assert 'outputSchema' in descriptor
    args={'operation_id':str(uuid.uuid4()),'base_revision':0,'consumption_text':'Comí una banana','food':food()}
    first=tool(client,token,'record_food',args)['structuredContent']
    replay=tool(client,token,'record_food',args)['structuredContent']
    assert first==replay and first['saved'] is True and first['version']==1
    assert tool(client,token,'record_food',args|{'food':food()|{'name':'Different'}})['isError']
    day=tool(client,token,'get_day',{'day':'2026-10-10'})['structuredContent']
    assert len(day['entries'])==1 and day['totals']['energy']==133.5
    assert day['totals']['saturatedFat'] is None
    assert day['totals']['fiber']==3.9
    summary=tool(client,token,'show_day_summary',{'day':'2026-10-10'})['structuredContent']
    assert summary['day']=='2026-10-10' and summary['totals']['energy']==133.5
    hypothetical=tool(client,token,'record_food',args|{'consumption_text':'¿Y si como una banana?'})
    assert hypothetical['isError']
    for text in ('Voy a comer una banana', '¿Qué tiene una banana?', 'How much protein is in a banana?'):
        assert tool(client,token,'record_food',args|{'consumption_text':text})['isError']
    correction={'operation_id':str(uuid.uuid4()),'base_revision':1,'entry_id':first['entry_id'],
        'expected_version':1,'correction_text':'Eran 100 gramos','food':food()|{'nutrients':{'energy':89}}}
    updated=tool(client,token,'update_food',correction)['structuredContent']
    assert updated['version']==2
    stale=tool(client,token,'update_food',correction|{'operation_id':str(uuid.uuid4())})
    assert stale['isError']
    deletion={'operation_id':str(uuid.uuid4()),'base_revision':2,'entry_id':first['entry_id'],'expected_version':2,'confirmed':False}
    assert tool(client,token,'delete_food',deletion)['isError']
    assert tool(client,token,'delete_food',deletion|{'confirmed':True})['structuredContent']['deleted'] is True
    assert tool(client,token,'get_day',{'day':'2026-10-10'})['structuredContent']['entries']==[]
    assert tool(client,token,'get_progress',{'start_day':'2026-01-01','end_day':'2026-10-10'})['isError']


def test_registration_rejects_untrusted_callbacks_and_consent_csrf(client):
    assert client.post('/register',json={'redirect_uris':['https://evil.example/callback'],
        'token_endpoint_auth_method':'none'}).status_code==400
    tokens,client_id,form=connect(client)
    assert client.post('/oauth/connect',data={'flow':'anything','csrf':'bad','email':'plugin@example.com',
        'password':'synthetic plugin password','action':'login'}).status_code==400
    assert client.post('/token',data=form|{'code_verifier':'wrong'}).status_code==400
    assert client.post('/token',data={'grant_type':'refresh_token','client_id':client_id,
        'refresh_token':tokens['refresh_token'],'scope':'tracking:read tracking:write health:read','resource':RESOURCE}).status_code==400
    with client.app.state.store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM oauth_codes').fetchone()[0]==0
        rows=list(db.execute('SELECT hash FROM oauth_tokens'))
        assert all(tokens['access_token'] not in r['hash'] and len(r['hash'])==64 for r in rows)


def test_token_expiry_restart_and_foreign_entry_cannot_mutate(client):
    from app.store import Store
    from app.plugin_auth import hashed
    first,client_id,_=connect(client)
    other,_,_=connect(client,email='second@example.com')
    args={'operation_id':str(uuid.uuid4()),'base_revision':0,'consumption_text':'Comí una banana','food':food()}
    saved=tool(client,first['access_token'],'record_food',args)['structuredContent']
    correction={'operation_id':str(uuid.uuid4()),'base_revision':0,'entry_id':saved['entry_id'],
        'expected_version':1,'correction_text':'Eran 100 gramos','food':food()}
    assert tool(client,other['access_token'],'update_food',correction)['isError']
    restarted=Store(client.app.state.store.path)
    with restarted.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM oauth_tokens WHERE revoked=0').fetchone()[0]==4
        db.execute('UPDATE oauth_tokens SET expires_at=0 WHERE hash=?',(hashed(first['access_token']),))
    assert client.post('/mcp',headers={'Authorization':'Bearer '+first['access_token']},json={}).status_code==401
    assert client.post('/revoke',data={'client_id':client_id,'token':first['access_token']}).status_code==200
    assert client.post('/token',data={'grant_type':'refresh_token','client_id':client_id,'refresh_token':first['refresh_token'],'resource':RESOURCE}).status_code==400
    assert len(tool(client,other['access_token'],'get_day',{'day':'2026-10-10'})['structuredContent']['entries'])==0


def test_wrong_pkce_and_audience_never_issue_token(client):
    verifier='v'*64
    challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    registered=client.post('/register',json={'redirect_uris':[CALLBACK],
        'token_endpoint_auth_method':'none','grant_types':['authorization_code','refresh_token']}).json()
    params={'client_id':registered['client_id'],'redirect_uri':CALLBACK,'response_type':'code',
        'scope':'tracking:read','resource':RESOURCE,'code_challenge':challenge,'code_challenge_method':'S256'}
    wrong=client.get('/authorize',params=params|{'resource':'https://evil.example/mcp'},follow_redirects=False)
    assert 'error=' in wrong.headers['location'] and parse_qs(urlsplit(wrong.headers['location']).query)['iss']==[BASE]
    response=client.get('/authorize',params=params,follow_redirects=False)
    page=client.get(response.headers['location'])
    csrf=re.search(r'name="csrf" value="([^"]+)"',page.text)[1]
    flow=parse_qs(urlsplit(response.headers['location']).query)['flow'][0]
    result=client.post('/oauth/connect',data={'flow':flow,'csrf':csrf,'email':'pkce@example.com',
        'password':'synthetic plugin password','action':'signup'},follow_redirects=False)
    code=parse_qs(urlsplit(result.headers['location']).query)['code'][0]
    form={'grant_type':'authorization_code','client_id':registered['client_id'],'code':code,
        'redirect_uri':CALLBACK,'resource':RESOURCE,'code_verifier':'w'*64}
    assert client.post('/token',data=form|{'code_verifier':'short'}).json()['error']=='invalid_request'
    assert client.post('/token',data=form).json()['error']=='invalid_grant'
    from app.plugin_auth import hashed
    with client.app.state.store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM oauth_tokens').fetchone()[0]==0
        row=db.execute('SELECT payload FROM oauth_codes WHERE hash=?',(hashed(code),)).fetchone()
        payload=json.loads(row['payload']);payload['expires_at']=0
        db.execute('UPDATE oauth_codes SET payload=? WHERE hash=?',(json.dumps(payload),hashed(code)))
    assert client.post('/token',data=form|{'code_verifier':verifier}).status_code==400


def test_day_totals_atomic_replay_scope_and_correctable(client):
    tokens,_,_=connect(client);token=tokens['access_token']
    read,_,_=connect(client,email='reader@example.com',scopes='tracking:read')
    saved=tool(client,token,'record_food',{'operation_id':str(uuid.uuid4()),'base_revision':0,
        'consumption_text':'Comí una banana','food':food()})['structuredContent']
    nutrients={'energy':2200,'protein':140,'carbohydrates':250,'fat':70,'saturatedFat':15,'fiber':30}
    args={'operation_id':str(uuid.uuid4()),'base_revision':1,'day':'2026-10-10',
        'consumption_text':'Guardar el día completo que consumí','nutrients':nutrients}
    assert tool(client,read['access_token'],'record_day_totals',args)['isError']
    for invalid in (-1,True,'20'):
        assert tool(client,token,'record_day_totals',args|{'nutrients':{'fiber':invalid}})['isError']
    assert tool(client,token,'record_day_totals',args|{'base_revision':5})['isError']
    assert tool(client,token,'record_day_totals',args|{'consumption_text':'Si como eso mañana'})['isError']
    first=tool(client,token,'record_day_totals',args)['structuredContent']
    assert first['saved'] and first['revision']==2 and 'closed' not in first
    assert tool(client,token,'record_day_totals',args)['structuredContent']==first
    day=tool(client,token,'get_day',{'day':'2026-10-10'})['structuredContent']
    expected_totals={key:nutrients.get(key) for key in NUTRIENTS}
    assert 'closed' not in day and day['totals']==expected_totals and len(day['entries'])==1
    assert not day['needs_reconciliation']
    assert tool(client,token,'get_progress',{'start_day':'2026-10-10','end_day':'2026-10-10'})['structuredContent']['days'][0]['totals']==expected_totals
    assert tool(client,token,'record_day_totals',args|{'operation_id':str(uuid.uuid4()),'base_revision':2})['isError']
    correction=tool(client,token,'update_food',{'operation_id':str(uuid.uuid4()),'base_revision':2,
        'entry_id':saved['entry_id'],'expected_version':1,'correction_text':'Eran dos bananas','food':food()})
    assert correction['structuredContent']['saved']
    other=tool(client,read['access_token'],'get_day',{'day':'2026-10-10'})['structuredContent']
    assert 'closed' not in other and other['totals']['energy'] is None
    unknown=args|{'operation_id':str(uuid.uuid4()),'base_revision':3,'day':'2026-10-09','nutrients':{'energy':1800}}
    assert tool(client,token,'record_day_totals',unknown)['structuredContent']['saved']
    assert tool(client,token,'get_day',{'day':'2026-10-09'})['structuredContent']['totals']['fiber'] is None


def test_companion_state_reads_mcp_food_and_daily_snapshots_for_same_account(client):
    tokens,_,_=connect(client)
    token=tokens['access_token']
    session=client.post('/v1/auth/login',json={'email':'plugin@example.com','password':'synthetic plugin password'}).json()
    headers={'Authorization':'Bearer '+session['token']}
    assert client.get('/v1/state').status_code==401
    saved=tool(client,token,'record_food',{'operation_id':str(uuid.uuid4()),'base_revision':0,
        'consumption_text':'Comí una banana','food':food()})['structuredContent']
    state=client.get('/v1/state',headers=headers).json()
    assert state['revision']==1 and {record['kind'] for record in state['records']}=={'entry','day'}
    entry=next(record for record in state['records'] if record['kind']=='entry')
    assert entry['id']==saved['entry_id'] and entry['version']==1
    assert entry['payload']['draft']['nutrition']['fiber']==3.9
    assert entry['payload']['draft']['consumedAt'].endswith('-03:00')
    totals=tool(client,token,'record_day_totals',{'operation_id':str(uuid.uuid4()),'base_revision':1,
        'day':'2026-10-10','consumption_text':'Guardar el total consumido del día','nutrients':{'energy':2200,'fiber':30}})
    assert totals['structuredContent']['saved']
    state=client.get('/v1/state',headers=headers).json()
    assert state['revision']==2 and {r['kind'] for r in state['records']}=={'entry','historical','resolution','day'}
    day=next(r['payload'] for r in state['records'] if r['kind']=='day')
    assert 'isClosed' not in day and day['id']=='2026-10-10'
    assert day['summaries'][-1]['closedAt']
    other=client.post('/v1/auth/signup',json={'email':'companion-other@example.com','password':'synthetic plugin password'}).json()
    assert client.get('/v1/state',headers={'Authorization':'Bearer '+other['token']}).json()['records']==[]


def test_mcp_reads_only_connected_accounts_uploaded_health_weight(client):
    first,_,_=connect(client)
    other,_,_=connect(client,email='weight-other@example.com')
    session=client.post('/v1/auth/login',json={'email':'plugin@example.com','password':'synthetic plugin password'}).json()
    headers={'Authorization':'Bearer '+session['token']}
    version=client.post('/v1/health/weight/consent',headers=headers,json={'enabled':True}).json()['version']
    response=client.post('/v1/health/weight/sync',headers=headers,json={'request_id':str(uuid.uuid4()),
        'consent_version':version,'samples':[{'sample_id':str(uuid.uuid4()),'recorded_at':'2026-10-12T08:00:00-03:00','kilograms':80.5}], 'deleted_ids':[]})
    assert response.status_code==200
    day=tool(client,first['access_token'],'get_day',{'day':'2026-10-12'})['structuredContent']
    assert len(day['weights'])==1 and day['weights'][0]['kilograms']==80.5
    assert day['weights'][0]['source']=='appleHealth'
    assert day['health_sync_available'] and day['health_sync_metrics']==['weight']
    assert tool(client,other['access_token'],'get_day',{'day':'2026-10-12'})['structuredContent']['weights']==[]
    progress=tool(client,first['access_token'],'get_progress',{'start_day':'2026-10-12','end_day':'2026-10-12'})['structuredContent']
    assert progress['days'][0]['weights']==day['weights']

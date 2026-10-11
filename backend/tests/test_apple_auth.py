import os
import time
from types import SimpleNamespace
import jwt
import psycopg
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from app.main import create_app
from app.config import Settings
from tests.test_plugin import connect, rpc

@pytest.fixture(params=['sqlite']+(['postgres'] if os.getenv('TEST_POSTGRES_URL') else []))
def setup(tmp_path, request):
    database=str(tmp_path/'apple.sqlite')
    if request.param=='postgres':
        database=os.environ['TEST_POSTGRES_URL']
        with psycopg.connect(database,autocommit=True) as db:
            db.execute('DROP SCHEMA public CASCADE'); db.execute('CREATE SCHEMA public')
    app=create_app(Settings(database=database,environment='test',auth_per_minute=100))
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    app.state.apple_identity.keys=SimpleNamespace(get_signing_key_from_jwt=lambda token:SimpleNamespace(key=key.public_key()))
    with TestClient(app,base_url='http://localhost:8000') as client: yield client, app, key

def token(key,challenge_nonce,**changes):
    claims={'iss':'https://appleid.apple.com','aud':'com.peter7z.NutritionTracker','sub':'apple-subject',
        'iat':int(time.time()),'exp':int(time.time())+300,'nonce':challenge_nonce,
        'email':'apple@example.com','email_verified':'true'}|changes
    return jwt.encode(claims,key,algorithm='RS256',headers={'kid':'test'})

def login(client,key,**changes):
    challenge=client.post('/v1/auth/apple/challenge').json()
    body={'challenge_id':challenge['challenge_id'],'identity_token':token(key,challenge['nonce'],**changes)}
    return client.post('/v1/auth/apple',json=body),body

def test_verified_email_automatically_links_existing_account_and_plugin(setup):
    client,app,key=setup
    plugin,_,_=connect(client,email='apple@example.com')
    profile=rpc(client,plugin['access_token'],'tools/call',{'name':'get_profile','arguments':{}})['result']['structuredContent']
    response,body=login(client,key,email='APPLE@EXAMPLE.COM')
    assert response.status_code==200
    assert response.json()['user_id']==profile['user_id']
    with app.state.store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM users').fetchone()[0]==1
    auth={'Authorization':'Bearer '+response.json()['token']}
    assert client.get('/v1/auth/me',headers=auth).json()['email']=='apple@example.com'
    assert client.get('/v1/state',headers=auth).status_code==200
    assert client.post('/v1/auth/apple',json=body).status_code==401
    assert client.post('/v1/auth/logout',headers=auth).status_code==200
    assert client.get('/v1/auth/me',headers=auth).status_code==401

def test_new_account_subject_is_stable_without_email_and_cascades(setup):
    client,app,key=setup
    first,_=login(client,key)
    assert first.status_code==200
    second,_=login(client,key,email=None,email_verified=False)
    assert second.json()['user_id']==first.json()['user_id']
    private,_=login(client,key,sub='different-subject',email='relay@privaterelay.appleid.com')
    assert private.json()['user_id']!=first.json()['user_id']
    auth={'Authorization':'Bearer '+first.json()['token']}
    assert client.delete('/v1/account',headers=auth).status_code==200
    with app.state.store.connect() as db:
        assert db.execute('SELECT * FROM apple_identities WHERE subject=?',('apple-subject',)).fetchone() is None
    assert client.get('/v1/auth/me',headers=auth).status_code==401

@pytest.mark.parametrize('changes',[{'aud':'foreign.app'},{'iss':'https://attacker.example'},
    {'nonce':'wrong'},{'exp':int(time.time())-100},{'email_verified':False},{'email':None}])
def test_reject_untrusted_identity_before_creating_account(setup,changes):
    client,app,key=setup
    response,_=login(client,key,**changes)
    assert response.status_code==401
    with app.state.store.connect() as db: assert db.execute('SELECT COUNT(*) FROM users').fetchone()[0]==0

def test_expired_challenge_and_wrong_signature(setup):
    client,app,key=setup
    challenge=client.post('/v1/auth/apple/challenge').json()
    with app.state.store.connect() as db: db.execute('UPDATE apple_challenges SET expires_at=0')
    assert client.post('/v1/auth/apple',json={'challenge_id':challenge['challenge_id'],
        'identity_token':token(key,challenge['nonce'])}).status_code==401
    other=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    assert login(client,other)[0].status_code==401

def test_web_disabled_and_callback_csrf_rejected(setup):
    client,app,key=setup
    assert client.post('/oauth/apple/start',data={}).status_code==503
    assert client.post('/oauth/apple/callback',data={'state':'attacker','code':'fake'}).status_code==400

def test_apple_web_login_joins_ios_owner_and_issues_plugin_code(setup,monkeypatch):
    import base64,hashlib,re
    from dataclasses import replace
    from urllib.parse import parse_qs,urlsplit
    import httpx
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    client,app,key=setup
    native,_=login(client,key)
    private=ec.generate_private_key(ec.SECP256R1()).private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
    apple=app.state.apple_identity
    apple.settings=replace(apple.settings,apple_service_id='com.peter7z.NutritionTracker.web',
        apple_team_id='test-team',apple_key_id='test-key',apple_private_key=private)
    callback='https://chatgpt.com/connector_platform_oauth_redirect'
    registered=client.post('/register',json={'redirect_uris':[callback],'token_endpoint_auth_method':'none',
        'grant_types':['authorization_code','refresh_token'],'response_types':['code']}).json()
    verifier='a'*64
    pkce=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    redirect=client.get('/authorize',params={'client_id':registered['client_id'],'redirect_uri':callback,
        'response_type':'code','scope':'tracking:read tracking:write','resource':'http://localhost:8000/mcp',
        'code_challenge':pkce,'code_challenge_method':'S256','state':'chatgpt-state'},follow_redirects=False)
    flow=parse_qs(urlsplit(redirect.headers['location']).query)['flow'][0]
    page=client.get(redirect.headers['location'])
    assert 'Continuar con Apple' in page.text
    csrf=re.search(r'name="csrf" value="([^"]+)"',page.text)[1]
    assert client.post('/oauth/apple/start',data={'flow':flow,'csrf':'wrong'}).status_code==400
    start=client.post('/oauth/apple/start',data={'flow':flow,'csrf':csrf},follow_redirects=False)
    assert start.status_code==303
    query=parse_qs(urlsplit(start.headers['location']).query)
    state=query['state'][0]
    apple_token=token(key,query['nonce'][0],aud=apple.settings.apple_service_id)
    async def exchange(self,url,**kwargs):
        assert url=='https://appleid.apple.com/auth/token'
        assert kwargs['data']['code']=='apple-one-time-code'
        secret=jwt.decode(kwargs['data']['client_secret'],ec.generate_private_key(ec.SECP256R1()).public_key(),
                          algorithms=['ES256'],options={'verify_signature':False,'verify_aud':False})
        assert secret['sub']==apple.settings.apple_service_id
        return httpx.Response(200,json={'id_token':apple_token},request=httpx.Request('POST',url))
    monkeypatch.setattr(httpx.AsyncClient,'post',exchange)
    completed=client.post('https://localhost:8000/oauth/apple/callback',
        data={'state':state,'code':'apple-one-time-code'},headers={'Cookie':'nutrition_apple_state='+state},follow_redirects=False)
    assert completed.status_code==303
    query=parse_qs(urlsplit(completed.headers['location']).query)
    assert query['state']==['chatgpt-state']
    plugin=client.post('/token',data={'grant_type':'authorization_code','client_id':registered['client_id'],
        'code':query['code'][0],'redirect_uri':callback,'code_verifier':verifier,'resource':'http://localhost:8000/mcp'}).json()
    profile=rpc(client,plugin['access_token'],'tools/call',{'name':'get_profile','arguments':{}})['result']['structuredContent']
    assert profile['user_id']==native.json()['user_id']
    replay=client.post('https://localhost:8000/oauth/apple/callback',data={'state':state,'code':'apple-one-time-code'},
        headers={'Cookie':'nutrition_apple_state='+state},follow_redirects=False)
    assert replay.status_code==400

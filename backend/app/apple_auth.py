"""Apple identity verification and shared-account sign in. Never trust client email."""
import hashlib
import json
import secrets
import ssl
import certifi
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import urlencode
import httpx
import jwt
from fastapi import Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, ConfigDict, Field

ISSUER = 'https://appleid.apple.com'

class AppleInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    challenge_id: str = Field(min_length=20, max_length=100)
    identity_token: str = Field(min_length=20, max_length=10000)

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

class AppleIdentity:
    def __init__(self, store, settings):
        self.store, self.settings = store, settings
        self.keys = jwt.PyJWKClient(ISSUER+'/auth/keys', timeout=10, ssl_context=ssl.create_default_context(cafile=certifi.where()))

    @property
    def web_enabled(self):
        return all((self.settings.apple_service_id, self.settings.apple_team_id,
                    self.settings.apple_key_id, self.settings.apple_private_key))

    def challenge(self, audience, flow=None):
        key, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with self.store.connect() as db:
            db.execute('DELETE FROM apple_challenges WHERE expires_at<?', (int(time.time()),))
            db.execute('INSERT INTO apple_challenges VALUES(?,?,?,?,?)',
                       (digest(key), digest(nonce), audience, int(time.time())+300, flow))
        return key, digest(nonce)

    def verify(self, token, audience, nonce):
        key = self.keys.get_signing_key_from_jwt(token)
        claims = jwt.decode(token, key.key, algorithms=['RS256'], issuer=ISSUER,
                            audience=audience, options={'require':['exp','iat','iss','aud','sub','nonce']})
        if not isinstance(claims['sub'], str) or not 1<=len(claims['sub'])<=255:
            raise ValueError('invalid subject')
        if not isinstance(claims['nonce'], str) or not secrets.compare_digest(claims['nonce'], nonce):
            raise ValueError('invalid nonce')
        return claims

    def authenticate(self, challenge, token, audience):
        with self.store.connect() as db:
            row = db.execute('SELECT * FROM apple_challenges WHERE hash=?', (digest(challenge),)).fetchone()
        if not row or row['expires_at']<=time.time() or row['audience']!=audience:
            raise ValueError('expired challenge')
        claims = self.verify(token, audience, row['nonce'])
        # Atomic consumption prevents replay, including simultaneous valid submissions.
        with self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            current=db.execute('SELECT * FROM apple_challenges WHERE hash=?', (digest(challenge),)).fetchone()
            if not current or current['expires_at']<=time.time(): raise ValueError('used challenge')
            owner = self.account(db, claims)
            db.execute('DELETE FROM apple_challenges WHERE hash=?', (digest(challenge),))
        return owner, row['flow_hash']

    def account(self, db, claims):
        linked=db.execute('SELECT user_id FROM apple_identities WHERE subject=?', (claims['sub'],)).fetchone()
        if linked: return linked['user_id']
        email=claims.get('email')
        verified=claims.get('email_verified') in (True, 'true')
        if not verified or not isinstance(email,str) or '@' not in email or len(email)>254:
            raise ValueError('verified Apple email required for first connection')
        email=email.strip().lower()
        user=db.execute('SELECT id FROM users WHERE email=?', (email,)).fetchone()
        owner=user['id'] if user else str(uuid.uuid4())
        if not user:
            # A random unknowable password maintains legacy schema without password login access.
            from .main import password_hash
            db.execute('INSERT INTO users(id,email,password,created_at) VALUES(?,?,?,?)',
                (owner,email,password_hash(secrets.token_urlsafe(64)),datetime.now(timezone.utc).isoformat()))
        db.execute('INSERT INTO apple_identities VALUES(?,?)', (claims['sub'],owner))
        return owner

    def client_secret(self):
        return jwt.encode({'iss':self.settings.apple_team_id,'iat':int(time.time()),
            'exp':int(time.time())+300,'aud':ISSUER,'sub':self.settings.apple_service_id},
            self.settings.apple_private_key.replace('\\n','\n'),algorithm='ES256',
            headers={'kid':self.settings.apple_key_id})

    def routes(self, app, make_session, identity, auth_limit):
        from .main import APIError
        @app.post('/v1/auth/apple/challenge')
        def challenge(request:Request):
            auth_limit(request)
            key,nonce=self.challenge(self.settings.apple_app_id)
            return {'challenge_id':key,'nonce':nonce}

        @app.post('/v1/auth/apple')
        def login(body:AppleInput, request:Request):
            auth_limit(request)
            try: owner,_=self.authenticate(body.challenge_id,body.identity_token,self.settings.apple_app_id)
            except jwt.PyJWKClientConnectionError: raise APIError('apple_unavailable',503) from None
            except (jwt.PyJWTError,ValueError): raise APIError('invalid_apple_credentials',401) from None
            with self.store.connect() as db: return make_session(db,owner)

        @app.get('/v1/auth/me')
        def me(owner=Depends(identity)):
            with self.store.connect() as db:
                row=db.execute('SELECT id,email FROM users WHERE id=?',(owner,)).fetchone()
            return {'user_id':row['id'],'email':row['email']}

        @app.post('/oauth/apple/start')
        async def start(request:Request):
            auth_limit(request)
            if not self.web_enabled: return HTMLResponse('Apple no está configurado para la web.',status_code=503)
            form=await request.form()
            flow,csrf=str(form.get('flow','')),str(form.get('csrf',''))
            if not csrf or not secrets.compare_digest(csrf,request.cookies.get('nutrition_oauth_csrf','')):
                return HTMLResponse('Conexión inválida.',status_code=400)
            with self.store.connect() as db:
                row=db.execute('SELECT * FROM oauth_flows WHERE hash=? AND expires_at>?',
                               (digest(flow),int(time.time()))).fetchone()
            if not row or not secrets.compare_digest(row['csrf_hash'],digest(csrf)):
                return HTMLResponse('Conexión vencida.',status_code=400)
            state,nonce=self.challenge(self.settings.apple_service_id,digest(flow))
            response=RedirectResponse(ISSUER+'/auth/authorize?'+urlencode({
                'client_id':self.settings.apple_service_id,'redirect_uri':self.settings.public_url.rstrip('/')+'/oauth/apple/callback',
                'response_type':'code','response_mode':'form_post','scope':'email name','state':state,'nonce':nonce}),status_code=303)
            # Apple posts cross-site; bind the callback to the initiating browser.
            response.set_cookie('nutrition_apple_state',state,httponly=True,secure=True,samesite='none',max_age=300,path='/oauth/apple/callback')
            return response

        @app.post('/oauth/apple/callback')
        async def callback(request:Request):
            auth_limit(request)
            form=await request.form()
            state,code=str(form.get('state','')),str(form.get('code',''))
            if not self.web_enabled or not state or not code or len(code)>2000 or not secrets.compare_digest(state,request.cookies.get('nutrition_apple_state','')):
                return HTMLResponse('No se pudo conectar Apple. Volvé a conectar el plugin.',status_code=400)
            try:
                async with httpx.AsyncClient(timeout=15) as client:
                    result=await client.post(ISSUER+'/auth/token',data={'client_id':self.settings.apple_service_id,
                        'client_secret':self.client_secret(),'code':code,'grant_type':'authorization_code',
                        'redirect_uri':self.settings.public_url.rstrip('/')+'/oauth/apple/callback'})
                    result.raise_for_status()
                from starlette.concurrency import run_in_threadpool
                owner,flow_hash=await run_in_threadpool(self.authenticate,state,result.json()['id_token'],self.settings.apple_service_id)
                response=await run_in_threadpool(app.state.plugin_oauth.approve_owner,owner,flow_hash)
                response.delete_cookie('nutrition_apple_state',path='/oauth/apple/callback')
                return response
            except (jwt.PyJWTError,ValueError,KeyError,httpx.HTTPError):
                return HTMLResponse('No se pudo conectar Apple. Volvé a conectar el plugin.',status_code=400)

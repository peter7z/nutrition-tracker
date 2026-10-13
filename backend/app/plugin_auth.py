"""Persisted OAuth authorization-code + PKCE provider for the private plugin."""
import hashlib
import html
import json
import re
import secrets
import time
from urllib.parse import urlencode, urlsplit
from fastapi import Request
from fastapi.responses import HTMLResponse, RedirectResponse
from mcp.server.auth.provider import (AccessToken, AuthorizationCode, AuthorizationParams,
    AuthorizeError, RefreshToken, RegistrationError, TokenError)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from .models import AuthInput

SCOPES = ['tracking:read', 'tracking:write']

def hashed(value):
    return hashlib.sha256(value.encode()).hexdigest()

class PluginOAuth:
    def __init__(self, store, settings):
        self.store, self.settings = store, settings
        self.base = settings.public_url.rstrip('/')
        self.resource = self.base + '/mcp'

    async def get_client(self, client_id):
        with self.store.connect() as db:
            row = db.execute('SELECT metadata FROM oauth_clients WHERE id=?', (client_id,)).fetchone()
        return OAuthClientInformationFull.model_validate_json(row['metadata']) if row else None

    async def register_client(self, client_info):
        if client_info.token_endpoint_auth_method != 'none':
            raise RegistrationError(error='invalid_client_metadata', error_description='Use a public PKCE client.')
        if not client_info.redirect_uris or len(client_info.redirect_uris)>5:
            raise RegistrationError(error='invalid_redirect_uri', error_description='A registered callback is required.')
        for uri in client_info.redirect_uris:
            value = str(uri)
            allowed = value in self.settings.oauth_redirects.split(',')
            allowed |= bool(re.fullmatch(r'https://chatgpt\.com/connector/oauth/[A-Za-z0-9_-]+', value))
            if self.settings.environment != 'production':
                parts = urlsplit(value)
                allowed |= parts.scheme == 'http' and parts.hostname in ('localhost','127.0.0.1') and not parts.fragment and not parts.username
            if not allowed:
                raise RegistrationError(error='invalid_redirect_uri', error_description='Callback is not allowed.')
        with self.store.connect() as db:
            db.execute('INSERT INTO oauth_clients VALUES(?,?)', (client_info.client_id, client_info.model_dump_json()))

    async def authorize(self, client, params):
        if params.resource != self.resource or not re.fullmatch(r'[A-Za-z0-9_-]{43}', params.code_challenge):
            raise AuthorizeError(error='invalid_request', error_description='Resource and S256 PKCE are required.')
        if not params.scopes or not set(params.scopes)<=set(SCOPES):
            raise AuthorizeError(error='invalid_scope', error_description='Unsupported permissions.')
        flow = secrets.token_urlsafe(32)
        with self.store.connect() as db:
            db.execute('DELETE FROM oauth_flows WHERE expires_at<?', (int(time.time()),))
            db.execute('INSERT INTO oauth_flows VALUES(?,?,?,?,?)',
                (hashed(flow), client.client_id, params.model_dump_json(), int(time.time())+600, ''))
        return self.base+'/oauth/connect?'+urlencode({'flow':flow})

    async def load_authorization_code(self, client, authorization_code):
        with self.store.connect() as db:
            row = db.execute('SELECT payload FROM oauth_codes WHERE hash=? AND client_id=?',
                (hashed(authorization_code), client.client_id)).fetchone()
        return AuthorizationCode(code=authorization_code, **json.loads(row['payload'])) if row else None

    def issue_tokens(self, db, owner, client_id, scopes, family=None):
        access, refresh = secrets.token_urlsafe(48), secrets.token_urlsafe(48)
        family = family or secrets.token_urlsafe(32)
        now = int(time.time())
        for token, kind, expires in ((access, 'access', now+3600), (refresh, 'refresh', now+30*86400)):
            db.execute('INSERT INTO oauth_tokens VALUES(?,?,?,?,?,?,?,?,?)',
                (hashed(token), owner, client_id, kind, json.dumps(scopes), self.resource, expires, family, 0))
        return OAuthToken(access_token=access, token_type='Bearer', expires_in=3600,
            refresh_token=refresh, scope=' '.join(scopes))

    async def exchange_authorization_code(self, client, authorization_code):
        with self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT payload FROM oauth_codes WHERE hash=? AND client_id=?',
                (hashed(authorization_code.code), client.client_id)).fetchone()
            if not row or json.loads(row['payload'])['expires_at']<time.time():
                raise TokenError(error='invalid_grant', error_description='Code expired or already used.')
            db.execute('DELETE FROM oauth_codes WHERE hash=?', (hashed(authorization_code.code),))
            return self.issue_tokens(db, authorization_code.subject, client.client_id, authorization_code.scopes)

    def load_token(self, token, kind, client_id=None):
        with self.store.connect() as db:
            row = db.execute('SELECT * FROM oauth_tokens WHERE hash=? AND kind=?', (hashed(token), kind)).fetchone()
        if not row or row['revoked'] or row['expires_at']<=time.time() or row['resource']!=self.resource:
            return None
        if client_id and row['client_id']!=client_id:
            return None
        cls = AccessToken if kind=='access' else RefreshToken
        return cls(token=token, client_id=row['client_id'], scopes=json.loads(row['scopes']),
            expires_at=row['expires_at'], resource=row['resource'], subject=row['user_id'])

    async def load_access_token(self, token):
        return self.load_token(token, 'access')

    async def load_refresh_token(self, client, refresh_token):
        return self.load_token(refresh_token, 'refresh', client.client_id)

    async def exchange_refresh_token(self, client, refresh_token, scopes):
        with self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM oauth_tokens WHERE hash=?', (hashed(refresh_token.token),)).fetchone()
            if not row or row['revoked'] or row['expires_at']<=time.time() or row['client_id']!=client.client_id:
                raise TokenError(error='invalid_grant', error_description='Refresh token expired or already used.')
            if not set(scopes)<=set(json.loads(row['scopes'])):
                raise TokenError(error='invalid_scope', error_description='Cannot increase permissions.')
            db.execute('UPDATE oauth_tokens SET revoked=1 WHERE family=?', (row['family'],))
            return self.issue_tokens(db, row['user_id'], client.client_id, scopes, row['family'])

    async def revoke_token(self, token):
        with self.store.connect() as db:
            row = db.execute('SELECT family FROM oauth_tokens WHERE hash=?', (hashed(token.token),)).fetchone()
            if row: db.execute('UPDATE oauth_tokens SET revoked=1 WHERE family=?', (row['family'],))

    def approve_owner(self, owner, flow_hash):
        """Finish an already-consented Apple browser flow, keeping the same account owner."""
        with self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT * FROM oauth_flows WHERE hash=? AND expires_at>?',
                           (flow_hash,int(time.time()))).fetchone()
            if not row: raise ValueError('expired OAuth flow')
            params=AuthorizationParams.model_validate_json(row['params'])
            code=secrets.token_urlsafe(32)
            authorization=AuthorizationCode(code=code,scopes=params.scopes,expires_at=time.time()+300,
                client_id=row['client_id'],code_challenge=params.code_challenge,redirect_uri=params.redirect_uri,
                redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,resource=params.resource,subject=owner)
            db.execute('INSERT INTO oauth_codes VALUES(?,?,?,?)',
                (hashed(code),owner,row['client_id'],authorization.model_dump_json(exclude={'code'})))
            db.execute('DELETE FROM oauth_flows WHERE hash=?',(flow_hash,))
        values={'code':code,'iss':self.base}
        if params.state is not None: values['state']=params.state
        separator='&' if urlsplit(str(params.redirect_uri)).query else '?'
        response=RedirectResponse(str(params.redirect_uri)+separator+urlencode(values),status_code=303)
        response.delete_cookie('nutrition_oauth_csrf',path='/oauth')
        return response

    def connect_routes(self, app, password_hash, auth_limit):
        def flow_row(db, flow):
            return db.execute('SELECT * FROM oauth_flows WHERE hash=? AND expires_at>?',
                (hashed(flow), int(time.time()))).fetchone()

        @app.get('/oauth/connect', response_class=HTMLResponse)
        def connect(request:Request, flow:str):
            csrf = secrets.token_urlsafe(32)
            with self.store.connect() as db:
                row = flow_row(db, flow)
                if not row: return HTMLResponse('Conexión vencida. Volvé a conectar el plugin.', status_code=400)
                client = db.execute('SELECT metadata FROM oauth_clients WHERE id=?', (row['client_id'],)).fetchone()
                name = json.loads(client['metadata']).get('client_name') or 'ChatGPT'
                params = AuthorizationParams.model_validate_json(row['params'])
                db.execute('UPDATE oauth_flows SET csrf_hash=? WHERE hash=?', (hashed(csrf), hashed(flow)))
            permissions = '<li>Consultar comidas, peso y progreso.</li>'
            if 'tracking:write' in params.scopes: permissions += '<li>Registrar y corregir tracking cuando lo pidas.</li>'
            apple_button = ''
            if app.state.apple_identity.web_enabled:
                apple_button = f'<form method="post" action="/oauth/apple/start"><input type="hidden" name="flow" value="{html.escape(flow)}"><input type="hidden" name="csrf" value="{csrf}"><button>Continuar con Apple y autorizar</button></form>'
            page = f''' <!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Conectar Bocado Log</title><body><main><h1>Conectar Bocado Log</h1>
<p>Autorizar a {html.escape(name)} con tu cuenta de Bocado Log.</p><ul>{permissions}</ul>
<p>Tu contraseña se envía únicamente a Bocado Log. No se comparte con ChatGPT. No se conecta Apple Health desde esta pantalla.</p>
{apple_button}
<form method="post" action="/oauth/connect"><input type="hidden" name="flow" value="{html.escape(flow)}">
<input type="hidden" name="csrf" value="{csrf}"><p><label>Email <input type="email" name="email" required autocomplete="username"></label></p>
<p><label>Contraseña <input type="password" name="password" required minlength="12" maxlength="256" autocomplete="current-password"></label></p>
<button name="action" value="login">Ingresar y autorizar</button>
<button name="action" value="signup">Crear cuenta y autorizar</button></form></main></body></html>'''
            response = HTMLResponse(page, headers={'Content-Security-Policy':"default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'", 'Referrer-Policy':'no-referrer'})
            response.set_cookie('nutrition_oauth_csrf', csrf, httponly=True, secure=self.settings.environment=='production', samesite='lax', max_age=600, path='/oauth')
            return response

        @app.post('/oauth/connect')
        async def approve(request:Request):
            from starlette.concurrency import run_in_threadpool
            form = await request.form()
            return await run_in_threadpool(complete, request, dict(form))

        def complete(request, form):
            auth_limit(request)
            flow, csrf = str(form.get('flow','')), str(form.get('csrf',''))
            if not csrf or not secrets.compare_digest(csrf, request.cookies.get('nutrition_oauth_csrf','')):
                return HTMLResponse('Conexión inválida. Volvé a conectar.', status_code=400)
            try: credentials = AuthInput(email=form.get('email',''), password=form.get('password',''))
            except ValueError: return HTMLResponse('Revisá email y contraseña (mínimo 12 caracteres).', status_code=400)
            import uuid
            with self.store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                row = flow_row(db, flow)
                if not row or not secrets.compare_digest(row['csrf_hash'], hashed(csrf)):
                    return HTMLResponse('Conexión inválida o vencida.', status_code=400)
                user = db.execute('SELECT * FROM users WHERE email=?', (credentials.email,)).fetchone()
                if form.get('action')=='signup':
                    if user: return HTMLResponse('No se pudo crear la cuenta. Usá ingresar si ya tenés una.', status_code=400)
                    owner = str(uuid.uuid4())
                    from datetime import datetime, timezone
                    db.execute('INSERT INTO users(id,email,password,created_at) VALUES(?,?,?,?)',
                        (owner, credentials.email, password_hash(credentials.password), datetime.now(timezone.utc).isoformat()))
                elif form.get('action')=='login':
                    saved = user['password'] if user else password_hash('dummy login password', salt='00'*16)
                    valid = secrets.compare_digest(saved, password_hash(credentials.password, saved.split(':')[0]))
                    if not user or not valid: return HTMLResponse('Email o contraseña incorrectos. Volvé atrás para reintentar.', status_code=400)
                    owner = user['id']
                else: return HTMLResponse('Acción inválida.', status_code=400)
                params = AuthorizationParams.model_validate_json(row['params'])
                code = secrets.token_urlsafe(32)
                authorization = AuthorizationCode(code=code, scopes=params.scopes, expires_at=time.time()+300,
                    client_id=row['client_id'], code_challenge=params.code_challenge, redirect_uri=params.redirect_uri,
                    redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly, resource=params.resource, subject=owner)
                db.execute('INSERT INTO oauth_codes VALUES(?,?,?,?)',
                    (hashed(code), owner, row['client_id'], authorization.model_dump_json(exclude={'code'})))
                db.execute('DELETE FROM oauth_flows WHERE hash=?', (hashed(flow),))
            values = {'code':code,'iss':self.base}
            if params.state is not None: values['state']=params.state
            separator = '&' if urlsplit(str(params.redirect_uri)).query else '?'
            response = RedirectResponse(str(params.redirect_uri)+separator+urlencode(values), status_code=303)
            response.delete_cookie('nutrition_oauth_csrf', path='/oauth')
            return response

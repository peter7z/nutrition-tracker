import uuid
from unittest.mock import patch
from fastapi.testclient import TestClient
from tests.ui_server import create_ui_app


def test_native_fixture_real_auth_and_sync_consumption_correction_hypothesis_close_without_openai():
    # Any unexpected provider HTTP call fails; test-service responses never call OpenAI.
    with patch('urllib.request.urlopen',side_effect=AssertionError('No real provider network allowed')):
        with TestClient(create_ui_app()) as client:
            account=client.post('/v1/auth/signup',json={'email':'ui-fixture@example.com','password':'synthetic fixture password'}).json()
            owner={'Authorization':'Bearer '+account['token']}
            def chat(text): return client.post('/v1/chat',headers=owner,json={'request_id':str(uuid.uuid4()),'day':'2026-10-09','text':text})
            first=chat('Comí 150 g de banana')
            assert first.status_code==200
            proposal=first.json()['proposals'][0]
            assert proposal['quantity']==150 and proposal['nutrients']['energy']==133.5
            assert client.get('/v1/state',headers=owner).json()['records']==[]
            identifier=str(uuid.uuid4())
            draft=dict(name='Banana',mealName='Meal',consumedAt='2026-10-09T12:00:00-03:00',amount=150,unit='gram',preparation='raw',nutrition=proposal['nutrients'],basis='perServing',conversion={'gramsPerServing':150},source='estimate',notes='Synthetic UI fixture')
            def sync(version,amount,revision):
                current={**draft,'amount':amount}
                return client.post('/v1/sync',headers=owner,json={'request_id':str(uuid.uuid4()),'base_revision':revision,'operations':[{'operation_id':str(uuid.uuid4()),'action':'upsert','kind':'entry','id':identifier,'expected_version':version,'payload':{'version':version+1,'draft':current}}]})
            assert sync(0,150,0).status_code==200
            correction=chat('Eran 100 g')
            assert correction.status_code==200
            corrected=correction.json()['proposals'][0]
            assert corrected['entry_id']==identifier and corrected['expected_version']==1
            assert corrected['quantity']==100 and corrected['nutrients']['energy']==89
            assert sync(1,100,1).status_code==200
            hypothetical=chat('¿Y si como banana?')
            assert hypothetical.status_code==200 and hypothetical.json()['proposals']==[]
            close=chat('Cerrá el día')
            assert close.status_code==200 and close.json()['proposals']==[]
            assert 'no hace falta cerrar' in close.json()['message']
            state=client.get('/v1/state',headers=owner).json()
            assert state['revision']==2 and next(r for r in state['records'] if r['kind']=='entry')['payload']['draft']['amount']==100
            assert client.get('/v1/state').status_code==401
            assert client.delete('/v1/account',headers=owner).status_code==200

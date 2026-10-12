import pytest
from tests.test_backend import setup,sync,operation,uid

def enable(client,headers):
    response=client.post('/v1/health/weight/consent',headers=headers,json={'enabled':True})
    assert response.status_code==200
    return response.json()['version']

def wire(version,identifier=None,kg=80):
    return {'request_id':uid(),'consent_version':version,'samples':[{'sample_id':identifier or uid(),
        'recorded_at':'2026-10-12T08:00:00-03:00','kilograms':kg}],'deleted_ids':[]}

def upload(client,headers,payload):
    return client.post('/v1/health/weight/sync',headers=headers,json=payload)

def test_consent_is_explicit_and_owner_scoped(setup):
    client,_,_,first,second=setup
    assert client.get('/v1/health/weight/consent').status_code==401
    assert not client.get('/v1/health/weight/consent',headers=first).json()['enabled']
    assert upload(client,first,wire(1)).status_code==403
    version=enable(client,first)
    assert upload(client,first,wire(version)).status_code==200
    assert upload(client,second,wire(version)).status_code==403
    assert client.get('/v1/state',headers=second).json()['records']==[]
    assert client.post('/v1/health/weight/consent',headers=first,json={'enabled':True,'delete_data':True}).status_code==422

def test_receipt_retries_sample_dedup_and_shared_diary(setup):
    client,_,_,first,_=setup
    version=enable(client,first);body=wire(version)
    receipt=upload(client,first,body)
    assert receipt.status_code==200 and receipt.json()['saved']
    assert upload(client,first,body).json()==receipt.json()
    assert upload(client,first,{**body,'samples':[{**body['samples'][0],'kilograms':81}]}).status_code==409
    assert upload(client,first,{**body,'request_id':uid()}).json()['revision']==1
    records=client.get('/v1/state',headers=first).json()['records']
    assert len(records)==1 and records[0]['payload']['source']=='appleHealth'
    assert records[0]['payload']['sourceSampleID']==body['samples'][0]['sample_id']
    assert records[0]['payload']['kilograms']==80
    day=client.get('/v1/diary?day=2026-10-12',headers=first).json()
    assert day['weights'][0]['kilograms']==80 and day['weights'][0]['source']=='appleHealth'

def test_real_deletions_win_over_delayed_devices_and_preserve_manual_weights(setup):
    client,_,_,first,_=setup
    version=enable(client,first);body=wire(version)
    assert upload(client,first,body).status_code==200
    manual=uid()
    assert sync(client,first,[operation(kind='weight',id=manual,payload={'id':manual,'recordedAt':'2026-10-12T10:00:00Z','kilograms':82,'source':'manual'})],1).status_code==200
    deletion={'request_id':uid(),'consent_version':version,'samples':[],'deleted_ids':[body['samples'][0]['sample_id']]}
    assert upload(client,first,deletion).status_code==200
    assert upload(client,first,{**body,'request_id':uid()}).status_code==200
    records=client.get('/v1/state',headers=first).json()['records']
    assert len(records)==1 and records[0]['id']==manual

def test_revocation_invalidates_pending_upload_and_can_delete_only_health_copy(setup):
    client,_,_,first,_=setup
    version=enable(client,first);body=wire(version)
    assert upload(client,first,body).status_code==200
    assert client.post('/v1/health/weight/consent',headers=first,json={'enabled':False}).status_code==200
    assert upload(client,first,body).status_code==403
    assert len(client.get('/v1/state',headers=first).json()['records'])==1
    new_version=enable(client,first)
    assert new_version>version and upload(client,first,body).status_code==403
    assert client.post('/v1/health/weight/consent',headers=first,json={'enabled':False,'delete_data':True}).status_code==200
    assert client.get('/v1/state',headers=first).json()['records']==[]

@pytest.mark.parametrize('invalid',[True,-1,0,1000,'80'])
def test_invalid_weight_or_extra_health_metrics_are_rejected(setup,invalid):
    client,_,_,first,_=setup
    version=enable(client,first)
    assert upload(client,first,wire(version,kg=invalid)).status_code==422
    assert upload(client,first,{**wire(version),'steps':1000}).status_code==422
    assert client.get('/v1/state',headers=first).json()['records']==[]

import pytest
from tests.test_backend import setup, sync, operation, draft, uid


def test_web_page_assets_and_authentication(setup):
    client,_,_,first,second=setup
    for path in ('/','/web'):
        response=client.get(path)
        assert response.status_code==200 and 'Tu diario' in response.text
        assert "frame-ancestors 'none'" in response.headers['content-security-policy']
        assert response.headers['cache-control']=='no-store'
        assert 'password' in response.text
    assert client.get('/web/assets/diary.js').status_code==200
    assert client.get('/web/assets/style.css').status_code==200
    assert client.get('/v1/diary').status_code==401
    assert client.get('/v1/diary?day=invalid',headers=first).status_code==422
    assert client.get('/v1/diary',headers=first).json()['time_zone']=='America/Montevideo'


def test_web_diary_scaled_nutrients_nulls_and_account_isolation(setup):
    client,_,_,first,second=setup
    food=draft(150)
    food['name']='<img src=x onerror=alert(1)>'
    food['nutrition']['fiber']=2.6
    assert sync(client,first,[operation(payload={'draft':food})]).status_code==200
    day=client.get('/v1/diary?day=2026-10-08',headers=first).json()
    assert day['revision']==1 and day['totals']['energy']==133.5
    assert day['totals']['fiber']==pytest.approx(3.9) and day['totals']['saturatedFat'] is None
    assert len(day['entries'])==1
    assert day['entries'][0]['totals']==day['totals']
    assert day['entries'][0]['draft']['name']==food['name']
    assert client.get('/v1/diary?day=2026-10-08',headers=second).json()['entries']==[]


def test_web_closure_uses_daily_summary_without_adding_food(setup):
    client,_,_,first,_=setup
    history_id=uid()
    history={'id':history_id,'dayID':'2026-10-08','nutrients':{'energy':2200,'fiber':30},
        'isClosed':True,'notes':'Total diario','importBatchID':uid(),'sourceRow':'fixture'}
    day={'id':'2026-10-08','version':1,'isClosed':True,'summaries':[{'id':uid(),'version':1,
        'completeness':'incomplete','intakeSource':'historical','totals':{},'entryVersions':{}}]}
    assert sync(client,first,[operation(),operation(kind='historical',id=history_id,payload=history),
        operation(kind='day',payload=day)]).status_code==200
    result=client.get('/v1/diary?day=2026-10-08',headers=first).json()
    assert result['closed'] and result['intake_selection']=='historical'
    assert result['totals']['energy']==2200 and result['totals']['fiber']==30
    assert result['totals']['protein'] is None
    assert len(result['entries'])==1 and result['entries'][0]['totals']['energy']==133.5

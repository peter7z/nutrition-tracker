"""Loopback-only native acceptance fixture. No OpenAI calls, keys or production data.

From backend/: python -m tests.ui_server --port 8766
The real auth, owner filtering, sync, chat guards and SQLite migrations run unchanged.
Responses are deterministic test data for banana consumption/correction/planning/closure.
"""
import argparse
import re
import tempfile
import uuid
from pathlib import Path

from app.config import Settings
from app.main import create_app
from app.models import AssistantOutput


class FixtureResponses:
    def analyze(self, context, text, image=None):
        normalized=text.casefold()
        proposal=dict(operation_id=str(uuid.uuid4()),action='add',entry_id=None,expected_version=None,name='Banana',quantity=150,unit='gram',state='raw',day=context['day'],nutrients=dict(energy=133.5,protein=1.65,carbohydrates=34.2,fat=.45,saturatedFat=.15),assumptions=['Deterministic UI test fixture; estimated banana portion, editable quantity.'],requires_clarification=False)
        message='Fixture: revisá la banana estimada y confirmá la cantidad antes de registrarla.'
        intent='consumed'; proposals=[]
        if re.search(r'\b(y si|si como|what if|qué ceno|que ceno)\b',normalized):
            intent='hypothetical'; message='Fixture: esta hipótesis no registra consumo.'
        elif re.search(r'\b(cerr[aá]|cerrar|close)\b',normalized):
            intent='close';proposal.update(action='close_day',name=None,quantity=None,unit=None,state=None,nutrients=None)
            proposals=[proposal];message='Fixture: revisá el cierre del día antes de confirmarlo.'
        elif re.search(r'\b(eran|correg[ií]|actually|correct)\b',normalized):
            matches=[e for e in context['entries'] if 'banana' in e['draft']['name'].casefold()]
            proposal['action']='update';intent='correction';proposals=[proposal]
            if len(matches)==1:
                proposal.update(entry_id=matches[0]['id'],expected_version=matches[0]['version'])
            else:
                proposal['requires_clarification']=True
                proposal['assumptions'].append('Select one banana entry; this fixture does not guess an ambiguous record.')
            message='Fixture: cantidad corregida en propuesta; confirmá para aplicar.'
        elif 'banana' in normalized:
            proposals=[proposal]
        else:
            intent='query';message='Fixture: este servidor de prueba sólo cubre banana, corrección, hipótesis y cierre.'
        if proposals and proposal['action'] in ('add','update'):
            match=re.search(r'(\d+(?:[.,]\d+)?)\s*(?:g|gramos|grams)\b',normalized)
            quantity=float(match.group(1).replace(',','.')) if match else 150.0
            proposal['quantity']=quantity
            proposal['nutrients']={key:value*quantity/100 for key,value in dict(energy=89,protein=1.1,carbohydrates=22.8,fat=.3,saturatedFat=.1).items()}
        return AssistantOutput.model_validate(dict(message=message,intent=intent,proposals=proposals)),0,0


def create_ui_app():
    directory=tempfile.TemporaryDirectory(prefix='nutrition-native-ui-')
    settings=Settings(database=str(Path(directory.name)/'fixture.sqlite3'),environment='test',openai_key='',model='deterministic-native-ui-fixture',input_price=.000001,output_price=.000001,daily_budget=1,global_budget=1,requests_per_hour=1000,auth_per_minute=1000)
    app=create_app(settings,FixtureResponses())
    app.state.ui_fixture=True
    app.state.fixture_directory=directory
    app.add_event_handler('shutdown',directory.cleanup)
    return app


if __name__=='__main__':
    import uvicorn
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',type=int,default=8766)
    args=parser.parse_args()
    if not 1<=args.port<=65535: parser.error('Invalid local port')
    uvicorn.run(create_ui_app(),host='127.0.0.1',port=args.port,access_log=False,log_level='warning')

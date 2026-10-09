import json
import math
from uuid import UUID
from datetime import datetime
from zoneinfo import ZoneInfo
from pydantic import ValidationError
from .models import EntryDraft,Product,Recipe,Profile,Weight,Activity,Historical,Resolution

NUTRIENTS=('energy','protein','carbohydrates','fat','saturatedFat')

def safe_payload(payload):
    def walk(v):
        if isinstance(v,float) and not math.isfinite(v): raise ValueError('nonfinite number')
        if isinstance(v,dict):
            for k,n in v.items():
                if k.lower().startswith(('health','applehealth')) or 'deviceidentifier' in k.lower(): raise ValueError('health data forbidden')
                if k.lower()=='source' and str(n).lower() in ('health','healthkit','applehealth'): raise ValueError('health data forbidden')
                walk(n)
        if isinstance(v,list):
            for n in v: walk(n)
    walk(payload)
    if len(json.dumps(payload))>100000: raise ValueError('payload too large')
    if str(payload.get('source','')).lower() in ('health','healthkit','applehealth'): raise ValueError('health data forbidden')

def validate_payload(kind,payload,identifier):
    safe_payload(payload)
    if kind=='entry':
        draft=EntryDraft.model_validate(payload.get('draft',payload))
        if str(UUID(str(payload.get('id',identifier))))!=identifier: raise ValueError('entry identifier mismatch')
        return draft
    if kind in ('historical','resolution'):
        (Historical if kind=='historical' else Resolution).model_validate(payload)
    if kind in ('product','recipe','profile','weight','activity'):
        model={'product':Product,'recipe':Recipe,'profile':Profile,'weight':Weight,'activity':Activity}[kind]
        model.model_validate(payload)
        if kind!='profile' and str(UUID(str(payload['id'])))!=identifier: raise ValueError('identifier mismatch')
    if kind=='weight':
        n=payload.get('kilograms',payload.get('weightKg',payload.get('value')))
        if isinstance(n,bool) or not isinstance(n,(int,float)) or not 0<n<1000: raise ValueError('weight required')
    if kind=='activity':
        for key in ('durationMinutes','activeEnergy','activeCalories'):
            if key in payload and payload[key] is not None:
                n=payload[key]
                if isinstance(n,bool) or not isinstance(n,(int,float)) or not 0<=n<=100000: raise ValueError('invalid activity')
    if kind=='day':
        for summary in payload.get('summaries',[]):
            if not isinstance(summary,dict): raise ValueError('invalid day summary')
            if summary.get('intakeSource')=='health':
                totals=summary.get('totals',{})
                if any(isinstance(totals.get(key),dict) and (totals[key].get('known',0)!=0 or totals[key].get('knownCount',0)!=0) for key in NUTRIENTS): raise ValueError('health data forbidden in closure history')
        if not isinstance(payload.get('date',payload.get('day',payload.get('id'))),str): raise ValueError('day required')
        datetime.fromisoformat(payload.get('date',payload.get('day',payload.get('id')))[:10])
        if 'status' in payload and payload['status'] not in ('open','closed'): raise ValueError('invalid day status')
    if kind=='goal':
        for key in NUTRIENTS:
            n=(payload.get('nutrition',payload.get('targets',payload.get('goals',payload))) or {}).get(key)
            if n is not None and (isinstance(n,bool) or not isinstance(n,(int,float)) or not 0<n<=100000): raise ValueError('invalid goal')
    return None

def context_for(db,owner,day):
    rows=list(db.execute('SELECT * FROM records WHERE user_id=? AND deleted=0',(owner,)))
    records=[dict(id=r['id'],kind=r['kind'],version=r['version'],payload=json.loads(r['payload'])) for r in rows]
    profile=next((r['payload'] for r in records if r['kind']=='profile'),{})
    try: zone=ZoneInfo(profile.get('timeZoneIdentifier','America/Montevideo'))
    except Exception: zone=ZoneInfo('America/Montevideo')
    entries=[]
    for r in records:
        if r['kind']!='entry': continue
        draft=EntryDraft.model_validate(r['payload'].get('draft',r['payload']))
        if draft.consumedAt.astimezone(zone).date().isoformat()==day:
            provider_draft=draft.model_dump(mode='json',exclude={'productID','productVersion','recipeID','recipeVersion'})
            entries.append(dict(id=r['id'],version=r['payload'].get('version',r['version']),draft=provider_draft))
    totals={key:None for key in NUTRIENTS}
    if entries:
        for key in NUTRIENTS:
            values=[]
            for entry in entries:
                d=EntryDraft.model_validate(entry['draft'])
                n=getattr(d.nutrition,key)
                if n is None: break
                values.append(n*d.multiplier())
            else: totals[key]=sum(values)
    goals=[r['payload'] for r in records if r['kind']=='goal' and str(r['payload'].get('effectiveDay',r['payload'].get('effectiveFrom',r['payload'].get('effectiveDate','0000'))))[:10]<=day]
    goals.sort(key=lambda p:str(p.get('effectiveDay',p.get('effectiveFrom',p.get('effectiveDate','0000')))))
    historical=[r['payload'] for r in records if r['kind']=='historical' and r['payload'].get('dayID')==day]
    resolutions=[r['payload']['selection'] for r in records if r['kind']=='resolution' and r['payload'].get('dayID')==day]
    selection=resolutions[-1] if resolutions else None
    needs_reconciliation=bool(entries and historical and selection is None) or len(historical)>1
    if selection=='health' or needs_reconciliation:
        totals={key:None for key in NUTRIENTS}
    elif selection=='historical' or (not entries and len(historical)==1):
        totals={key:historical[0]['nutrients'].get(key) if historical else None for key in NUTRIENTS}
    frozen=next((r['payload']['summaries'][-1] for r in records if r['kind']=='day' and str(r['payload'].get('date',r['payload'].get('day',r['payload'].get('id',''))))[:10]==day and r['payload'].get('isClosed') is True and r['payload'].get('summaries')),None)
    if frozen:
        selection=frozen.get('intakeSource') or 'manual';needs_reconciliation=False
        totals={key:(metric.get('known') if metric.get('knownCount',0)>0 and metric.get('missingCount',0)==0 else None) for key in NUTRIENTS for metric in [frozen.get('totals',{}).get(key,{})]}
        if selection=='health': totals={key:None for key in NUTRIENTS}
        goal_id=str(frozen.get('goalVersionID','')).lower()
        goals=[r['payload'] for r in records if r['kind']=='goal' and r['id'].lower()==goal_id]
        if selection=='historical': historical=[{'dayID':day,'nutrients':totals,'isClosed':True,'frozen':True}]
    def same_day(payload):
        return datetime.fromisoformat(payload['recordedAt'].replace('Z','+00:00')).astimezone(zone).date().isoformat()==day
    weights=[{'id':r['id'],'recorded_at':r['payload']['recordedAt'],'kilograms':r['payload']['kilograms']} for r in records if r['kind']=='weight' and same_day(r['payload'])]
    activities=[{'id':r['id'],'recorded_at':r['payload']['recordedAt'],'kind':r['payload']['kind'],'duration_minutes':r['payload'].get('durationMinutes'),'active_kcal':r['payload'].get('activeEnergy')} for r in records if r['kind']=='activity' and same_day(r['payload'])]
    return dict(weights=weights[-10:],activities=activities[-10:],closed=bool(frozen),intake_selection=selection or ('historical' if historical and not entries else 'manual'),needs_reconciliation=needs_reconciliation,historical_summary=historical[0] if len(historical)==1 else None,day=day,time_zone=zone.key,entries=entries[-50:],totals=totals,goals=goals[-1] if goals else None,preferences=profile.get('preferences',{})), records

def closed_day(db,owner,day):
    for r in db.execute("SELECT payload FROM records WHERE user_id=? AND kind='day' AND deleted=0",(owner,)):
        p=json.loads(r['payload'])
        if str(p.get('date',p.get('day',p.get('id',''))))[:10]==day and (p.get('status')=='closed' or p.get('isClosed') is True): return True
    return False

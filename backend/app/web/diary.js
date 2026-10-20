'use strict';
const $ = id => document.getElementById(id);
const nutrients = [['energy','Calorías','kcal'],['protein','Proteínas','g'],['carbohydrates','Carbohidratos','g'],['fat','Grasas','g'],['saturatedFat','Grasa saturada','g'],['fiber','Fibra','g'],['vitaminA','Vitamina A','mcg'],['thiamin','Tiamina (B1)','mg'],['riboflavin','Riboflavina (B2)','mg'],['niacin','Niacina (B3)','mg'],['pantothenicAcid','Ácido pantoténico (B5)','mg'],['vitaminB6','Vitamina B6','mg'],['biotin','Biotina (B7)','mcg'],['vitaminB12','Vitamina B12','mcg'],['vitaminC','Vitamina C','mg'],['vitaminD','Vitamina D','mcg'],['vitaminE','Vitamina E','mg'],['vitaminK','Vitamina K','mcg'],['folate','Folato','mcg'],['calcium','Calcio','mg'],['chloride','Cloruro','mg'],['iron','Hierro','mg'],['magnesium','Magnesio','mg'],['phosphorus','Fósforo','mg'],['potassium','Potasio','mg'],['sodium','Sodio','mg'],['zinc','Zinc','mg'],['chromium','Cromo','mcg'],['copper','Cobre','mg'],['iodine','Yodo','mcg'],['manganese','Manganeso','mg'],['molybdenum','Molibdeno','mcg'],['selenium','Selenio','mcg']];
const format = value => value == null ? '—' : new Intl.NumberFormat('es-UY',{maximumFractionDigits:1}).format(value);
let token = null, sequence = 0, controller = null;
function node(tag,text,className) { const element=document.createElement(tag); if(text!==undefined)element.textContent=text;if(className)element.className=className;return element; }
async function api(path,options={}) {
  const requestToken=token;
  const response=await fetch(path,{...options,cache:'no-store',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{}),...options.headers}});
  if(requestToken!==token)throw new DOMException('Respuesta de una sesión anterior','AbortError');
  if(response.status===401) { if(token)reset();throw new Error('Email o contraseña incorrectos, o sesión vencida. Volvé a ingresar.'); }
  if(response.status===429)throw new Error('Demasiados intentos. Esperá un momento y volvé a intentar.');
  if(!response.ok)throw new Error('No se pudieron consultar los datos. Volvé a intentar.');
  return response.json();
}
function reset() {
  token=null;sequence++;controller?.abort();controller=null;
  $('login').hidden=false;$('diary').hidden=true;$('logout').hidden=true;
  $('meals').replaceChildren();$('totals').replaceChildren();$('account').textContent='';$('freshness').textContent='';
  $('weights').replaceChildren();
}
function render(data) {
  $('day').value=data.day;
  $('day-title').textContent=new Intl.DateTimeFormat('es-UY',{dateStyle:'long',timeZone:'UTC'}).format(new Date(data.day+'T12:00:00Z'));
  $('source').textContent='Totales de '+({manual:'las comidas registradas',historical:'un resumen diario',health:'Apple Health'}[data.intake_selection]||'la fuente seleccionada')+' · '+data.time_zone;
  $('totals').replaceChildren(...nutrients.map(([key,title,unit])=>{const dl=node('dl',undefined,'metric');const coverage=data.nutrient_coverage?.[key]||{};const partial=Number(coverage.knownCount)>0&&Number(coverage.missingCount)>0;dl.append(node('dt',title));const value=partial?data.known_totals?.[key]:data.totals[key];const dd=node('dd',format(value));dd.append(node('small',' '+unit));if(partial)dd.append(node('small',` · falta dato en ${coverage.missingCount} ${coverage.missingCount===1?'comida':'comidas'}`));dl.append(dd);return dl;}));
  $('warning').hidden=!data.needs_reconciliation;
  $('warning').textContent='Hay comidas y resúmenes superpuestos. Los totales quedan pendientes hasta resolver qué fuente usar.';
  $('meal-count').textContent='('+data.entries.length+')';
  $('weights').replaceChildren(...data.weights.map(weight=>node('p',format(weight.kilograms)+' kg · '+new Intl.DateTimeFormat('es-UY',{hour:'2-digit',minute:'2-digit',timeZone:data.time_zone}).format(new Date(weight.recorded_at))+' · '+(weight.source==='appleHealth'?'Apple Health':'Registro manual'))));
  if(!data.weights.length)$('weights').append(node('p','No hay pesos registrados para esta fecha.'));
  $('meals').replaceChildren(...data.entries.map(entry=>{
    const food=entry.draft,article=node('article',undefined,'meal');
    article.append(node('h3',food.name));
    const time=new Intl.DateTimeFormat('es-UY',{hour:'2-digit',minute:'2-digit',timeZone:data.time_zone}).format(new Date(food.consumedAt));
    article.append(node('p',food.mealName+' · '+time+' · '+format(food.amount)+' '+({gram:'g',milliliter:'ml',serving:'porción(es)'}[food.unit]||food.unit)));
    // Meal totals are calculated on the server using the same portion conversion as MCP.
    article.append(node('p',nutrients.map(([key,title,unit])=>title+': '+format(entry.totals[key])+' '+unit).join(' · '),'values'));
    if(food.notes)article.append(node('p',food.notes));
    return article;
  }));
  if(!data.entries.length)$('meals').append(node('p','No hay comidas registradas para esta fecha.'));
  if(data.entries.length===50)$('meals').append(node('p','Se muestran las últimas 50 comidas. Los totales incluyen todas las entradas del día.'));
  $('freshness').textContent='Datos del servidor · actualizados a las '+new Intl.DateTimeFormat('es-UY',{timeStyle:'short'}).format(new Date());
}
async function refresh(day) {
  if(!token)return;
  const current=++sequence;controller?.abort();controller=new AbortController();$('refresh').disabled=true;$('status').textContent='';
  try { const data=await api('/v1/diary'+(day?'?day='+encodeURIComponent(day):''),{signal:controller.signal});if(current===sequence&&token)render(data); }
  catch(error) { if(error.name!=='AbortError')$('status').textContent=error.message; }
  finally { if(current===sequence)$('refresh').disabled=false; }
}
$('login-form').addEventListener('submit',async event=>{
  event.preventDefault();const button=event.submitter;button.disabled=true;$('status').textContent='';
  const form=new FormData(event.currentTarget);
  try {
    const session=await api('/v1/auth/login',{method:'POST',body:JSON.stringify({email:form.get('email'),password:form.get('password')})});
    token=session.token;event.target.reset();const profile=await api('/v1/auth/me');
    $('account').textContent=profile.email;$('login').hidden=true;$('diary').hidden=false;$('logout').hidden=false;
    await refresh();
  } catch(error) { reset();$('status').textContent=error.message; }
  finally { button.disabled=false; }
});
$('logout').addEventListener('click',async()=>{try{await api('/v1/auth/logout',{method:'POST'});}catch{}finally{reset();$('status').textContent='';}});
$('refresh').addEventListener('click',()=>refresh($('day').value));
$('day').addEventListener('change',()=>{if($('day').value)refresh($('day').value);});
function moveDay(delta) {if(!$('day').value)return;const date=new Date($('day').value+'T12:00:00Z');date.setUTCDate(date.getUTCDate()+delta);refresh(date.toISOString().slice(0,10));}
$('previous').addEventListener('click',()=>moveDay(-1));$('next').addEventListener('click',()=>moveDay(1));

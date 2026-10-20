const { chromium } = require('playwright');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
(async () => {
 const browser = await chromium.launch({headless:true, executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined});
 const page = await browser.newPage({viewport:{width:1100,height:1000}});
 page.setDefaultTimeout(10000); const errors=[];page.on('console',m=>{if(process.env.DEBUG_BRIDGE)console.log(m.text());});page.on('pageerror',e=>{errors.push(e.message);if(process.env.DEBUG_BRIDGE)console.log('pageerror',e.message);});
 const html=fs.readFileSync(`${__dirname}/../app/web/nutrition-day-widget.html`,'utf8').replace(/<script type="module">[\s\S]*?<\/script>/,'');
 const day = {day:'2026-10-14',time_zone:'America/Montevideo',totals:{energy:447,protein:7.1,carbohydrates:96.8,fat:6.6,fiber:17.4},goals:{nutrition:{energy:2000}},entries:[{draft:{name:'<script>untrusted</script>',consumedAt:'2026-10-14T10:00:00-03:00',amount:1,unit:'serving',mealName:'Desayuno',notes:'Una porción'}}],weights:[{recorded_at:'2026-10-14T09:00:00-03:00',kilograms:75,source:'appleHealth'}]};
 const progress={start_day:'2026-09-15',end_day:'2026-10-14',days:[{...day,weights:[{recorded_at:'2026-10-13T09:00:00-03:00',kilograms:76,source:'appleHealth'},{recorded_at:'2026-10-14T09:00:00-03:00',kilograms:75,source:'appleHealth'}]},{day:'2026-10-12',totals:{energy:null},weights:[]}]};
 await page.setContent(html);
 await page.evaluate(({day,progress})=>{window.calls=[];window.bocadoCallTool=async(name,args)=>{calls.push({name,args});return {structuredContent:name==='get_day'?{...day,day:args.day}:progress};};window.renderBocadoLogSummary({...day,dashboard:true,progress});},{day,progress});
 assert.equal(await page.locator('#energy').textContent(),'447');
 assert.match(await page.locator('#goal-line').textContent(),/2.000/);
 assert.equal(await page.locator('#meal-list strong').textContent(),'<script>untrusted</script>');
 const partialDay={...day,totals:{...day.totals,fiber:null},known_totals:{fiber:2.64},nutrient_coverage:{fiber:{knownCount:1,missingCount:1}},entries:[
  {draft:{name:'Kiwi',consumedAt:'2026-10-14T10:00:00-03:00',amount:88,unit:'gram',mealName:'Desayuno'},totals:{fiber:2.64}},
  {draft:{name:'Dulce de leche',consumedAt:'2026-10-14T10:00:00-03:00',amount:32,unit:'gram',mealName:'Desayuno'},totals:{fiber:null}}
 ]};
 await page.evaluate(({day,progress})=>renderBocadoLogSummary({...day,dashboard:true,progress}),{day:partialDay,progress});
 assert.equal(await page.locator('#fiber-label').textContent(),'Fibra');
 assert.equal(await page.locator('#fiber').textContent(),'2,6 g');
 assert.match(await page.locator('#notice').textContent(),/Dulce de leche/);
 await page.evaluate(({day,progress})=>renderBocadoLogSummary({...day,dashboard:true,progress}),{day,progress});
 await page.click('#previous');await page.waitForFunction(()=>document.querySelector('#day-picker').value==='2026-10-13');
 await page.click('#tab-progress');assert.equal(await page.locator('#weight-chart circle').count(),2);
 await page.locator('#weight-chart circle').last().click();assert.match(await page.locator('#chart-info').textContent(),/75 kg/);
 await page.click('[data-range="90"]');await page.waitForFunction(()=>calls.some(c=>c.args.start_day && (new Date(c.args.end_day)-new Date(c.args.start_day))/86400000===89));
 await page.locator('#day-history button').last().click();await page.waitForFunction(()=>document.querySelector('#day-picker').value==='2026-10-12');
 await page.evaluate(()=>window.bocadoCallTool=async()=>{throw Error('offline');});await page.click('#next');await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('No se pudo'));
 assert.equal(await page.locator('#day-picker').inputValue(),'2026-10-12');assert.equal(await page.locator('#energy').textContent(),'447');
 await page.setViewportSize({width:375,height:900});await page.screenshot({path:path.join(os.tmpdir(),'bocado-dashboard-mobile.png'),fullPage:true});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await page.evaluate(()=>document.documentElement.dataset.theme='dark');await page.click('#tab-progress');await page.screenshot({path:path.join(os.tmpdir(),'bocado-dashboard-dark.png'),fullPage:true});
 await page.evaluate(()=>renderBocadoLogSummary({day:'2026-10-14',dashboard:true,entries:[],totals:{energy:null},weights:[],progress:{start_day:'2026-10-08',end_day:'2026-10-14',days:[]}}));
 assert.equal(await page.locator('#weight-chart circle').count(),0);assert.match(await page.locator('#latest-weight').textContent(),/Sin mediciones/);
 assert.deepEqual(errors,[]);
 await page.setViewportSize({width:1100,height:1000});await page.evaluate(({day,progress})=>{document.documentElement.dataset.theme='light';renderBocadoLogSummary({...day,dashboard:true,progress});}, {day,progress});await page.screenshot({path:path.join(os.tmpdir(),'bocado-dashboard-progress.png'),fullPage:true});
 await page.click('#tab-day');await page.screenshot({path:path.join(os.tmpdir(),'bocado-dashboard-day.png'),fullPage:true});
 // Standard MCP Apps bridge, with a simulated parent host.
 const bundle=fs.readFileSync(`${__dirname}/../app/web/nutrition-day-app.bundle.js`,'utf8');
 await page.setContent('<iframe id="app" style="width:100%;height:950px;border:0"></iframe>');
 await page.evaluate(({html,bundle,day,progress})=>{
  window.addEventListener('message',event=>{const m=event.data;if(m?.id == null || !m?.method)return;
   const result=m.method==='ui/initialize'?{protocolVersion:m.params.protocolVersion,hostInfo:{name:'Test host',version:'1'},hostCapabilities:{serverTools:{}},hostContext:{theme:'light'}}:m.method==='tools/call'?{content:[],structuredContent:{...day,day:m.params.arguments.day}}:{};
   event.source.postMessage({jsonrpc:'2.0',id:m.id,result},'*');
   if(m.method==='ui/initialize')setTimeout(()=>event.source.postMessage({jsonrpc:'2.0',method:'ui/notifications/tool-result',params:{content:[],structuredContent:{...day,dashboard:true,progress}}},'*'),50);
  });
  document.querySelector('iframe').srcdoc=html.replace('</body>',()=>`<script type="module">${bundle.replaceAll('</script>','<\\/script>')}</script></body>`);
 },{html,bundle,day,progress});
 const frame=page.frameLocator('#app');await frame.locator('#day-picker').waitFor();await frame.locator('#previous').click();await page.waitForTimeout(100);await frame.locator('#day-picker').evaluate(e=>{if(e.value!=='2026-10-13')throw Error('Bridge navigation failed');});
 assert.deepEqual(errors,[]);await browser.close();console.log('Dashboard: navigation, ranges, weight selection, errors, mobile, dark, empty and MCP bridge passed.');
})().catch(e=>{console.error(e);process.exit(1)});

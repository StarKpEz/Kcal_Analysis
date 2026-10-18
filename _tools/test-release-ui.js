// Production UI, persistence and offline upgrade checks in fresh Chrome contexts.
const fs=require('node:fs'), path=require('node:path'), http=require('node:http');
const vm=require('node:vm'), assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const version=read('index.html').match(/const APP_VERSION = '([^']+)'/)[1];
const cacheName=read('sw.js').match(/const CACHE = '([^']+)'/)[1];
new vm.Script(read('navigation.js'));
const fixtureContext=vm.createContext({window:{}});
vm.runInContext(read('preview/demo.js')+'\nglobalThis.fixture=previewStorage.getItem("kcal.data.v5");',fixtureContext);
const fixture=fixtureContext.fixture; // Generated fictional records, never user data.
// A separate fictional 17-day energy export exercises the actual file-picker flow.
const energyDates=Array.from({length:17},(_,i)=>'2026-09-'+String(i+1).padStart(2,'0'));
const energyFile={app:'kcal-health-energy',version:1,exportedAt:new Date(Date.now()+1000).toISOString(),from:energyDates[0],through:energyDates[16],dailyTotals:['active','basal'].map(kind=>({kind,unit:'kcal',source:'Synthetic Watch',count:17,separator:'|',dates:energyDates.join('|'),values:energyDates.map((_,i)=>(kind==='active'?500:1400)+i).join('|')})),boundarySamples:Array.from({length:18},(_,i)=>{
  const date='2026-09-'+String(i+1).padStart(2,'0'),previous=i?'2026-09-'+String(i).padStart(2,'0'):'2026-08-31';
  return ['active','basal'].map(kind=>({kind,unit:'kcal',source:'Synthetic Watch',boundaryAt:date+'T00:00:00+08:00',startAt:previous+'T23:50:00+08:00',endAt:date+'T00:10:00+08:00',value:(kind==='active'?30:100)+i}));
}).flat()};
const beforeHtml=process.env.RELEASE_PREVIOUS_HTML, beforeWorker=process.env.RELEASE_PREVIOUS_SW;
let servePrevious=false;
const server=http.createServer((req,res)=>{
  const pathname=new URL(req.url,'http://localhost').pathname;
  if(pathname==='/_seed'){res.writeHead(200,{'Content-Type':'text/html'}).end('<!doctype html><title>Test seed</title>');return;}
  const relative=pathname==='/'?'index.html':decodeURIComponent(pathname.slice(1));
  if(servePrevious && ((relative==='index.html' && beforeHtml)||(relative==='sw.js' && beforeWorker))){
    res.writeHead(200,{'Content-Type':relative==='sw.js'?'text/javascript':'text/html','Cache-Control':'no-store'});
    res.end(fs.readFileSync(relative==='sw.js'?beforeWorker:beforeHtml));return;
  }
  const file=path.resolve(root,relative);
  if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return;}
  const mime={'.html':'text/html','.css':'text/css','.js':'text/javascript','.json':'application/json','.webmanifest':'application/manifest+json','.png':'image/png'};
  fs.readFile(file,(err,body)=>{if(err){res.writeHead(404).end();return;}res.writeHead(200,{'Content-Type':(mime[path.extname(file)]||'text/plain')+'; charset=utf-8','Cache-Control':'no-store'}).end(body);});
});
async function disk(page){return page.evaluate(()=>JSON.stringify(Object.keys(localStorage).sort().map(key=>[key,localStorage.getItem(key)])));}
async function ready(page){
  await page.waitForFunction(async()=>{
    const registration=await navigator.serviceWorker.getRegistration();
    return !!registration?.active && !!navigator.serviceWorker.controller;
  });
}
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url='http://127.0.0.1:'+server.address().port;
  const browser=await chromium.launch({channel:'chrome',headless:true});
  fs.mkdirSync(path.join(root,'.preview-check'),{recursive:true});
  try{
    for(const [width,height,scheme] of [[393,852,'light'],[320,740,'light'],[393,852,'dark']]){
      const context=await browser.newContext({viewport:{width,height},colorScheme:scheme,timezoneId:'Asia/Shanghai',deviceScaleFactor:2});
      const page=await context.newPage(), errors=[];
      page.setDefaultTimeout(15000);
      page.on('pageerror',error=>errors.push(error.message));
      page.on('dialog',dialog=>dialog.accept());
      await page.goto(url+'/_seed');
      await page.evaluate(data=>{localStorage.setItem('kcal.data.v5',data);localStorage.setItem('kcal.entries.v1','{}');},fixture);
      const original=await disk(page);
      const upgrade=width===393 && scheme==='light' && beforeHtml && beforeWorker;
      servePrevious=!!upgrade;
      await page.goto(url+'/#/health');
      await ready(page);
      console.log(`CHECK ${width} ${scheme}: initial offline shell ready`);
      if(upgrade){
        assert(!(await page.locator('#verLabel').textContent()).includes(version),'Upgrade must start from the actual previous page');
        assert.equal(await disk(page),original,'Starting the old page must preserve seeded records');
        servePrevious=false;
        await page.evaluate(async()=>{const registration=await navigator.serviceWorker.getRegistration();await registration.update();});
      }
      await page.waitForFunction(expected=>document.getElementById('verLabel').textContent==='v'+expected,version);
      await page.locator('#tabGlassLens[data-selected="navHealth"]').waitFor();
      await page.waitForFunction(async name=>{
        const cache=await caches.open(name);
        return !!(await cache.match(document.getElementById('appTheme').href)) && !!(await cache.match(document.querySelector('script[src*="navigation.js"]').src));
      },cacheName);
      assert.equal(await disk(page),original,'Installing the approved UI must preserve every local record and legacy key');
      assert.equal(await page.locator('#tabGlassLens').count(),1,'Production must create exactly one lens');
      const appearance=await page.evaluate(()=>{
        const nav=document.getElementById('primaryNav'),lens=getComputedStyle(document.getElementById('tabGlassLens'));
        const r=nav.getBoundingClientRect();
        return {fill:lens.backgroundColor,border:lens.borderTopWidth,shadow:lens.boxShadow,
          glass:getComputedStyle(nav,'::before').backdropFilter,body:getComputedStyle(document.body).backgroundColor,
          left:r.left,right:r.right,width:r.width,viewport:innerWidth};
      });
      assert.equal(appearance.fill,'rgba(0, 0, 0, 0)');assert.equal(appearance.border,'0px');assert.equal(appearance.shadow,'none');
      assert(appearance.glass.includes('blur(10px)'));
      assert(appearance.width<=288 && appearance.left>=16 && appearance.right<=appearance.viewport-16);
      assert.equal(appearance.body,scheme==='light'?'rgb(242, 242, 247)':'rgb(0, 0, 0)');
      await page.locator('#navDiet').click();await page.locator('#dietPage').waitFor({state:'visible'});
      await page.locator('#navHealth').click();await page.locator('#healthPage').waitFor({state:'visible'});
      await page.locator('#tabGlassLens[data-selected="navHealth"][data-moving="false"]').waitFor();
      for(const [button,panel,back] of [['btnBurn','energyActive','btnBurnBack'],['btnHealthWeight','weightBox','btnBurnBack'],['btnHealthTraining','trainingPanel','btnWellBack'],['btnHealthSleep','sleepPanel','btnWellBack'],['btnHealthImport','healthImportPanel','btnWellBack']]){
        await page.locator('#'+button).click();await page.locator('#'+panel).waitFor({state:'visible'});
        assert(await page.evaluate(()=>Math.max(document.body.scrollWidth,document.documentElement.scrollWidth)<=innerWidth+1),'Detail must fit the viewport');
        await page.locator('#'+back).click();await page.locator('#healthPage').waitFor({state:'visible'});
      }
      await page.locator('#btnSet').click();await page.locator('#dlg').waitFor({state:'visible'});
      assert.equal(await page.locator('#verLabel').textContent(),'v'+version);
      await page.locator('#btnCloseX').click();
      assert.equal(await disk(page),original,'Read-only navigation must not mutate records');
      await page.emulateMedia({reducedMotion:'reduce'});
      await page.locator('#navDiet').click();await page.locator('#tabGlassLens[data-selected="navDiet"]').waitFor();
      assert.equal(await page.evaluate(()=>document.getElementById('tabGlassLens').getAnimations().filter(a=>a.playState==='running').length),0);
      await page.emulateMedia({reducedMotion:'no-preference'});
      if(width===393)await page.screenshot({path:path.join(root,'.preview-check','production-'+scheme+'.png'),animations:'disabled'});
      await context.setOffline(true);
      await page.reload();await page.locator('#tabGlassLens[data-selected="navDiet"]').waitFor();
      assert.equal(await page.evaluate(()=>getComputedStyle(document.getElementById('primaryNav'),'::before').backdropFilter),'blur(10px) saturate(1.8)','Offline reload must keep the approved glass style');
      assert.equal(await disk(page),original,'Offline startup must preserve records');
      const before=await page.evaluate(()=>JSON.parse(buildBackup())); // App-normalized records; empty meal arrays are not entries.
      await page.locator('#navHealth').click();await page.locator('#btnBurn').click();
      await page.locator('#energyActive').fill('777');await page.locator('#btnSaveEnergy').click();
      const after=JSON.parse(await page.evaluate(()=>localStorage.getItem('kcal.data.v5')));
      const today=await page.evaluate(()=>todayKey());
      assert.equal(after.burn[today].active,777);
      for(const category of ['entries','weight','weightMeta','training','sleep','settings','body'])assert.deepEqual(after[category],before[category],'Saving energy must preserve '+category);
      const saved=await disk(page);await page.reload();await page.locator('#energyActive').waitFor({state:'visible'});
      assert.equal(await page.locator('#energyActive').inputValue(),'777');assert.equal(await disk(page),saved);
      await page.locator('#btnEnergyImport').click();await page.locator('#healthImportPanel').waitFor({state:'visible'});
      const payload={name:'synthetic-energy.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(energyFile))};
      const importBefore=JSON.parse(await page.evaluate(()=>buildBackup()));
      const importDisk=await disk(page);
      await page.locator('#healthFile').setInputFiles(payload);
      await page.waitForFunction(()=>document.getElementById('healthPreview').textContent.includes('能量 17 天 · 2026-09-01 至 2026-09-17'));
      assert((await page.locator('#healthPreview').textContent()).includes('将更新 17 项日记录'));
      assert.equal(await disk(page),importDisk,'Choosing and checking an energy file must not save anything');
      const importButton=await page.locator('#btnApplyHealth').evaluate(el=>({text:el.textContent,color:getComputedStyle(el).color,fill:getComputedStyle(el).webkitTextFillColor,opacity:getComputedStyle(el).opacity}));
      assert.equal(importButton.text,'确认导入');assert.equal(importButton.color,'rgb(255, 255, 255)');
      assert.equal(importButton.fill,'rgb(255, 255, 255)');assert.equal(importButton.opacity,'1');
      await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
      if(width===393)await page.screenshot({path:path.join(root,'.preview-check','energy-import-'+scheme+'.png'),animations:'disabled'});
      await page.locator('#btnApplyHealth').click();await page.locator('#alert.on').waitFor();
      await page.locator('#alertBtns button').filter({hasText:'取消'}).click();
      assert.equal(await disk(page),importDisk,'Cancelling the 17-day import must preserve all stored records');
      await page.locator('#btnApplyHealth').click();await page.locator('#alert.on').waitFor();
      await page.locator('#alertBtns button').filter({hasText:'导入并更新所列记录'}).click();
      await page.waitForFunction(()=>document.getElementById('healthPreview').textContent.startsWith('导入成功'));
      const imported=JSON.parse(await page.evaluate(()=>buildBackup()));
      for(const category of ['entries','weight','weightMeta','training','sleep','settings','body'])assert.deepEqual(imported[category],importBefore[category],'Energy import must preserve '+category);
      for(const [date,value] of Object.entries(importBefore.burn))if(!energyDates.includes(date))assert.deepEqual(imported.burn[date],value,'Energy import must preserve dates outside the file');
      for(let i=0;i<17;i++){
        assert.equal(imported.burn[energyDates[i]].active,499.5+i);assert.equal(imported.burn[energyDates[i]].basal,1399.5+i);
      }
      const importedDisk=await disk(page);await page.reload();await page.locator('#healthImportPanel').waitFor({state:'visible'});
      assert.equal(await disk(page),importedDisk,'Imported energy must survive an offline reload');
      await page.locator('#healthFile').setInputFiles(payload);
      await page.waitForFunction(()=>document.getElementById('healthPreview').textContent.includes('跳过 17 项'));
      await page.locator('#btnApplyHealth').click();
      assert.equal(await page.locator('#alert.on').count(),0,'An identical export must not ask to overwrite records');
      assert.equal(await disk(page),importedDisk,'Repeat import must not add energy or write storage');
      await page.goto(url+'/docs/energy-single-day-guide.html');
      await page.getByRole('heading',{name:'选择日期导出单日能量',exact:true}).waitFor();
      assert(await page.evaluate(()=>Math.max(document.body.scrollWidth,document.documentElement.scrollWidth)<=innerWidth+1),'Single-day guide must fit the viewport and remain available offline');
      if(width===393 && scheme==='light')await page.screenshot({path:path.join(root,'.preview-check','energy-single-day-guide.png'),animations:'disabled'});
      assert.deepEqual(errors,[]);
      console.log(`PASS production ${width}x${height} ${scheme}: ${upgrade?'old-to-new upgrade, ':''}zero-fill lens, routes, unchanged records, offline assets, durable save and 17-day energy import/cancel/repeat`);
      await context.close();
    }
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});

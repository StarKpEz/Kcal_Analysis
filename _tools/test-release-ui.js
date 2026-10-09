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
      assert.deepEqual(errors,[]);
      console.log(`PASS production ${width}x${height} ${scheme}: ${upgrade?'old-to-new upgrade, ':''}zero-fill lens, routes, unchanged records, offline assets and durable save`);
      await context.close();
    }
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});

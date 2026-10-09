// Run with Node and Playwright available on NODE_PATH. Uses a fresh browser context.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const root = path.resolve(__dirname,'..');
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
const original = ['index.html','sw.js'].map(digest);
require('./build-design-preview');
assert.deepEqual(['index.html','sw.js'].map(digest),original,'Builder must not change production');
const html = fs.readFileSync(path.join(root,'preview/app.html'),'utf8');
assert(!/navigator\.serviceWorker|localStorage|sessionStorage|rel="manifest"/.test(html),'Preview must not use production persistence');
const host = fs.readFileSync(path.join(root,'preview/index.html'),'utf8');
assert(host.includes('sandbox="allow-scripts allow-downloads"'));
const server = http.createServer((req,res)=>{
  const pathname = new URL(req.url,'http://localhost').pathname;
  const file = path.resolve(root,'.'+(pathname==='/'?'/index.html':pathname));
  if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return;}
  const mime = {'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.png':'image/png'};
  fs.readFile(file,(error,body)=>{if(error){res.writeHead(404).end();return}res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'text/plain'}).end(body)});
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url = 'http://127.0.0.1:'+server.address().port;
  const browser = await chromium.launch({channel:'chrome',headless:true});
  fs.mkdirSync(path.join(root,'.preview-check'),{recursive:true});
  try {
    for (const [width,height,scheme] of [[393,852,'light'],[320,740,'light'],[375,812,'light'],[852,393,'light'],[393,852,'dark']]) {
      const context = await browser.newContext({viewport:{width,height},colorScheme:scheme,timezoneId:'Asia/Shanghai',deviceScaleFactor:2});
      const page = await context.newPage();
      const errors=[];page.on('pageerror',error=>{errors.push(error.message);console.error('PAGE ERROR',error.message)});
      // Artificial sentinel, never real records. This tests same-site storage isolation.
      await page.goto(url+'/preview/index.html');
      await page.evaluate(()=>localStorage.setItem('kcal.data.v5','TEST-PRODUCTION-SENTINEL'));
      const frame = page.frameLocator('#appPreview');
      await frame.locator('#healthActive').waitFor();
      await page.waitForFunction(()=>document.getElementById('appPreview').contentWindow!=null);
      await assert.doesNotReject(()=>frame.locator('#healthActive').getByText('480',{exact:true}).waitFor());
      assert.equal(await frame.locator('.storage-error:visible').count(),0,'Demo snapshot must validate');
      const child = page.frames().find(f=>f.url().includes('/preview/app.html'));
      const storageDenied = await child.evaluate(()=>{try{window.localStorage.getItem('kcal.data.v5');return false}catch{return true}});
      assert(storageDenied,'Sandbox must block real origin storage');
      for(const [route,selector] of [['health','#healthPage'],['diet','#dietPage'],['weight','#weightBox'],['training','#trainingPanel'],['sleep','#sleepPanel'],['settings','#dlg'],['import','#healthImportPanel']]){
        await page.locator('#page').selectOption(route);
        await frame.locator(selector).waitFor({state:'visible'});
        const overflow = await child.evaluate(()=>Math.max(document.documentElement.scrollWidth,document.body.scrollWidth)-innerWidth);
        assert(overflow<=1,`${width} ${scheme} ${route}: horizontal overflow ${overflow}`);
        if(width===393 && scheme==='light' && ['health','diet','weight','sleep','settings'].includes(route)){
          await frame.locator(selector).screenshot({path:path.join(root,'.preview-check',route+'.png')});
        }
      }
      await page.locator('#page').selectOption('energy');
      await frame.locator('#energyActive').fill('777');
      await frame.locator('#btnSaveEnergy').click();
      assert.equal(await child.evaluate(()=>JSON.parse(previewStorage.getItem('kcal.data.v5')).burn[todayKey()].active),777);
      assert.equal(await page.evaluate(()=>localStorage.getItem('kcal.data.v5')),'TEST-PRODUCTION-SENTINEL','Editing demo must not change formal data');
      await page.locator('#currentStyle').click();
      await child.waitForFunction(()=>document.getElementById('designTheme').disabled);
      await page.locator('#newStyle').click();
      await child.waitForFunction(()=>!document.getElementById('designTheme').disabled);
      if(width===393 && scheme==='light'){
        await page.locator('#page').selectOption('weight');
        await frame.locator('.weight-scrub').focus();
        const before = await frame.locator('.weight-scrub').inputValue();
        await page.keyboard.press('ArrowLeft');
        assert.notEqual(await frame.locator('.weight-scrub').inputValue(),before,'Weight inspection must support the keyboard');
        for(const [route,selector] of [['health','#healthPage'],['sleep','#sleepPanel'],['settings','#dlg']]){
          await page.locator('#page').selectOption(route);
          await frame.locator(selector).waitFor({state:'visible'});
          // Explicit 130% text-size simulation, not a claim about iOS Dynamic Type.
          await child.evaluate(()=>{
            const elements=[...document.querySelectorAll('body *')].filter(el=>el.getBoundingClientRect().width>0 && !el.closest('svg'));
            const styles=elements.map(el=>({el,size:parseFloat(getComputedStyle(el).fontSize),height:getComputedStyle(el).lineHeight}));
            for(const {el,size,height} of styles){el.style.fontSize=size*1.3+'px';if(height!=='normal')el.style.lineHeight=parseFloat(height)*1.3+'px'}
          });
          const overflow=await child.evaluate(()=>Math.max(document.documentElement.scrollWidth,document.body.scrollWidth)-innerWidth);
          assert(overflow<=1,`${route}: 130% text horizontal overflow ${overflow}`);
          await child.evaluate(()=>{for(const el of document.querySelectorAll('body *')){el.style.removeProperty('font-size');el.style.removeProperty('line-height')}});
        }
        await page.screenshot({path:path.join(root,'.preview-check','review-shell.png')});
        console.log('PASS keyboard weight inspection and 130% text simulation');
      }
      await page.locator('#reset').click();
      await frame.locator('#healthActive').getByText('480',{exact:true}).waitFor();
      assert.equal(await page.evaluate(()=>localStorage.getItem('kcal.data.v5')),'TEST-PRODUCTION-SENTINEL');
      assert.deepEqual(errors,[],`${width} ${scheme}: browser errors`);
      console.log(`PASS ${width}x${height} ${scheme}: routes, style toggle, edit/reset, storage isolation`);
      await context.close();
    }
  } finally {await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1});

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
      const nav = await child.evaluate(()=>{
        const bounds = document.getElementById('primaryNav').getBoundingClientRect();
        return {width:bounds.width,left:bounds.left,right:bounds.right,bottom:innerHeight-bounds.bottom,
          viewport:innerWidth,targets:[...document.querySelectorAll('.tabbar a')].map(el=>({height:el.getBoundingClientRect().height,width:el.getBoundingClientRect().width})),
          filter:getComputedStyle(document.getElementById('primaryNav'),'::before').backdropFilter,
          supported:CSS.supports('backdrop-filter','blur(1px)')};
      });
      assert(nav.width<=288 && nav.left>=16 && nav.right<=nav.viewport-16,'Floating navigation must fit small viewports');
      assert(nav.bottom>=12 && nav.targets.every(t=>t.height>=44 && t.width>=44),'Touch targets and bottom clearance');
      if(nav.supported) assert(nav.filter.includes('blur(10px)'),'Use the lighter glass filter');
      await frame.locator('#tabGlassLens[data-selected="navHealth"]').waitFor();
      if(nav.supported){
        const lensStyle = await child.evaluate(()=>{
          const s=getComputedStyle(document.getElementById('tabGlassLens'));
          return {fill:s.backgroundColor,image:s.backgroundImage,filter:s.backdropFilter,
            borders:[s.borderTopWidth,s.borderRightWidth,s.borderBottomWidth,s.borderLeftWidth],shadow:s.boxShadow};
        });
        assert.equal(lensStyle.fill,'rgba(0, 0, 0, 0)','Selected lens must have zero background fill');
        assert.equal(lensStyle.image,'none','Selected lens must not add a gradient overlay');
        assert(lensStyle.filter.includes('brightness(') && lensStyle.filter.includes('contrast(') && !lensStyle.filter.includes('blur('),'The zero-fill oval must use subtle backdrop optics without additional blur');
        assert(lensStyle.borders.every(width=>width==='0px'),'Selected lens must not draw an inner frame');
        assert.equal(lensStyle.shadow,'none','Selected lens must not recreate a frame with edge highlights or shadows');
      }
      const noContentGlass = await child.evaluate(()=>[document.querySelector('.card'),document.querySelector('.tabbar a')].every(el=>getComputedStyle(el).backdropFilter==='none'));
      assert(noContentGlass,'Content and individual tabs must not add extra glass layers');
      await page.emulateMedia({contrast:'more'});
      assert.equal(await child.evaluate(()=>getComputedStyle(document.getElementById('primaryNav')).backdropFilter),'none','Increased contrast must use the solid fallback');
      assert.equal(await child.evaluate(()=>getComputedStyle(document.getElementById('primaryNav'),'::before').backdropFilter),'none','Increased contrast must disable the outer glass surface');
      assert.equal(await child.evaluate(()=>getComputedStyle(document.getElementById('tabGlassLens')).backdropFilter),'none','Increased contrast must disable selection optics');
      await page.emulateMedia({contrast:'no-preference'});
      await frame.locator('#navDiet').click();
      await frame.locator('#dietPage').waitFor({state:'visible'});
      assert.equal(await frame.locator('#navDiet').getAttribute('aria-current'),'page');
      assert.equal(await frame.locator('#navHealth').getAttribute('aria-current'),null);
      if(width===393 && scheme==='light'){
        await frame.locator('#tabGlassLens[data-selected="navDiet"][data-moving="true"]').waitFor();
        assert(await child.evaluate(()=>document.getElementById('tabGlassLens').getAnimations().some(a=>a.playState==='running')),'Switching must animate the sliding lens');
        await frame.locator('#navHealth').click();
        await frame.locator('#navDiet').click();
        await frame.locator('#tabGlassLens[data-selected="navDiet"][data-moving="false"]').waitFor();
        const aligned=await child.evaluate(()=>{
          const a=document.getElementById('navDiet').getBoundingClientRect(), lens=document.getElementById('tabGlassLens').getBoundingClientRect();
          return Math.abs(lens.left-a.left-4)<1;
        });
        assert(aligned,'Rapid taps must settle on the actual selected tab');
        await page.emulateMedia({reducedMotion:'reduce'});
        await frame.locator('#navHealth').click();
        await frame.locator('#tabGlassLens[data-selected="navHealth"]').waitFor();
        assert.equal(await child.evaluate(()=>document.getElementById('tabGlassLens').getAnimations().filter(a=>a.playState==='running').length),0,'Reduced motion must suppress elastic animation');
        await page.emulateMedia({reducedMotion:'no-preference'});
        console.log('PASS sliding lens, rapid switching, and reduced-motion feedback');
      }
      await frame.locator('#navHealth').click();
      await frame.locator('#healthPage').waitFor({state:'visible'});
      assert.equal(await frame.locator('#navHealth').getAttribute('aria-current'),'page');
      if(width===393){
        // Colorful fixture proves actual backdrop color transmission; not product content.
        await child.evaluate(()=>{
          const nav=document.getElementById('primaryNav').getBoundingClientRect();
          const sample=document.createElement('div');sample.id='glass-color-fixture';
          sample.style.cssText='position:fixed;z-index:84;pointer-events:none;left:'+nav.left+'px;top:'+(nav.top-30)+'px;width:'+nav.width+'px;height:'+(nav.height+60)+'px;background:linear-gradient(90deg,#22c55e,#06b6d4 50%,#8b5cf6);border-radius:16px';
          document.body.append(sample);
        });
        const visibleLens=await frame.locator('#primaryNav').screenshot({path:path.join(root,'.preview-check','glass-transmission-'+scheme+'.png'),animations:'disabled'});
        await child.evaluate(()=>document.getElementById('tabGlassLens').style.visibility='hidden');
        const hiddenLens=await frame.locator('#primaryNav').screenshot({animations:'disabled'});
        await child.evaluate(()=>document.getElementById('tabGlassLens').style.removeProperty('visibility'));
        assert(!visibleLens.equals(hiddenLens),'The transparent oval must still affect the rendered backdrop instead of disappearing');
        await child.evaluate(()=>document.getElementById('glass-color-fixture').remove());
      }
      await child.evaluate(()=>window.scrollTo(0,document.documentElement.scrollHeight));
      const importClear = await child.evaluate(()=>document.getElementById('btnHealthImport').getBoundingClientRect().bottom<=document.getElementById('primaryNav').getBoundingClientRect().top);
      assert(importClear,'Last health action must scroll above the floating navigation');
      if(width===393){
        await frame.locator('#primaryNav').screenshot({path:path.join(root,'.preview-check','floating-nav-'+scheme+'.png'),animations:'disabled'});
        await page.screenshot({path:path.join(root,'.preview-check','floating-health-'+scheme+'.png'),animations:'disabled'});
        // Scroll real demo content under the capsule to inspect the glass surface.
        await page.locator('#page').selectOption('diet');
        await frame.locator('#dietPage').waitFor({state:'visible'});
        await frame.locator('#tabGlassLens[data-selected="navDiet"][data-moving="false"]').waitFor();
        await child.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
        await child.evaluate(()=>window.scrollTo(0,Math.max(0,document.documentElement.scrollHeight-innerHeight-100)));
        await page.screenshot({path:path.join(root,'.preview-check','glass-over-content-'+scheme+'.png'),animations:'disabled'});
        await page.locator('#page').selectOption('health');
      }
      for(const [route,selector] of [['health','#healthPage'],['diet','#dietPage'],['weight','#weightBox'],['training','#trainingPanel'],['sleep','#sleepPanel'],['settings','#dlg'],['import','#healthImportPanel']]){
        await page.locator('#page').selectOption(route);
        await frame.locator(selector).waitFor({state:'visible'});
        const overflow = await child.evaluate(()=>Math.max(document.documentElement.scrollWidth,document.body.scrollWidth)-innerWidth);
        assert(overflow<=1,`${width} ${scheme} ${route}: horizontal overflow ${overflow}`);
        if(route==='weight'){
          await child.evaluate(()=>{const panel=document.getElementById('burn');panel.scrollTop=panel.scrollHeight});
          assert(await child.evaluate(()=>document.getElementById('btnSaveWeight').getBoundingClientRect().bottom<=document.getElementById('primaryNav').getBoundingClientRect().top),'Weight save must scroll above navigation');
          await frame.locator('#weightSection').scrollIntoViewIfNeeded();
        }
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

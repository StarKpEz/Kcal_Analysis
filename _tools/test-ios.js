// Native bridge integration against the complete generated app, using fictional data only.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {chromium}=require('playwright');
const {mergeNativeHealth}=require('../native-ios/bridge/native-health');
const root=path.resolve(__dirname,'..'),native=path.join(root,'native-ios','Web');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
const prod=['index.html','app.css','navigation.js','sw.js'],before=prod.map(hash);
require('./build-ios');assert.deepEqual(prod.map(hash),before);
const html=fs.readFileSync(path.join(native,'index.html'),'utf8');
assert(!/navigator\.serviceWorker|\blocalStorage\b|new FileReader|createObjectURL/.test(html));
const fixture=fs.readFileSync(path.join(root,'native-ios','fixtures','synthetic-backup-v7.json'),'utf8');
const fixtureData=JSON.parse(fixture);
const server=http.createServer((req,res)=>{
  const file=path.resolve(native,'.'+decodeURIComponent(new URL(req.url,'http://localhost').pathname));
  if(!file.startsWith(native+path.sep)){res.writeHead(403).end();return;}
  fs.readFile(file,(err,data)=>{if(err){res.writeHead(404).end();return;}const type={'.html':'text/html','.js':'application/javascript','.css':'text/css','.json':'application/json'}[path.extname(file)]||'text/plain';res.writeHead(200,{'Content-Type':type+'; charset=utf-8'}).end(data);});
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const browser=await chromium.launch({channel:'chrome',headless:true});
  try{
    for(const [width,height,scheme] of [[393,852,'light'],[320,740,'light'],[393,852,'dark']]){
      const context=await browser.newContext({viewport:{width,height},colorScheme:scheme,timezoneId:'Asia/Shanghai'});
      const page=await context.newPage(),errors=[];page.setDefaultTimeout(10000);page.on('pageerror',e=>errors.push(e.message));
      let raw=fixture,writes=0,failWrites=false,shareCompleted=false,prefs={autoSync:false,sleepSource:''},result={daily:null,sleepSamples:null,notes:[]},failure=null;
      let nativeNavigation=false,pingFailure=false,holdAuthorization=false,authorizationReply=null,dropNavigationReply=false,nativeVisible=false;
      const calls=[];
      page.on('dialog',async dialog=>{
        assert.equal(dialog.message(),'__KCAL_STORAGE__');
        const p=JSON.parse(dialog.defaultValue());
        if(p.operation==='read')await dialog.accept(JSON.stringify({ok:true,raw}));
        else if(failWrites||p.expectedRaw!==raw)await dialog.accept(JSON.stringify({ok:false,message:'Synthetic disk/CAS failure'}));
        else{raw=p.raw;writes++;await dialog.accept('{"ok":true}');}
      });
      await page.exposeBinding('__nativeRequest',async({page},message)=>{
        calls.push(message);
        if(message.method==='synthetic.noResponse')return;
        let value;
        if(message.method==='bridge.ping')value={protocolVersion:2,appVersion:'1.0.1',buildNumber:'2',healthAvailable:true,nativeNavigation};
        else if(message.method==='nav.state'){nativeVisible=message.params.visible;if(dropNavigationReply)return;value={accepted:true};}
        else if(message.method==='nav.disable'){nativeVisible=false;value={disabled:true};}
        else if(message.method==='deepseek.open')value={opened:true,target:'app'};
        else if(message.method==='preferences.load')value=prefs;
        else if(message.method==='preferences.save')value=prefs={...prefs,...message.params};
        else if(message.method==='health.authorize')value={requestCompleted:true};
        else if(message.method==='health.sync')value=result;
        else if(message.method==='share.text')value={completed:shareCompleted};
        else if(message.method==='file.pick')value={name:'synthetic-backup.json',text:fixture};
        else if(message.method==='clipboard.read')value={text:'synthetic clipboard'};
        else value={};
        const requestFailure=message.method==='health.sync'?failure:message.method==='bridge.ping'&&pingFailure?'Synthetic bridge unavailable':null;
        const reply=requestFailure?{id:message.id,error:{code:'synthetic',message:requestFailure}}:{id:message.id,result:value};
        if(message.method==='health.authorize'&&holdAuthorization){authorizationReply=()=>page.evaluate(reply=>window.KcalNative.receive(reply),reply);return;}
        await page.evaluate(reply=>window.KcalNative.receive(reply),reply);
      });
      await page.addInitScript(()=>{window.webkit={messageHandlers:{kcalNative:{postMessage:message=>window.__nativeRequest(message)}}};});
      const url='http://127.0.0.1:'+server.address().port+'/index.html#/health';
      await page.goto(url);await page.locator('#btnNativeSync').waitFor();
      assert.equal(writes,0,'Opening app must not write');
      for(const route of ['diet','health','weight','energy','training','sleep','import']){
        await page.evaluate(route=>navigateApp(route),route);
        assert.equal(await page.evaluate(()=>Math.max(document.body.scrollWidth,document.documentElement.scrollWidth)-innerWidth),0,'Native layout must fit viewport');
      }
      assert.equal(raw,fixture,'Browsing all modules must preserve the complete snapshot');
      await page.evaluate(()=>navigateApp('health'));
      if(width===393&&scheme==='light'){
        assert.equal(await page.evaluate(()=>commitData({settings:{...settings,kcal:2300}})),true);
        assert.equal(JSON.parse(raw).settings.kcal,2300);
        const saved=raw;failWrites=true;
        assert.equal(await page.evaluate(()=>commitData({settings:{...settings,kcal:999}})),false);
        assert.equal(raw,saved);assert.equal(await page.evaluate(()=>settings.kcal),2300,'Failed native write must roll back memory');failWrites=false;
        raw=JSON.stringify({...JSON.parse(raw),settings:{...JSON.parse(raw).settings,kcal:2400}});
        assert.equal(await page.evaluate(()=>commitData({settings:{...settings,kcal:1800}})),false,'External native change must not be overwritten');
        await page.reload();assert.equal(await page.evaluate(()=>settings.kcal),2400,'Reopen must load the native snapshot');
        await page.evaluate(()=>navigateApp('health'));
        const beforeHealth=JSON.parse(raw);
        const day='2026-10-05',stamp=new Date(Date.now()+1500).toISOString();
        result={daily:{app:'kcal-health',version:2,exportedAt:stamp,days:[{date:day,energy:{active:650,basal:1450},training:[{id:'synthetic-walk-1',type:'室内步行',durationMinutes:30,distanceKm:2}]}]},sleepSamples:null,notes:[]};
        await page.locator('#nativeFrom').fill(day);await page.locator('#nativeThrough').fill(day);
        let writesBefore=writes;
        await page.locator('#btnNativeSync').click();await page.getByRole('button',{name:'取消',exact:true}).click();
        await page.locator('#nativeSyncStatus').getByText('已取消，没有修改记录。',{exact:true}).waitFor();
        assert.equal(writes,writesBefore,'Cancel native preview must not write');
        await page.locator('#btnNativeSync').click();await page.getByRole('button',{name:'确认更新',exact:true}).click();
        await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('已在本机保存'));
        assert.equal(writes,writesBefore+1,'All native health categories must save atomically once');
        let parsed=JSON.parse(raw);assert.equal(parsed.burn[day].active,650);assert.equal(parsed.training[day].sessions.length,1);
        assert.deepEqual(parsed.entries,beforeHealth.entries);assert.deepEqual(parsed.sleep,beforeHealth.sleep);assert.deepEqual(parsed.weight,beforeHealth.weight);
        result={daily:{app:'kcal-health',version:2,exportedAt:new Date(Date.now()+2000).toISOString(),days:[{date:day,energy:{active:700,basal:1500}}]},sleepSamples:{app:'kcal-health-samples',version:1,exportedAt:new Date().toISOString(),from:day,through:day,samples:[{kind:'sleep',value:'Unknown stage',startAt:day+'T01:00:00+08:00',endAt:day+'T02:00:00+08:00',source:'Synthetic Watch'}]},notes:[]};
        writesBefore=writes;await page.locator('#btnNativeSync').click();await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('未更新：'));
        assert.equal(writes,writesBefore,'Invalid sleep result must abort the valid energy result too');
        result={daily:null,sleepSamples:null,notes:['No readable samples']};writesBefore=writes;
        await page.locator('#btnNativeSync').click();await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('没有可更新'));
        assert.equal(writes,writesBefore,'Empty or denied reads must preserve records');
        failure='Synthetic HealthKit failure';await page.locator('#btnNativeSync').click();
        await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('Synthetic HealthKit failure'));assert.equal(writes,writesBefore);failure=null;
        await page.evaluate(()=>openSet());await page.locator('#btnBackup').click();
        await page.waitForFunction(()=>document.getElementById('toast').textContent==='已取消分享');assert.equal(writes,writesBefore,'Cancelled backup must not mark backup time');
        const exported=calls.findLast(c=>c.method==='share.text');assert.equal(JSON.parse(exported.params.text).version,7);
        assert.deepEqual(JSON.parse(exported.params.text).training,JSON.parse(raw).training,'Native full backup must include all training');
        await page.locator('#btnRestore').click();await page.getByRole('button',{name:'取消',exact:true}).click();
        assert.equal(writes,writesBefore,'Cancelling native file restoration must preserve records');
        await page.locator('#btnRestore').click();await page.getByRole('button',{name:'覆盖备份中包含的数据',exact:true}).click();
        await page.waitForFunction(()=>document.getElementById('toast').textContent.includes('已覆盖恢复'));
        assert.equal(writes,writesBefore+1,'Native file picker must restore the full snapshot atomically');
        assert.equal(JSON.parse(raw).settings.kcal,JSON.parse(fixture).settings.kcal);
        assert.deepEqual(JSON.parse(raw).training,JSON.parse(fixture).training);
        await page.reload();
        const restoredBackup=await page.evaluate(()=>JSON.parse(buildBackup()));
        for(const key of ['entries','settings','body','weight','weightMeta','burn','training','sleep','completion','meta']){
          assert.deepEqual(restoredBackup[key],fixtureData[key],'Fictional acceptance backup must round-trip '+key);
        }
        await page.evaluate(async()=>{settings.dsScheme='bad-kcal-test://';await launchDeepSeek();delete settings.dsScheme;});
        await page.evaluate(async()=>launchDeepSeek());
        assert.deepEqual(calls.filter(c=>c.method==='deepseek.open').map(c=>c.params.preferred),['bad-kcal-test://',null],'Native launcher must own app-first fallback and optional custom links');
        // Fresh launch with explicitly opted-in auto sync must protect hand-entered records.
        prefs={autoSync:true,sleepSource:''};
        const now=new Date(),today=now.toLocaleDateString('sv-SE',{timeZone:'Asia/Shanghai'});
        parsed=JSON.parse(raw);parsed.burn[today]={active:123,basal:1450,updatedAt:'2020-01-01T00:00:00Z'};raw=JSON.stringify(parsed);
        result={daily:{app:'kcal-health',version:2,exportedAt:new Date().toISOString(),days:[{date:today,energy:{active:900,basal:1500}}]},sleepSamples:null,notes:[]};
        writesBefore=writes;await page.reload();await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('包含手动记录'));
        assert.equal(writes,writesBefore);assert.equal(JSON.parse(raw).burn[today].active,123,'Automatic refresh must not overwrite manual records');
        assert.throws(()=>mergeNativeHealth({...result,sleepSamples:{from:today,through:today}},()=>({}),{from:'2026-10-01',through:'2026-10-05'}),/超出所选范围/);
        const realParse=await page.evaluate(()=>parseHealthJSON.toString());assert(realParse.includes('normalizeTrainingDay'));
        parsed=JSON.parse(raw);parsed.burn[today].source='health-json';raw=JSON.stringify(parsed);
        writesBefore=writes;await page.reload();await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('已在本机保存'));
        assert.equal(writes,writesBefore+1,'Opted-in auto sync should refresh existing health records');
        const syncCalls=calls.filter(c=>c.method==='health.sync').length;
        await page.evaluate(()=>{KcalNative.onResume();KcalNative.onResume();});
        assert.equal(calls.filter(c=>c.method==='health.sync').length,syncCalls,'Repeated foreground events should not repeat a recent sync');
        assert.equal(new Set(calls.map(c=>c.id)).size,calls.length,'Bridge request IDs must not be reused across page reloads');
        // The reported failure was a silent early return. Exercise the protected states directly.
        prefs={autoSync:false,sleepSource:''};raw=null;result={daily:null,sleepSamples:null,notes:[]};
        await page.reload();await page.evaluate(()=>navigateApp('health'));
        await page.evaluate(()=>KcalNative.ready);writesBefore=writes;
        holdAuthorization=true;authorizationReply=null;
        await page.locator('#btnNativeSync').click();
        await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('正在请求 Apple 健康授权'));
        assert.equal(await page.locator('#btnNativeSync').isDisabled(),true);
        assert.equal(typeof authorizationReply,'function');
        await authorizationReply();holdAuthorization=false;
        await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('没有可更新'));
        assert.equal(writes,writesBefore);assert.equal(raw,null,'Empty first install must not write before accepting real records');
        await page.evaluate(()=>{storageReadError=true;document.getElementById('btnNativeSync').click();});
        assert.match(await page.locator('#nativeSyncStatus').textContent(),/本地记录读取异常/);
        await page.evaluate(()=>{storageReadError=false;storageStale=true;document.getElementById('btnNativeSync').click();});
        assert.match(await page.locator('#nativeSyncStatus').textContent(),/其他操作更新/);
        pingFailure=true;await page.reload();await page.evaluate(()=>navigateApp('health'));
        await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.includes('Synthetic bridge unavailable'));
        await page.locator('#btnNativeSync').click();
        await page.waitForFunction(()=>document.getElementById('nativeSyncStatus').textContent.startsWith('未更新：'));
        assert.equal(raw,null);pingFailure=false;
        assert.equal(await page.evaluate(async()=>{try{await KcalNative.call('synthetic.noResponse',{}, {timeoutMs:20});return 'unexpected';}catch(error){return error.code;}}),'bridge_timeout');
        // A successful native handshake alone may hide HTML navigation; native taps reuse route guards.
        nativeNavigation=true;raw=fixture;await page.reload();
        await page.waitForFunction(()=>document.documentElement.classList.contains('native-navigation'));
        await page.evaluate(()=>KcalNativeNavigation.setClearance(180));
        await page.waitForFunction(()=>Math.abs(parseFloat(getComputedStyle(document.getElementById('toast')).bottom)-180)<0.1);
        assert.equal(await page.locator('#toast').evaluate(element=>getComputedStyle(element).bottom),'180px','Large native bars must lift feedback above their bounds');
        await page.evaluate(()=>KcalNativeNavigation.select('health'));
        await page.waitForFunction(()=>document.getElementById('navHealth').getAttribute('aria-current')==='page');
        await page.evaluate(()=>navigateApp('weight'));await page.evaluate(()=>KcalNativeNavigation.select('diet'));
        await page.evaluate(()=>KcalNativeNavigation.select('health'));
        assert.equal(await page.evaluate(()=>appRoute),'weight','Native health tab must restore last detail route');
        await page.evaluate(()=>openSet());
        await page.waitForFunction(()=>document.querySelector('.modal.on'));
        await page.waitForTimeout(30);
        assert.equal(calls.findLast(c=>c.method==='nav.state').params.visible,false,'Native bar must hide for editing modals');
        await page.evaluate(()=>KcalNativeNavigation.setEnabled(false));
        assert.equal(await page.locator('#primaryNav').getAttribute('aria-hidden'),null,'Native failure must restore accessible HTML navigation');
        await page.waitForTimeout(30);assert.equal(nativeVisible,false,'HTML fallback must disable an already visible native bar');
        // Native applied a new route, but its acknowledgement never arrived.
        await page.reload();await page.waitForFunction(()=>document.documentElement.classList.contains('native-navigation'));
        await page.evaluate(()=>{const call=KcalNative.call.bind(KcalNative);KcalNative.call=(method,params,options)=>call(method,params,method==='nav.state'?{timeoutMs:30}:options);});
        dropNavigationReply=true;
        await page.evaluate(()=>KcalNativeNavigation.select(document.getElementById('navHealth').hasAttribute('aria-current')?'diet':'health'));
        await page.waitForFunction(()=>!document.documentElement.classList.contains('native-navigation'));
        await page.waitForTimeout(30);assert.equal(nativeVisible,false,'Lost navigation replies must not leave both bars visible');
        dropNavigationReply=false;
        nativeNavigation=false;await page.reload();
        console.log('PASS native sync preview/cancel, all-category atomic save, disk failure rollback, CAS, backup sharing, empty/failure preservation and auto-sync conflicts');
      }
      assert.deepEqual(errors,[]);assert.equal(await page.evaluate(()=>navigator.serviceWorker.getRegistrations().then(x=>x.length)),0);
      await page.evaluate(()=>{navigateApp('health');window.scrollTo(0,0);});
      if(width===393)await page.screenshot({path:path.join(root,'.preview-check','ios-health-'+scheme+'.png')});
      await page.locator('#nativeHealth').evaluate(card=>{for(const element of card.querySelectorAll('*'))element.style.fontSize=(parseFloat(getComputedStyle(element).fontSize)*1.3)+'px';});
      assert.equal(await page.evaluate(()=>Math.max(document.body.scrollWidth,document.documentElement.scrollWidth)-innerWidth),0,'Native sync card must fit with 130% text');
      console.log(`PASS native bundle ${width}x${height} ${scheme}: all routes, no overflow, no SW and read-only startup`);
      await context.close();
    }
    assert.deepEqual(prod.map(hash),before,'Native migration must leave PWA production unchanged');
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1});

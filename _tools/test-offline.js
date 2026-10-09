/* node _tools/test-offline.js：更新完整缓存后才接管，安装失败保留旧版本。 */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'..','sw.js'),'utf8');
async function install(fail){
  const handlers = {}, events = [], cached = [];
  const ctx = vm.createContext({
    self:{addEventListener:(name,fn)=>handlers[name]=fn,skipWaiting:()=>events.push('takeover')},
    caches:{open:async()=>({addAll:async files=>{
      events.push('cache'); cached.push(...files);
      if(fail) throw Error('network unavailable');
    }})}
  });
  vm.runInContext(source,ctx);
  let pending;
  handlers.install({waitUntil:p=>pending=p});
  if(fail) await assert.rejects(pending,/network unavailable/);
  else await pending;
  assert.ok(cached.includes('./index.html'));
  assert.ok(cached.includes('./manifest.webmanifest'));
  const html = fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
  const theme = html.match(/<link id="appTheme"[^>]*href="([^"]+)"/)[1];
  const navigation = html.match(/<script src="(\.\/navigation\.js[^"]+)"/)[1];
  assert.ok(cached.includes(theme),'Approved theme must be cached before takeover');
  assert.ok(cached.includes(navigation),'Navigation feedback must be cached before takeover');
  assert.deepEqual(events,fail?['cache']:['cache','takeover']);
}
async function navigate(online){
  const handlers = {}, events = [];
  const fresh = {status:200,clone:()=>({body:'fresh'}),body:'fresh'};
  const offline = {body:'cached shell'};
  const ctx = vm.createContext({URL,
    self:{location:{origin:'https://example.test'},addEventListener:(name,fn)=>handlers[name]=fn},
    fetch:async()=>{events.push('network');if(!online)throw Error('offline');return fresh;},
    caches:{open:async()=>({put:()=>events.push('cache fresh')}),match:async key=>{
      events.push(key === './index.html'?'shell fallback':'request fallback');
      return key === './index.html'?offline:undefined;
    }}
  });
  vm.runInContext(source,ctx);
  let pending;
  handlers.fetch({request:{method:'GET',mode:'navigate',url:'https://example.test/',headers:{get:()=>''}},respondWith:p=>pending=p});
  const response = await pending;
  assert.equal(response.body,online?'fresh':'cached shell');
  assert.equal(events[0],'network');
  if(!online)assert.deepEqual(events,['network','request fallback','shell fallback']);
}
(async()=>{
  await install(false); await install(true);
  await navigate(true); await navigate(false);
  console.log('PASS: complete offline shell before takeover; failed install preserves previous worker; navigation prefers network and falls back to cached shell offline');
})().catch(err=>{console.error(err);process.exitCode=1;});

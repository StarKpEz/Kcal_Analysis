/* 导航回归：真实路由与详情控制代码，不写入或迁移记录。 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script);
const slice = (a,b) => script.slice(script.indexOf(a),script.indexOf(b,script.indexOf(a)));
function harness(hash = ''){
  const nodes = new Map(), events = new Map();
  let focus = '', position = 0;
  const node = id => {
    if (!nodes.has(id)){
      const classes = new Set(), attributes = new Map();
      nodes.set(id,{id,inert:false,hidden:false,scrollTop:0,textContent:'',
        classList:{contains:v=>classes.has(v),add:v=>classes.add(v),remove:v=>classes.delete(v),
          toggle(v,on){if(on)classes.add(v);else classes.delete(v);}},
        setAttribute:(k,v)=>attributes.set(k,v),removeAttribute:k=>attributes.delete(k),
        getAttribute:k=>attributes.get(k),addEventListener:(k,v)=>events.set(id+':'+k,v),
        focus(){focus=id;},scrollIntoView(){node('burn').scrollTop=700;}});
    }
    return nodes.get(id);
  };
  const location = {hash};
  const stack = [{hash,state:null}]; let index = 0;
  const history = {
    get state(){return stack[index].state;},
    pushState(state,_,hash){stack.splice(index+1);stack.push({hash,state});index++;location.hash=hash;},
    replaceState(state,_,hash){stack[index]={hash,state};location.hash=hash;},
    back(){if(index){location.hash=stack[--index].hash;events.get('popstate')?.();}},
    forward(){if(index+1<stack.length){location.hash=stack[++index].hash;events.get('popstate')?.();}}
  };
  const body = node('body'); body.children=['appMain','primaryNav','burn','dlg','rec','alert','impor','iosStatusStrip'].map(node);
  const window = {get scrollY(){return position;},scrollTo(x,y){position=y;},addEventListener:(k,v)=>events.set(k,v)};
  const ctx = vm.createContext({$,console,document:{body},window,location,history,
    render:()=>{},renderBurn:()=>{},closeSet:()=>node('dlg').classList.remove('on'),
    closeRec:()=>node('rec').classList.remove('on'),N:v=>Math.round(v*10)/10,todayKey:()=> '2026-10-07'});
  function $(id){return node(id);}
  const run = code => vm.runInContext(code,ctx);
  run("let editDate='2026-10-05'; const store={fixture:true}; let burnByDay={}, weight={}, body={};");
  run(slice('function renderHealth(){','function openBurn(){'));
  run(slice('/* TEST-EXTRACT-NAV-A */','/* TEST-EXTRACT-NAV-B */'));
  return {run,node,history,location,window,focus:()=>focus,
    click(id){events.get(id+':click')({button:0,preventDefault(){}});}};
}
const h = harness();
h.run('syncAppRoute({initial:true})');
assert.equal(h.location.hash,'#/diet');
h.window.scrollTo(0,420); h.click('navHealth');
assert.equal(h.node('dietPage').hidden,true);
assert.equal(h.node('healthPage').hidden,false);
assert.equal(h.node('navHealth').getAttribute('aria-current'),'page');
assert.equal(h.node('navDiet').getAttribute('aria-current'),undefined);
h.window.scrollTo(0,120); h.click('navDiet');
assert.equal(h.window.scrollY,420);
h.click('navHealth'); assert.equal(h.window.scrollY,120);
h.run("navigateApp('energy')");
assert.equal(h.node('appMain').inert,true);
assert.equal(h.node('primaryNav').inert,false);
assert.equal(h.node('burn').classList.contains('on'),true);
h.node('burn').scrollTop=300; h.click('navDiet');
assert.equal(h.node('appMain').inert,false);
h.click('navHealth');
assert.equal(h.location.hash,'#/health/energy');
assert.equal(h.node('burn').scrollTop,300);
h.run('returnToHealth()');
assert.equal(h.location.hash,'#/health');
assert.equal(h.focus(),'btnBurn');
h.history.back(); assert.equal(h.location.hash,'#/diet');
h.history.forward(); assert.equal(h.location.hash,'#/health');
h.click('btnHealthWeight');
assert.equal(h.node('burn').scrollTop,700);
assert.equal(h.focus(),'weightSection');
h.run('returnToHealth()');
assert.equal(h.focus(),'btnHealthWeight');
assert.equal(h.run('editDate'),'2026-10-05');
assert.equal(h.run('JSON.stringify(store)'),'{"fixture":true}');
h.node('alert').classList.add('on'); h.click('navDiet');
assert.equal(h.location.hash,'#/health');
assert.equal(h.node('healthPage').hidden,false);
const direct = harness('#/health/weight');
direct.run('syncAppRoute({initial:true}); returnToHealth()');
assert.equal(direct.location.hash,'#/health');
assert.equal(direct.node('appMain').inert,false);
const unknown = harness('#/unknown'); unknown.run('syncAppRoute({initial:true})');
assert.equal(unknown.location.hash,'#/diet');
// 摘要数据：零能量是有效记录，缺失与未来体重不能混入所选日期。
h.run("burnByDay={'2026-10-05':{active:0,basal:1400}};weight={'2026-10-04':71,'2026-10-06':70};renderHealth()");
assert.equal(h.node('healthActive').textContent,0);
assert.equal(h.node('healthWeightValue').textContent,71);
assert.equal(h.node('healthWeightDate').textContent,'最近记录 · 2026-10-04');
h.run("editDate='2026-10-03';body={weightKg:72};renderHealth()");
assert.equal(h.node('healthActive').textContent,'—');
assert.equal(h.node('healthWeightValue').textContent,72);
console.log('PASS: navigation, history, section/detail scroll, shared date, inert restoration and health summaries');

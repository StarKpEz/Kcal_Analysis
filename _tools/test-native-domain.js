/* Headless native command contract + parity with the unmodified PWA algorithms.
 * No browser, file storage, network, user backup or real health record is exposed to the VM. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const {buildNativeDomain} = require('./build-native-domain');
const root = path.resolve(__dirname, '..');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const pwaFiles = ['index.html', 'app.css', 'navigation.js', 'sw.js', 'manifest.webmanifest'];
const hashes = pwaFiles.map(name => hash(fs.readFileSync(path.join(root, name))));
const {code, manifest} = buildNativeDomain();
const fixedInstant = Date.parse('2026-11-02T12:00:00Z');
class Clock extends Date {
  constructor(...args) { super(...(args.length ? args : [fixedInstant])); }
  static now() { return fixedInstant; }
}
const native = vm.createContext({Date: Clock}, {codeGeneration:{strings:false,wasm:false}});
vm.runInContext(code, native, {timeout:1000});
const execute = native.NativeDomainEngine.execute;
const clone = value => JSON.parse(JSON.stringify(value));
const request = (snapshot, operation, payload = {}, mutation = false) =>
  JSON.parse(execute(JSON.stringify({snapshot, operation, payload, mutation})));
function call(snapshot, operation, payload = {}, mutation = false) {
  const response = request(snapshot, operation, payload, mutation);
  assert.equal(response.ok, true, operation + ': ' + response.error);
  return response.value;
}
const empty = () => call(null, 'initialize').snapshot;
const query = (snapshot, operation, payload) => call(snapshot, operation, payload);
const mutate = (snapshot, operation, payload) => call(snapshot, operation, payload, true);
function rejected(snapshot, operation, payload, expression, mutation = true) {
  const previous = JSON.stringify(snapshot), response = request(snapshot, operation, payload, mutation);
  assert.equal(response.ok, false, 'Expected rejected ' + operation);
  assert.match(response.error, expression);
  assert.equal(JSON.stringify(snapshot), previous, 'Caller snapshot must never be mutated');
  assert.equal(response.value, undefined, 'Failure must never return a candidate snapshot');
}

// Independent oracle: run the exact PWA source slices without the native adapter.
const source = fs.readFileSync(path.join(root, 'index.html'), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const sections = manifest.sections.map(({start,end,sha256}) => {
  const from=source.indexOf(start), text=source.slice(from,source.indexOf(end,from+start.length));
  assert.equal(hash(text), sha256); return text;
});
const oracle = vm.createContext({Date:Clock});
vm.runInContext('const N = v => Number.isFinite(v) ? Math.round(v*10)/10 : 0;\n'+sections.join('\n'), oracle);
function production(snapshot, expression, payload = {}) {
  oracle.inputSnapshot = clone(snapshot); oracle.input = clone(payload);
  return JSON.parse(vm.runInContext('applySnapshot(inputSnapshot); JSON.stringify('+expression+')', oracle));
}
let passed = 0;
function test(name, body) { body(); passed++; console.log('PASS ' + name); }
const day = '2026-10-05', other = '2026-10-04';
const item = {name:'虚构米饭',grams:200,kcal:232,protein:5,fat:0.6,carbs:51};
const foodText = '虚构米饭 | 200g | 232kcal | 蛋白质5g | 脂肪0.6g | 碳水51g\n合计 | - | 232kcal | 蛋白质5g | 脂肪0.6g | 碳水51g';
const health = JSON.parse(fs.readFileSync(path.join(root, 'docs/health-import-example.json'), 'utf8'));
const samples = JSON.parse(fs.readFileSync(path.join(root, 'docs/health-samples-example.json'), 'utf8'));

test('build is reproducible, DOM-free, and leaves the in-use PWA byte-identical', () => {
  assert.equal(hash(code), manifest.domainSHA256);
  assert.equal(buildNativeDomain().code, code);
  pwaFiles.forEach((name, i) => assert.equal(hash(fs.readFileSync(path.join(root,name))),hashes[i]));
  assert.equal(vm.runInContext('typeof document + "/" + typeof fetch + "/" + typeof localStorage',native),'undefined/undefined/undefined');
});
test('empty launch, malformed commands and invalid snapshot fail closed', () => {
  assert.equal(empty().version, 7); assert.deepEqual(empty().entries, {});
  assert.equal(JSON.parse(execute('{')).ok, false);
  rejected({}, 'summary', {date:day}, /本地快照/, false);
  rejected({...empty(),version:8}, 'summary', {date:day}, /本地快照/, false);
  rejected(empty(), 'unknown', {}, /不支持/, false);
  rejected(empty(), 'summary', {date:'2026-02-30'}, /日期/, false);
  rejected(empty(), 'range', {from:day,through:other}, /范围/, false);
});
test('food parsing and prompt keep existing Chinese/JSON rules and ignore totals', () => {
  for (const text of [foodText, JSON.stringify([item]), '食物名称：虚构炒饭\n重量：400克\n热量：720kcal\n蛋白质：24g\n脂肪：20g\n碳水：100g']) {
    const parsed=query(empty(),'parseFood',{text});
    assert.deepEqual(parsed.items,production(empty(),'parseText(input.text)',{text}));
    assert.equal(parsed.items.length,1);
  }
  rejected(empty(),'parseFood',{text:'[{"name":"bad","kcal":-1}]'},/数值/,false);
  const prompt=query(empty(),'foodPrompt',{meal:'breakfast',description:'虚构测试餐'}).text;
  assert.match(prompt,/早餐/);assert.match(prompt,/虚构测试餐/);
  assert.equal(query(empty(),'parseFood',{text:prompt}).items.length,2);
});
test('food CRUD, gram scaling, meal move and failed edit preserve snapshot isolation', () => {
  let state=empty(); const original=clone(state);
  state=mutate(state,'addFood',{date:day,meal:'lunch',items:[item]}).snapshot;
  assert.deepEqual(original,empty());
  state=mutate(state,'scaleFood',{date:day,meal:'lunch',index:0,grams:100}).snapshot;
  assert.equal(state.entries[day].lunch[0].kcal,116);
  assert.equal(state.entries[day].lunch[0].carbs,25.5);
  state=mutate(state,'moveFood',{date:day,fromMeal:'lunch',index:0,toMeal:'dinner'}).snapshot;
  assert.equal(state.entries[day].dinner.length,1); assert.equal(state.entries[day].lunch,undefined);
  state=mutate(state,'editFood',{date:day,meal:'dinner',index:0,item:{name:'改名虚构食物'}}).snapshot;
  rejected(state,'editFood',{date:day,meal:'dinner',index:0,item:{kcal:-1}},/数值/);
  rejected(state,'deleteFood',{date:day,meal:'dinner',index:5},/已变更/);
  rejected(state,'scaleFood',{date:day,meal:'dinner',index:0,grams:-1},/重量/);
  const sum=query(state,'summary',{date:day});assert.equal(sum.totals.kcal,116);
  assert.deepEqual(sum.totals,production(state,'sum(store[input.date].dinner)',{date:day}));
  state=mutate(state,'deleteFood',{date:day,meal:'dinner',index:0}).snapshot;
  assert.equal(state.entries[day],undefined);
});
test('completion invalidation is category-local and clearing diet preserves health/history', () => {
  let state=mutate(empty(),'addFood',{date:day,meal:'lunch',items:[item]}).snapshot;
  state=mutate(state,'saveEnergy',{date:day,active:600,basal:1400}).snapshot;
  state=mutate(state,'markCompletion',{date:day,value:{food:true,energy:true}}).snapshot;
  state=mutate(state,'saveWeight',{date:other,value:70}).snapshot;
  assert.deepEqual(state.completion[day],{food:true,energy:true});
  state=mutate(state,'clearDiet',{date:day}).snapshot;
  assert.deepEqual(state.completion[day],{food:false,energy:true});assert.equal(state.burn[day].active,600);
  assert.equal(state.weight[other],70);
  state=mutate(state,'clearCategory',{date:day,category:'burn'}).snapshot;
  assert.equal(state.completion[day].energy,false);
  assert.equal(mutate(state,'clearCategory',{date:day,category:'burn'}).changed,false);
});
test('stale food indices cannot silently edit, scale, move or delete another entry', () => {
  const second={...item,name:'虚构第二项'}, expectedItem={...item,annotation:{b:2,a:1}};
  let state=mutate(empty(),'addFood',{date:day,meal:'lunch',items:[expectedItem,second]}).snapshot;
  // JSON object ordering can change when crossing Swift/Foundation.
  const reordered={annotation:{a:1,b:2},...item};
  assert.equal(mutate(state,'editFood',{date:day,meal:'lunch',index:0,expectedItem:reordered,item:{name:item.name}}).changed,false);
  state=mutate(state,'deleteFood',{date:day,meal:'lunch',index:0,expectedItem}).snapshot;
  for(const operation of ['editFood','deleteFood','scaleFood','moveFood']) {
    rejected(state,operation,{date:day,meal:'lunch',index:0,expectedItem,item:{name:'误改'},grams:100,toMeal:'snack'},/其他操作修改/);
  }
  assert.equal(state.entries[day].lunch[0].name,second.name);
});
test('energy preserves missing/explicit zero/today distinctions and does not add workout calories', () => {
  let state=mutate(empty(),'addFood',{date:day,meal:'lunch',items:[item]}).snapshot;
  const missing=query(state,'energy',{date:day});assert.equal(missing.hasBurn,false);
  state=mutate(state,'saveEnergy',{date:day,active:600,basal:1400}).snapshot;
  state=mutate(state,'saveTraining',{date:day,input:{type:'虚构跑步',durationMinutes:45,energyKcal:500}}).snapshot;
  const result=query(state,'energy',{date:day});assert.equal(result.burn,2000);assert.equal(result.tef,0);
  const expected=production(state,'energyBalance(input.date,body,weight,burnByDay)',{date:day});
  for(const [key,value] of Object.entries(expected))assert.deepEqual(result[key],value,key);
  rejected(state,'saveEnergy',{date:day,active:0},/同时填写/);
  state=mutate(state,'saveEnergy',{date:day,active:0,basal:0}).snapshot;
  assert.equal(query(state,'energy',{date:day}).hasBurn,true);
  const today=production(state,'todayKey()');
  state=mutate(state,'saveEnergy',{date:today,active:600,basal:1400}).snapshot;
  assert.equal(query(state,'energy',{date:today}).hasDayEnergy,false);
});
test('formula uses nearest past weight and every weight window retains all stored dates', () => {
  let state=mutate(empty(),'patch',{patch:{body:{sex:'male',birthYear:1996,heightCm:175,weightKg:70,activity:1.375},weight:{'2026-09-01':69,'2026-10-04':68,'2026-10-06':90,'2026-11-03':100}}}).snapshot;
  assert.equal(query(state,'energy',{date:day}).bmr,1628.75);
  state=mutate(state,'saveEnergy',{date:day,active:5000,basal:2000}).snapshot;
  assert.deepEqual(query(state,'energy',{date:day}).target,production(state,'suggestTarget(calcTDEE(energyBalance(input.date,body,weight,burnByDay).bmr,body.activity),body.sex)',{date:day}));
  for(const mode of ['week','month','year','all']) {
    const payload={mode,anchor:day,asOf:day};
    assert.deepEqual(query(state,'weightWindow',payload),production(state,'weightWindow(weight,input.mode,input.anchor,input.asOf)',payload));
  }
  assert.equal(Object.keys(state.weight).length,4);
  assert.equal(query(state,'weightWindow',{mode:'month',anchor:day,asOf:day}).records.length,1);
});
test('reverse TDEE matches PWA least-squares trend and refuses sparse intake', () => {
  const state=empty();
  for(let i=1;i<=15;i++)state.entries['2026-10-'+String(i).padStart(2,'0')]={lunch:[{name:'虚构日记录',kcal:2000}]};
  state.weight={'2026-10-01':70,'2026-10-06':69.5,'2026-10-11':69,'2026-10-16':68.5};
  const payload={asOf:'2026-10-16'}, trend=query(state,'reverseTDEE',payload);
  assert.equal(trend.ok,true);assert.ok(Math.abs(trend.value-2770)<1e-6);
  assert.deepEqual(trend,production(state,'reverseTDEE(store,weight,input)',payload));
  delete state.entries['2026-10-07'];
  assert.equal(query(state,'reverseTDEE',payload).reason,'fewLogs');
});
test('chat import has preview, deterministic duplicate handling and no history truncation', () => {
  const text='2026-10-05 午餐：'+foodText.split('\n')[0]+'\n2026-10-06\n早餐\n'+foodText.split('\n')[0];
  const parsed=query(empty(),'parseChat',{text});assert.equal(parsed.days,2);assert.equal(parsed.items,2);
  assert.deepEqual(parsed.entries,production(empty(),'normalizeStore(parseChatDoc(input.text))',{text}));
  let state=mutate(empty(),'importChat',{text,mode:'merge'}).snapshot;
  assert.equal(mutate(state,'importChat',{text,mode:'merge'}).changed,false);
  state=mutate(state,'addFood',{date:'2001-01-01',meal:'breakfast',items:[item]}).snapshot;
  assert.equal(query(state,'range',{from:day,through:'2026-10-06'}).days.length,2);
  assert.equal(state.entries['2001-01-01'].breakfast.length,1);
  rejected(state,'importChat',{text:'没有日期的文字',mode:'merge'},/没解析出/);
});
test('backup v1-v7 restore retains unsupported-era categories and original multiplicity', () => {
  let state=mutate(empty(),'saveWeight',{date:other,value:70}).snapshot;
  state=mutate(state,'saveEnergy',{date:day,active:500,basal:1400}).snapshot;
  for(const version of [1,2,3,4]) {
    const backup={version,entries:{[day]:[item,item]}};
    const restored=mutate(state,'restore',{text:JSON.stringify(backup),mode:'replace'}).snapshot;
    assert.equal(restored.entries[day].__legacy.length,2);assert.deepEqual(restored.weight,state.weight);assert.deepEqual(restored.burn,state.burn);
    assert.equal(mutate(restored,'restore',{text:JSON.stringify(backup),mode:'merge'}).changed,false);
  }
  for(const version of [5,6,7]) {
    const backup={...state,version};
    if(version===5){delete backup.training;delete backup.sleep;}if(version<7)delete backup.weightMeta;
    const text=JSON.stringify(backup),preview=query(state,'previewRestore',{text});
    assert.equal(preview.version,version);
    const restored=mutate(state,'restore',{text,mode:'replace'}).snapshot;
    assert.deepEqual(restored.weight,state.weight);
  }
  rejected(state,'restore',{text:'{"app":"kcal","version":7}',mode:'replace'},/缺少/);
  rejected(state,'restore',{text:'{"entries":{}}',mode:'merge',recovering:true},/完整备份/);
  const backup=JSON.parse(query(state,'exportBackup').text);delete backup.exportedAt;
  assert.deepEqual(backup,state);
});
test('health preview and commit use PWA validators/plans and preserve untouched categories', () => {
  let state=mutate(empty(),'addFood',{date:other,meal:'snack',items:[item]}).snapshot;
  const payload={text:JSON.stringify(health)}, preview=query(state,'previewHealth',payload);
  const expected=production(state,'healthImportPlan(parseHealthJSON(input.text))',payload);
  for(const key of ['updates','skipped','conflicts','details','summary'])assert.deepEqual(preview[key],expected[key]);
  assert.equal(preview.updates,4);assert.deepEqual(state.burn,{});
  state=mutate(state,'importHealth',payload).snapshot;
  assert.equal(state.sleep[day].asleepMinutes,420);assert.equal(state.training[day].sessions[0].energyKcal,350);
  assert.equal(query(state,'energy',{date:day}).burn,2000);assert.equal(state.entries[other].snack.length,1);
  const retry=mutate(state,'importHealth',payload);assert.equal(retry.updates,0);assert.equal(retry.skipped,4);assert.equal(retry.changed,false);
  const invalid=clone(health);invalid.days[0].energy.basal=null;
  rejected(state,'importHealth',{text:JSON.stringify(invalid)},/能量/);
});
test('sample import excludes awake/inBed and uses source/timezone/dedup rules', () => {
  const payload={text:JSON.stringify(samples)}, snapshot=mutate(empty(),'importHealth',payload).snapshot;
  const expected=production(empty(),'parseHealthJSON(input.text)',payload);
  assert.deepEqual(snapshot.sleep,expected.sleep);assert.equal(snapshot.sleep[day].asleepMinutes,420);
  assert.deepEqual(snapshot.weight,expected.weight);assert.equal(snapshot.weight[day],71.8);
  const duplicated=clone(samples);duplicated.samples.push(clone(duplicated.samples[0]));
  assert.equal(mutate(empty(),'importHealth',{text:JSON.stringify(duplicated)}).snapshot.weight[day],71.8);
});
test('native HealthKit batch preserves no-data dates and rejects mismatched/overlapping responses', () => {
  const state=mutate(empty(),'saveEnergy',{date:other,active:1,basal:2}).snapshot;
  const none={nativeResult:{daily:null,sleepSamples:null,notes:['没有可读数据']},from:other,through:day};
  const preview=query(state,'previewHealth',none);assert.equal(preview.updates,0);assert.match(preview.notes.join(''),/没有可读/);
  assert.equal(mutate(state,'importHealth',none).changed,false);
  const payload={nativeResult:{daily:health,sleepSamples:null,notes:['虚构 HealthKit 返回']},from:other,through:day};
  assert.equal(query(state,'previewHealth',payload).updates,4);
  assert.equal(mutate(state,'importHealth',payload).snapshot.burn[other].active,1);
  rejected(state,'importHealth',{...payload,through:other},/超出/);
  rejected(state,'importHealth',{...payload,from:day,through:other},/范围/);
  rejected(state,'importHealth',{...payload,from:'bad'},/日期/);
  rejected(state,'importHealth',{documents:[health,health]},/重复/);
});
test('health manual conflicts require explicit confirmation; stale plans are recomputed', () => {
  const state=empty();state.burn[day]={active:1,basal:2,updatedAt:'2026-10-01T00:00:00Z'};
  const payload={text:JSON.stringify(health)};
  assert.equal(query(state,'previewHealth',payload).conflicts,1);
  rejected(state,'importHealth',{...payload,automatic:true},/手动记录/);
  const recent=mutate(state,'saveEnergy',{date:day,active:999,basal:1400}).snapshot;
  const saved=mutate(recent,'importHealth',payload);
  assert.equal(saved.snapshot.burn[day].active,999);assert.equal(saved.skipped,1);
});
test('manual health CRUD validates times, tracks sources and clears weight metadata', () => {
  let state=mutate(empty(),'saveWeight',{date:day,value:72.2}).snapshot;
  assert.equal(state.weightMeta[day].source,'manual');
  state=mutate(state,'saveTraining',{date:day,input:{type:'虚构步行',durationMinutes:20,distanceKm:1}}).snapshot;
  const id=state.training[day].sessions[0].id;
  state=mutate(state,'saveTraining',{date:day,id,input:{type:'虚构步行',durationMinutes:30}}).snapshot;
  assert.equal(state.training[day].sessions.length,1);assert.equal(state.training[day].sessions[0].durationMinutes,30);
  rejected(state,'saveTraining',{date:day,id:'stale',input:{type:'虚构',durationMinutes:1}},/变更/);
  state=mutate(state,'deleteTraining',{date:day,id}).snapshot;assert.deepEqual(state.training[day].sessions,[]);
  state=mutate(state,'saveSleep',{date:day,input:{asleepMinutes:400}}).snapshot;
  assert.equal(state.sleep[day].source,'manual');
  rejected(state,'saveSleep',{date:day,input:{asleepMinutes:1500}},/睡眠/);
  rejected(state,'saveSleep',{date:day,input:{asleepMinutes:10,startAt:'2026-10-05T01:00:00Z',endAt:'2026-10-06T02:00:00Z'}},/醒来/);
  state=mutate(state,'clearCategory',{date:day,category:'weight'}).snapshot;
  assert.equal(state.weight[day],undefined);assert.equal(state.weightMeta[day],undefined);
  rejected(state,'saveWeight',{date:day,value:401},/体重/);
});
console.log(`Native domain: ${passed} contract/parity scenarios passed; PWA files unchanged.`);

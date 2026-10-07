const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {harness}=require('./test-energy');
const html=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const slice=(a,b)=>script.slice(script.indexOf(a),script.indexOf(b,script.indexOf(a)));
function healthHarness(seed){
  const h=harness(seed);
  h.run("function resetTrainingForm(){trainingEditingId='';}");
  h.run(slice('function saveTrainingRecord(',"$('trainingForm').addEventListener"));
  h.run(slice('function saveSleepRecord(',"$('sleepForm').addEventListener"));
  h.run(slice('async function applyHealthJSON(',"$('btnCheckHealth').addEventListener"));
  h.run(slice('function localDateTime(','function resetTrainingForm('));
  return h;
}
const read=h=>JSON.parse(h.run('buildBackup()'));
const day='2026-10-05';
const file={app:'kcal-health',version:1,exportedAt:'2026-10-06T08:00:00+08:00',days:[{date:day,
  energy:{active:600,basal:1400},training:[{id:'run-1',type:'跑步',durationMinutes:45,distanceKm:5,energyKcal:350}],
  sleep:{asleepMinutes:420,startAt:'2026-10-04T23:00:00+08:00',endAt:'2026-10-05T07:00:00+08:00',stages:{core:260,deep:70,rem:90}}}]};
const apply=(h,f)=>h.run(`applyHealthJSON(${JSON.stringify(JSON.stringify(f))})`);
async function main(){
  const h=healthHarness();h.run(`editDate='${day}'`);h.choose(true);
  assert.equal(await apply(h,file),true); assert.equal(h.writes(),1);
  assert.equal(read(h).training[day].sessions.length,1);
  assert.equal(read(h).sleep[day].asleepMinutes,420);
  assert.equal(read(h).burn[day].active,600); // 训练 350 kcal 不重复叠加。
  assert.equal(h.run(`energyBalance('${day}',body,weight,burnByDay).burn`),2000);
  const unchanged=h.storage.get('kcal.data.v5');
  assert.equal(await apply(h,file),false);assert.equal(h.writes(),1);assert.equal(h.storage.get('kcal.data.v5'),unchanged);
  assert.equal(await apply(h,{...file,exportedAt:'2026-10-05T08:00:00+08:00'}),false);
  const updated={...file,exportedAt:'2026-10-07T08:00:00+08:00',days:[{...file.days[0],training:[]}]};
  h.choose(false);assert.equal(await apply(h,updated),false);assert.equal(h.storage.get('kcal.data.v5'),unchanged);
  h.choose(true);h.fail(true);assert.equal(await apply(h,updated),false);assert.equal(h.storage.get('kcal.data.v5'),unchanged);assert.equal(read(h).training[day].sessions.length,1);
  h.fail(false);assert.equal(await apply(h,updated),true);assert.equal(read(h).training[day].sessions.length,0);
  const reload=healthHarness(Object.fromEntries(h.storage));assert.deepEqual(read(reload).sleep,read(h).sleep);
  const complete=read(h), restored=healthHarness();restored.choose('replace');
  assert.equal(await restored.run(`applyImport(${JSON.stringify(JSON.stringify(complete))})`),true);
  assert.deepEqual(read(restored).training,complete.training);assert.deepEqual(read(restored).sleep,complete.sleep);
  // v5 缺少新类别时保留训练和睡眠；启动迁移也兼容旧快照。
  const old={...complete,version:5};delete old.training;delete old.sleep;
  assert.equal(await restored.run(`applyImport(${JSON.stringify(JSON.stringify(old))})`),true);
  assert.deepEqual(read(restored).sleep,complete.sleep);
  const legacy=healthHarness({'kcal.data.v5':JSON.stringify(old)});
  assert.equal(legacy.run('storageReadError'),false);assert.deepEqual(read(legacy).training,{});
  legacy.run('commitData({})');assert.equal(JSON.parse(legacy.storage.get('kcal.data.v5')).version,6);
  for(const entry of [
    {...file.days[0],date:'2026-02-30'},
    {...file.days[0],training:[...file.days[0].training,...file.days[0].training]},
    {...file.days[0],energy:{active:600}},
    {...file.days[0],sleep:{...file.days[0].sleep,asleepMinutes:500}},
    {...file.days[0],sleep:{...file.days[0].sleep,stages:{core:500}}},
    {...file.days[0],sleep:{...file.days[0].sleep,endAt:'2026-10-06T07:00:00+08:00'}},
    {...file.days[0],sleep:{asleepMinutes:-1}},
    {...file.days[0],training:[{...file.days[0].training[0],durationMinutes:0}]}
  ])assert.throws(()=>h.run(`parseHealthJSON(${JSON.stringify(JSON.stringify({...file,days:[entry]}))})`));
  assert.throws(()=>h.run(`parseHealthJSON(${JSON.stringify(JSON.stringify({...file,days:[file.days[0],file.days[0]]}))})`));
  assert.throws(()=>h.run(`parseHealthJSON(${JSON.stringify(JSON.stringify({...file,exportedAt:'2026-10-06T08:00'}))})`));
  assert.throws(()=>h.run(`parseHealthJSON(${JSON.stringify(JSON.stringify({...file,exportedAt:'2099-10-06T08:00:00Z'}))})`));
  assert.throws(()=>h.run("healthTimestamp('2026-10-05T24:00:00Z')"));
  assert.throws(()=>h.run(`validateBackup(${JSON.stringify({...complete,sleep:{[day]:{asleepMinutes:420,source:'manual'}}})})`));
  // 手动记录、编辑、失败恢复；空白不同于零。睡眠不从起止时间猜测睡着时长。
  h.run(`editDate='${day}';saveTrainingRecord({type:'力量训练',durationMinutes:30})`);
  assert.equal(read(h).training[day].sessions.length,1);
  const id=read(h).training[day].sessions[0].id;
  h.run(`trainingEditingId=${JSON.stringify(id)};saveTrainingRecord({type:'力量训练',durationMinutes:40})`);
  assert.equal(read(h).training[day].sessions.length,1);assert.equal(read(h).training[day].sessions[0].durationMinutes,40);
  h.fail(true);h.run('saveSleepRecord({asleepMinutes:390})');assert.equal(read(h).sleep[day].asleepMinutes,420);h.fail(false);
  h.run('saveSleepRecord({asleepMinutes:390})');assert.equal(read(h).sleep[day].stages,undefined);
  h.run('saveSleepRecord({asleepMinutes:0})');assert.equal(read(h).sleep[day].asleepMinutes,0);
  const parsed=h.run(`parseHealthJSON(${JSON.stringify(JSON.stringify({...file,exportedAt:new Date(Date.now()+1000).toISOString()}))})`);
  assert.ok(h.run(`healthImportPlan(${JSON.stringify(parsed)}).conflicts`)>=1);
  const points=[{k:'2026-10-01',kg:70},{k:'2026-10-03',kg:70},{k:day,kg:70}];
  const chart=h.run(`weightLineChart(${JSON.stringify(points)},'${day}')`);
  assert.equal((chart.match(/class="point"/g)||[]).length,3);assert.match(chart,/class="trend"/);assert.doesNotMatch(chart,/wdot|wcol/);
  const uneven=h.run(`weightLineChart([{k:'2026-10-01',kg:70},{k:'2026-10-02',kg:69.9},{k:'${day}',kg:69.8}],'${day}')`);
  const xs=[...uneven.matchAll(/class="point" cx="([^"]+)"/g)].map(m=>Number(m[1]));
  assert.ok(Math.abs((xs[2]-xs[1])/(xs[1]-xs[0])-3)<1e-6); // 三天空档与一天间隔保持比例。
  const single=h.run(`weightLineChart([{k:'${day}',kg:70}],'${day}')`);assert.match(single,/circle/);assert.doesNotMatch(single,/NaN|polyline/);
  const local=h.run("zonedDateTime('2026-10-05T07:00')");assert.equal(h.run(`localDateTime(${JSON.stringify(local)})`),'2026-10-05T07:00');
  console.log('PASS: health import atomicity/cancel/stale/dedup, v5/v6 backup migration, sleep dates/stages, training edits, no double energy and weight line geometry');
}
main().catch(e=>{console.error(e);process.exitCode=1;});

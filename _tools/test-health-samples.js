/* node _tools/test-health-samples.js：真实导入管线上的样本汇总与体重迁移检查。 */
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {harness}=require('./test-energy');
const html=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const ui=script.slice(script.indexOf('async function applyHealthJSON('),script.indexOf("$('btnCheckHealth').addEventListener"));
const make=seed=>{const h=harness(seed);h.run(ui);return h;};
const read=h=>JSON.parse(h.run('buildBackup()'));
const encode=f=>JSON.stringify(f);
const parse=(h,f)=>h.run(`parseHealthJSON(${JSON.stringify(encode(f))})`);
const apply=(h,f)=>h.run(`applyHealthJSON(${JSON.stringify(encode(f))})`);
const t=s=>'2026-10-'+s+':00+08:00';
const sleep=(value,start,end)=>({kind:'sleep',value,startAt:t(start),endAt:t(end),source:'Test Watch'});
const mass=(value,start,unit='kg')=>({kind:'weight',value,unit,startAt:t(start),endAt:t(start),source:'Test Scale'});
const energy=(kind,value,start,end,unit='kcal')=>({kind,value,unit,startAt:t(start),endAt:t(end),source:'Test Watch'});
const rows=[
  sleep('In Bed','04T23:00','05T07:00'),sleep('Asleep','04T23:00','05T07:00'),
  sleep('Asleep (Core)','04T23:00','05T02:00'),sleep(4,'05T02:00','05T03:00'),
  sleep('REM','05T03:00','05T04:00'),sleep('清醒','05T04:00','05T05:00'),sleep('核心','05T05:00','05T07:00'),
  mass(72,'05T08:00'),mass(71.8,'05T20:00'),
  energy('active',600,'05T08:00','05T09:00'),energy('basal',1400,'05T00:00','06T00:00')
];
const file={app:'kcal-health-samples',version:1,exportedAt:t('06T08:00'),from:'2026-10-01',through:'2026-10-06',samples:rows};
const summary=(h,samples)=>parse(h,{...file,samples});
async function main(){
  const h=make({'kcal.weight.v1':JSON.stringify({'2026-09-22':73})});
  for(const filename of ['health-import-example.json','health-samples-example.json']){
    const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'..','docs',filename),'utf8'));
    const fields=parse(h,fixture);assert.equal(fields.weight['2026-10-05'],71.8);assert.equal(fields.sleep['2026-10-05'].asleepMinutes,420);
  }
  const parsed=summary(h,[...rows,rows[2],rows[8]]);
  assert.equal(parsed.sleep['2026-10-05'].asleepMinutes,420); // 未细分样本不叠加，清醒扣除，卧床不相加。
  assert.deepEqual(JSON.parse(JSON.stringify(parsed.sleep['2026-10-05'].stages)),{core:300,deep:60,rem:60});
  assert.equal(parsed.sleep['2026-10-04'],undefined); // 核心片段跨午夜，整夜归醒来日。
  assert.equal(parsed.weight['2026-10-05'],71.8);assert.equal(parsed.weightMeta['2026-10-05'].measuredAt,t('05T20:00'));
  assert.equal(parsed.burn['2026-10-05'].active,600);assert.equal(parsed.burn['2026-10-05'].basal,1400);
  assert.equal(parsed.burn['2026-10-06'],undefined); // 00:00 结束不生成下一天 0。
  h.choose(false);assert.equal(await apply(h,file),false);assert.equal(h.writes(),0);
  h.choose(true);h.fail(true);assert.equal(await apply(h,file),false);assert.equal(read(h).weight['2026-10-05'],undefined);
  h.fail(false);assert.equal(await apply(h,file),true);assert.equal(read(h).version,7);
  assert.equal(read(h).weight['2026-09-22'],73);assert.equal(read(h).weight['2026-10-05'],71.8);
  const saved=h.storage.get('kcal.data.v5');assert.equal(await apply(h,file),false);assert.equal(h.storage.get('kcal.data.v5'),saved);
  const reload=make(Object.fromEntries(h.storage));assert.equal(reload.run('storageReadError'),false);assert.deepEqual(read(reload).weightMeta,read(h).weightMeta);
  const oldMeasurement={...file,exportedAt:t('07T08:00'),samples:[mass(72,'05T08:00')]};
  assert.equal(await apply(h,oldMeasurement),false);assert.equal(read(h).weight['2026-10-05'],71.8);
  const weightOnly={app:'kcal-health',version:2,exportedAt:t('06T09:00'),days:[{date:'2026-09-23',weight:{kg:72.9,measuredAt:'2026-09-23T08:00:00+08:00'}}]};
  assert.equal(await apply(h,weightOnly),true);assert.equal(read(h).weight['2026-09-22'],73);assert.equal(read(h).weight['2026-09-23'],72.9);
  h.run("editDate='2026-09-23'");h.node('wInput').value='72.5';h.node('btnSaveWeight').click();
  assert.equal(read(h).weightMeta['2026-09-23'].source,'manual');
  assert.equal(await apply(h,weightOnly),false);assert.equal(read(h).weight['2026-09-23'],72.5);
  const futureExport={...weightOnly,exportedAt:new Date(Date.now()+1000).toISOString()};
  assert.equal(h.run(`healthImportPlan(parseHealthJSON(${JSON.stringify(encode(futureExport))})).conflicts`),1);
  // 同日午睡汇总；未细分阶段保留为“未提供”，不假造 REM=0。
  const naps=summary(h,[...rows.filter(r=>r.kind==='sleep'),sleep('core','05T13:00','05T13:30')]);
  assert.equal(naps.sleep['2026-10-05'].asleepMinutes,450);assert.equal(naps.sleep['2026-10-05'].stages.core,330);
  const generic=summary(h,[sleep('Asleep','04T23:00','05T07:00')]);
  assert.equal(generic.sleep['2026-10-05'].asleepMinutes,480);assert.equal(generic.sleep['2026-10-05'].stages,undefined);
  const grams=summary(h,[mass(71800,'05T20:00','g')]);assert.equal(grams.weight['2026-10-05'],71.8);
  const pounds=summary(h,[mass(150,'05T20:00','lb')]);assert.ok(Math.abs(pounds.weight['2026-10-05']-68.0388555)<1e-8);
  const kj=summary(h,[energy('active',2510.4,'05T08:00','05T09:00','kJ'),rows.at(-1)]);assert.ok(Math.abs(kj.burn['2026-10-05'].active-600)<1e-8);
  const split=summary(h,[energy('active',120,'04T23:00','05T01:00'),energy('basal',100,'04T23:00','05T01:00')]);
  assert.equal(split.burn['2026-10-04'].active,60);assert.equal(split.burn['2026-10-05'].basal,50);assert.match(split.notes.join(''),/时长分配/);
  const partial=summary(h,[rows[8],rows[9]]);assert.equal(partial.burn['2026-10-05'],undefined);assert.match(partial.notes.join(''),/缺少/);
  const clipped=parse(h,{...file,from:'2026-10-05',through:'2026-10-05',samples:rows});assert.equal(clipped.sleep['2026-10-04'],undefined);
  for(const samples of [
    [sleep('Mystery','04T23:00','05T07:00')],
    [sleep('core','04T23:00','05T02:00'),sleep('deep','05T01:00','05T03:00')],
    [sleep('core','04T23:00','05T02:00'),sleep('awake','05T01:00','05T03:00')],
    [sleep('core','04T23:00','05T02:00'),{...sleep('deep','05T02:00','05T03:00'),source:'Other Watch'}],
    [rows[9],{...rows[9],source:'Other Watch'}],
    [rows[9],energy('active',100,'05T08:30','05T09:30')],
    [mass(72,'05T08:00'),mass(73,'05T08:00')],
    [mass('72','05T08:00')],[mass(0,'05T08:00')],[mass(72,'05T08:00','stone')],
    [{...rows[8],source:''}],[{...rows[8],endAt:t('07T20:00')}],[{...rows[8],extra:true}],
    [sleep('awake','04T23:00','05T07:00')]
  ])assert.throws(()=>summary(h,samples));
  for(const change of [
    {weight:{kg:72,measuredAt:'2026-09-24T08:00:00+08:00'}},
    {weight:{kg:72}},
    {sleep:{asleepMinutes:60,stages:{core:60}}},
    {weight:{kg:401,measuredAt:'2026-09-23T08:00:00+08:00'}}
  ])assert.throws(()=>parse(h,{...weightOnly,days:[{date:'2026-09-23',...change}]}));
  // 完整备份包含来源；v6 恢复覆盖体重时清理来源；缺少体重类别则保留来源。
  const full=read(h),restored=make();restored.choose('replace');
  assert.equal(await restored.run(`applyImport(${JSON.stringify(encode(full))})`),true);
  assert.deepEqual(read(restored).weightMeta,full.weightMeta);
  const v6={...full,version:6};delete v6.weightMeta;
  const legacy=make({'kcal.data.v5':encode(v6)});assert.equal(legacy.run('storageReadError'),false);assert.deepEqual(read(legacy).weightMeta,{});
  restored.choose('merge');assert.equal(await restored.run(`applyImport(${JSON.stringify(encode(v6))})`),true);assert.deepEqual(read(restored).weightMeta,{});
  assert.throws(()=>h.run(`validateBackup(${JSON.stringify({...full,weightMeta:{'2026-09-21':{source:'health-json',updatedAt:file.exportedAt}}})})`));
  const stale=make();stale.storage.set('kcal.data.v5',encode(full));stale.choose(true);assert.equal(await apply(stale,file),false);
  console.log('PASS: weight history/provenance/v7 migration, latest daily measurement, units, sleep phase union/awake exclusion/cross-midnight/naps, source ambiguity, partial energy, import repeat/cancel/quota/stale');
}
main().catch(e=>{console.error(e);process.exitCode=1;});

/* Synthetic totals/boundaries exercise the actual parser and atomic import path. */
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {harness}=require('./test-energy');
const html=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const ui=script.slice(script.indexOf('async function applyHealthJSON('),script.indexOf("$('btnCheckHealth').addEventListener"));
const make=()=>{const h=harness();h.run(ui);return h;};
const copy=o=>JSON.parse(JSON.stringify(o));
const stamp=s=>'2026-10-'+s+':00+08:00';
const total=(kind,values)=>({kind,unit:'kcal',source:'Synthetic Watch',count:2,separator:'|',dates:'2026-10-06|2026-10-07',values});
const boundary=(kind,date,value)=>({kind,unit:'kcal',source:'Synthetic Watch',boundaryAt:stamp(date+'T00:00'),value,startAt:stamp(String(+date-1).padStart(2,'0')+'T23:00'),endAt:stamp(date+'T01:00')});
const file={app:'kcal-health-energy',version:1,exportedAt:stamp('08T08:00'),from:'2026-10-06',through:'2026-10-07',dailyTotals:[total('active','500|600'),total('basal','1500|1600')],boundarySamples:[boundary('active','06',120),boundary('active','07',80),boundary('active','08',40),boundary('basal','06',200),boundary('basal','07',120),boundary('basal','08',80)]};
const parse=(h,f)=>h.run(`parseHealthJSON(${JSON.stringify(JSON.stringify(f))})`);
const apply=(h,f)=>h.run(`applyHealthJSON(${JSON.stringify(JSON.stringify(f))})`);
async function main(){
  const h=make(),fields=parse(h,file);
  assert.equal(h.run(`healthImportPlan(parseHealthJSON(${JSON.stringify(JSON.stringify(file))})).summary`),'能量 2 天 · 2026-10-06 至 2026-10-07');
  assert.equal(fields.burn['2026-10-06'].active,520);assert.equal(fields.burn['2026-10-06'].basal,1540);
  assert.equal(fields.burn['2026-10-07'].active,620);assert.equal(fields.burn['2026-10-07'].basal,1620);
  const single=copy(file);single.through=single.from;
  single.dailyTotals.forEach(b=>{b.count=1;b.dates='2026-10-06';b.values=b.values.split('|')[0];});
  single.boundarySamples=single.boundarySamples.filter(r=>r.boundaryAt.slice(0,10)<='2026-10-07');
  const singleFields=parse(h,single);assert.deepEqual(Object.keys(singleFields.burn),['2026-10-06']);
  assert.equal(singleFields.burn['2026-10-06'].active,520);assert.equal(singleFields.burn['2026-10-06'].basal,1540);
  assert.match(fields.notes.join(''),/按时长比例/);
  const fractional=copy(file);fractional.dailyTotals[0].values='500.125|600.75';
  assert.equal(parse(h,fractional).burn['2026-10-06'].active,520.125);
  assert.match(h.run(`healthImportPlan(parseHealthJSON(${JSON.stringify(JSON.stringify(fractional))})).details.join(' ')`),/活动 520/);
  const duplicate=copy(file);duplicate.boundarySamples.push(copy(file.boundarySamples[0]));assert.equal(parse(h,duplicate).burn['2026-10-06'].active,520);
  const mixedUnits=copy(file);mixedUnits.dailyTotals[0].unit='kJ';mixedUnits.dailyTotals[0].values='2092|2510.4';
  mixedUnits.boundarySamples.filter(r=>r.kind==='active').forEach(r=>{r.unit='kJ';r.value*=4.184;});
  assert.ok(Math.abs(parse(h,mixedUnits).burn['2026-10-06'].active-520)<1e-8);
  const noCross=copy(file);noCross.boundarySamples.forEach(r=>{r.startAt=r.startAt.replace('23:00','21:00');r.endAt=stamp(String(+r.boundaryAt.slice(8,10)-1).padStart(2,'0')+'T22:00');});
  assert.equal(parse(h,noCross).burn['2026-10-06'].active,500);
  const explicitZero=copy(noCross);explicitZero.dailyTotals[0].values='0|0';assert.equal(parse(h,explicitZero).burn['2026-10-06'].active,0);
  const partial=copy(file);partial.boundarySamples=partial.boundarySamples.filter(r=>!(r.kind==='basal' && r.boundaryAt===stamp('08T00:00')));
  assert.equal(parse(h,partial).burn['2026-10-07'],undefined);assert.equal(parse(h,partial).burn['2026-10-06'].active,520);assert.match(parse(h,partial).notes.join(''),/保留已有/);
  const missingDay=copy(file);missingDay.dailyTotals[0].dates='2026-10-06';missingDay.dailyTotals[0].values='500';missingDay.dailyTotals[0].count=1;
  assert.equal(parse(h,missingDay).burn['2026-10-07'],undefined);
  const invalids=[
    f=>{f.dailyTotals[0].separator="'";},f=>{f.dailyTotals[0].count=3;},
    f=>{f.dailyTotals[0].dates='2026-10-06|2026-10-06';},f=>{f.dailyTotals[0].values='500 kcal|600';},
    f=>{f.dailyTotals[0].values='|600';},f=>{f.dailyTotals[0].extra=true;},
    f=>{f.dailyTotals.push(copy(f.dailyTotals[0]));},f=>{f.dailyTotals[0].unit='unknown';},
    f=>{f.boundarySamples[0].source='Another Source';},f=>{f.boundarySamples[0].value='120';},
    f=>{f.boundarySamples[0].boundaryAt=stamp('06T00:01');},
    f=>{f.boundarySamples[0].startAt=stamp('06T00:00');},
    f=>{f.boundarySamples[0].endAt=stamp('07T02:00');},
    f=>{f.boundarySamples[0].endAt=f.boundarySamples[0].endAt.replace('+08:00','+07:00');},
    f=>{f.boundarySamples.filter(r=>r.kind==='basal').forEach(r=>{for(const key of ['boundaryAt','startAt','endAt'])r[key]=r[key].replace('+08:00','+07:00');});},
    f=>{f.boundarySamples.push({...f.boundarySamples[0],value:50,startAt:stamp('05T23:30')});},
    f=>{f.boundarySamples=[];},f=>{f.dailyTotals[0].values='0|600';f.boundarySamples[0].value=0;},
    f=>{f.exportedAt=stamp('07T00:00');},f=>{f.through='2026-10-05';}
  ];
  for(const mutate of invalids){const f=copy(file);mutate(f);assert.throws(()=>parse(h,f));}
  h.choose(false);assert.equal(await apply(h,file),false);assert.equal(h.writes(),0);
  const beforeFailure=h.storage.get('kcal.data.v5');
  h.choose(true);h.fail(true);assert.equal(await apply(h,file),false);assert.equal(h.storage.get('kcal.data.v5'),beforeFailure);assert.equal(h.run("burnByDay['2026-10-06']"),undefined);
  h.fail(false);assert.equal(await apply(h,file),true);
  const saved=h.storage.get('kcal.data.v5');assert.equal(await apply(h,file),false);assert.equal(h.storage.get('kcal.data.v5'),saved);
  const next=copy(partial);next.exportedAt=stamp('09T08:00');next.dailyTotals[0].values='550|600';
  assert.equal(await apply(h,next),true);assert.equal(h.run("burnByDay['2026-10-07'].active"),620);
  assert.equal(h.run("burnByDay['2026-10-06'].active"),570);
  const before=h.storage.get('kcal.data.v5');await assert.rejects(()=>apply(h,copy({...file,boundarySamples:[]})),/没有两类/);assert.equal(h.storage.get('kcal.data.v5'),before);
  console.log('PASS: energy totals + midnight boundaries, precision/units/source/coverage validation, missing-day preservation, and atomic cancel/failure/repeat import');
}
main().catch(e=>{console.error(e);process.exitCode=1;});

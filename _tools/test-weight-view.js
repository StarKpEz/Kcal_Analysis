/* 体重历史窗口、真实日历间隔和只读交互回归；全部使用虚构数据。 */
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {harness}=require('./test-energy');
const script=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const slice=(a,b)=>script.slice(script.indexOf(a),script.indexOf(b,script.indexOf(a)));
const h=harness(),run=h.run;
run(slice('function esc(', '/* ---------------- 存储'));
const weights={'2026-08-24':80,'2026-08-31':79,'2026-09-01':78.5,'2026-09-22':78,'2026-10-01':77.8,'2026-10-08':77.5,'2026-10-09':77.4,'2026-10-10':100};
run(`weight=${JSON.stringify(weights)};editDate='2026-10-09';`);
const window=(mode,anchor='2026-10-09',asOf='2026-10-09')=>run(`weightWindow(weight,${JSON.stringify(mode)},${JSON.stringify(anchor)},${JSON.stringify(asOf)})`);
let v=window('all');
assert.equal(v.from,'2026-08-24');assert.equal(v.through,'2026-10-09');assert.equal(v.records.length,7);
assert.equal(v.first,80);assert.equal(v.last,77.4);assert.ok(Math.abs(v.delta+2.6)<1e-8);
assert.equal(v.canPrevious,false);assert.equal(v.canNext,false);
v=window('week');assert.equal(v.from,'2026-10-05');assert.equal(v.through,'2026-10-09');assert.equal(v.records.length,2);
assert.equal(v.previous,'2026-09-28');assert.equal(v.canNext,false);assert.equal(v.canPrevious,true);
v=window('month','2026-09-09');assert.equal(v.from,'2026-09-01');assert.equal(v.through,'2026-09-30');assert.equal(v.records.length,2);
assert.equal(v.next,'2026-10-01');assert.equal(v.previous,'2026-08-31');assert.equal(v.canNext,true);
v=window('month','2026-08-01');assert.equal(v.canPrevious,false);assert.equal(v.records.length,2);
v=window('month','2024-02-10');assert.equal(v.through,'2024-02-29');assert.equal(v.next,'2024-03-01');
v=window('month','2026-02-10');assert.equal(v.through,'2026-02-28');
v=window('year','2025-10-01');assert.equal(v.through,'2025-12-31');assert.equal(v.next,'2026-01-01');assert.equal(v.records.length,0);
v=window('week','2026-01-01');assert.equal(v.from,'2025-12-29');assert.equal(v.through,'2026-01-04');
v=window('all','2026-09-01','2026-09-01');assert.equal(v.records.length,3);assert.equal(v.last,78.5);
assert.equal(run("weightWindow({},'all','2026-10-09','2026-10-09').delta"),null);
assert.equal(run("weightWindow({'2026-02-30':80,'2026-10-09':77},'all','2026-10-09','2026-10-09').records.length"),1);
// 不限14天，完整显示全部数据；跨缺测日保持日期比例，单点无虚构变化或连线。
v=window('all');let chart=run(`weightLineChart(${JSON.stringify(v.records)},'${v.through}','${v.from}')`);
assert.equal((chart.match(/class="point"/g)||[]).length,7);assert.doesNotMatch(chart,/NaN|Infinity/);
const xs=[...chart.matchAll(/class="point" cx="([^"]+)"/g)].map(m=>+m[1]);
assert.ok(Math.abs((xs[3]-xs[2])/(xs[2]-xs[1])-21)<1e-6);
chart=run("weightLineChart([{k:'2026-10-09',kg:77}],'2026-10-09','2026-10-09')");
assert.match(chart,/cx="195"/);assert.doesNotMatch(chart,/polyline|NaN|Infinity/);
assert.match(run("weightLineChart([],'2026-10-09','2026-10-01')"),/这个区间没有体重记录/);
// 生产UI：切换、翻页、滑块和所选日期同步均不写存储，不修改输入草稿或体重。
for(const id of ['weightScrub','weightSelectedPoint','weightSelectedGuide']){
  const node=h.node(id);node.attributes={};node.setAttribute=(k,v)=>node.attributes[k]=v;
}
h.node('weightBox').querySelector=()=>({focus(){}});
run(slice('/* 时间范围只控制图表','let weightEditDate'));
h.node('wInput').value='76.9';
const before=run('JSON.stringify(dataSnapshot())'),writes=h.writes();run('renderWeightPanel()');
assert.match(h.node('weightBox').innerHTML,/全部记录（7 天）/);
assert.match(h.node('weightBox').innerHTML,/累计体重变化/);
const click=data=>h.node('weightBox').handlers.click({target:{closest:selector=>selector==='button'?{dataset:data,disabled:false}:null}});
click({weightMode:'month'});assert.equal(run('currentWeightWindow().records.length'),3);
click({weightStep:'previous'});assert.equal(run('currentWeightWindow().from'),'2026-09-01');
assert.match(h.node('weightBox').innerHTML,/全部记录（2 天）/);
run('selectWeightPoint(0)');assert.match(h.node('weightReadout').innerHTML,/2026-09-01/);
h.node('weightBox').handlers.input({target:{id:'weightScrub',value:'1'}});
assert.match(h.node('weightReadout').innerHTML,/2026-09-22/);
assert.equal(h.node('weightScrub').attributes['aria-valuetext'],'2026-09-22，78 kg');
assert.equal(h.node('wInput').value,'76.9');assert.equal(run('editDate'),'2026-10-09');
assert.equal(run('JSON.stringify(dataSnapshot())'),before);assert.equal(h.writes(),writes);
run("editDate='2026-08-31';renderWeightPanel()");assert.equal(run('weightView.anchor'),'2026-08-31');
assert.equal(run('currentWeightWindow().records.length'),2);
run("weight={};renderWeightPanel()");assert.match(h.node('weightBox').innerHTML,/这个区间没有体重记录/);
run("weight={'2026-08-31':77};renderWeightPanel()");assert.match(h.node('weightBox').innerHTML,/只有一次称重/);
console.log('PASS: full weight history, calendar periods/leap years, window statistics, true gaps, empty/single points, inspection and navigation without data writes');

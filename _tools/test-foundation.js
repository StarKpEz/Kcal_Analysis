/* node _tools/test-foundation.js：长期保存、事务恢复、无需确认的统计与模型边界。 */
const assert = require('node:assert/strict');
const { harness } = require('./test-energy');
const day = '2026-10-05';
const food = { name:'早餐', kcal:500, protein:25, fat:15, carbs:50, grams:200 };
const backup = h => { const b = JSON.parse(h.run('buildBackup()')); delete b.exportedAt; return b; };
const state = h => JSON.stringify(backup(h));
async function main(){
  // 长历史启动、首次迁移、重载均保留全部数据；支持访问旧月份。
  const dates = {}, h = harness();
  for (let i=0;i<180;i++) dates[h.run(`shiftDay('${day}',-${i})`)] = { breakfast:[food] };
  const history = harness({ 'kcal.entries.v1':JSON.stringify(dates) });
  assert.equal(history.run('Object.keys(store).length'),180);
  assert.equal(history.run('commitData({})'),true);
  const reloaded = harness(Object.fromEntries(history.storage));
  assert.equal(reloaded.run('Object.keys(store).length'),180);
  reloaded.run("setEditDate('2026-05-01')"); assert.equal(reloaded.run('editDate'),'2026-05-01');
  reloaded.run("setEditDate('2026-02-30')"); assert.equal(reloaded.run('editDate'),'2026-05-01');

  const original = harness({ 'kcal.entries.v1':JSON.stringify({ [day]:{ breakfast:[food] } }),
    'kcal.body.v1':JSON.stringify({ heightCm:175, birthYear:1990, weightKg:70 }),
    'kcal.weight.v1':JSON.stringify({ [day]:70 }),
    'kcal.burn.v1':JSON.stringify({ [day]:{ active:600, basal:1400 } }) });
  original.run(`editDate='${day}'`);
  // 旧完成标记作为兼容字段备份；统计不再依赖它。
  original.run(`commitData({completion:{'${day}':{food:true,energy:true}}})`);
  assert.equal(original.run('energyBalance(editDate,body,weight,burnByDay).canCompare'),true);
  const full = backup(original);
  assert.deepEqual(full.completion[day],{ food:true, energy:true });
  const restored = harness(); restored.choose('replace');
  assert.equal(await restored.run(`applyImport(${JSON.stringify(JSON.stringify(full))})`),true);
  assert.deepEqual(backup(restored),full);
  assert.equal(restored.writes(),1); // 所有类别只进行一次写入，没有部分恢复。
  assert.deepEqual(backup(harness(Object.fromEntries(restored.storage))),full);
  const shared = new Map([['kcal.data.v5',JSON.stringify(full)]]);
  const windowA = harness(shared), windowB = harness(shared);
  windowA.run('commitData({settings:{...settings,kcal:2400}})');
  assert.equal(windowB.run('commitData({settings:{...settings,kcal:1800}})'),false);
  assert.equal(windowB.run('storageStale'),true);
  assert.equal(JSON.parse(shared.get('kcal.data.v5')).settings.kcal,2400);
  assert.throws(() => windowB.run('buildBackup()'),/其他窗口/);
  assert.equal(backup(harness(shared)).settings.kcal,2400);

  const newer = { ...full, settings:{ ...full.settings,kcal:2200 }, body:{ ...full.body,heightCm:190 },
    entries:{ [day]:{ lunch:[{ ...food,kcal:800 }] } },weight:{ [day]:65 }, burn:{ [day]:{ active:900,basal:1300 } } };
  const before = state(original), diskBefore = original.storage.get('kcal.data.v5');
  original.choose(null); assert.equal(await original.run(`applyImport(${JSON.stringify(JSON.stringify(newer))})`),false);
  assert.equal(state(original),before); assert.equal(original.storage.get('kcal.data.v5'),diskBefore);
  original.choose('replace'); original.fail(true);
  assert.equal(await original.run(`applyImport(${JSON.stringify(JSON.stringify(newer))})`),false);
  assert.equal(state(original),before); assert.equal(original.storage.get('kcal.data.v5'),diskBefore);
  assert.match(original.messages.at(-1),/保存失败/); original.fail(false);

  // 空备份明确替换空类别；档案留空能清除旧值。
  const empty = backup(harness());
  restored.choose('replace'); await restored.run(`applyImport(${JSON.stringify(JSON.stringify(empty))})`);
  assert.deepEqual(backup(restored),empty);
  original.choose('replace');
  await original.run(`applyImport(${JSON.stringify(JSON.stringify({ version:3,entries:{},body:{heightCm:''},weight:{} }))})`);
  assert.deepEqual(backup(original).entries,{}); assert.deepEqual(backup(original).weight,{});
  assert.equal(backup(original).body.heightCm,''); assert.deepEqual(backup(original).burn,full.burn);
  assert.equal(backup(original).completion[day].food,false);

  // 合并保留同一餐确实重复吃的两份；重复恢复幂等；不同份量不误去重。
  const merged = harness({ 'kcal.entries.v1':JSON.stringify({ [day]:{ breakfast:[food] } }) });
  const repeated = { entries:{ [day]:{ breakfast:[food,food,{ ...food,grams:100 }] } } };
  await merged.run(`applyImport(${JSON.stringify(JSON.stringify(repeated))})`);
  assert.equal(merged.run(`store['${day}'].breakfast.length`),3);
  await merged.run(`applyImport(${JSON.stringify(JSON.stringify(repeated))})`);
  assert.equal(merged.run(`store['${day}'].breakfast.length`),3);

  // 修改数据自动失效；另一类状态及其他日期不受影响；写入失败撤回内存更改。
  const edited = harness(); edited.choose('replace'); await edited.run(`applyImport(${JSON.stringify(JSON.stringify(full))})`);
  edited.run(`editDate='${day}';currentMeal='breakfast'`);
  edited.run(`addItems([${JSON.stringify({ ...food,name:'加一份' })}])`);
  assert.deepEqual(backup(edited).completion[day],{ food:false,energy:true });
  edited.run(`commitData({completion:{'${day}':{food:true,energy:true}}})`);
  edited.node('energyActive').value='700'; edited.node('energyBasal').value='1400'; edited.node('btnSaveEnergy').click();
  assert.deepEqual(backup(edited).completion[day],{ food:true,energy:false });
  const editBefore = state(edited); edited.fail(true);
  assert.equal(edited.run(`addItems([${JSON.stringify({ ...food,name:'失败的数据' })}])`),0);
  assert.equal(state(edited),editBefore); edited.fail(false);
  edited.run("editDate='2026-10-04'");
  assert.equal(backup(edited).completion['2026-10-04'],undefined);
  assert.deepEqual(backup(edited).completion[day],{ food:true,energy:false });

  const zero = harness(); zero.run(`editDate='${day}'`);
  assert.equal(zero.run('energyBalance(editDate,body,weight,burnByDay).hasIntake'),false);
  zero.run(`commitData({completion:{'${day}':{food:true,energy:true}}})`);
  assert.equal(zero.run('energyBalance(editDate,body,weight,burnByDay).hasIntake'),false);
  zero.node('energyActive').value='0'; zero.node('energyBasal').value='0'; zero.node('btnSaveEnergy').click();
  assert.equal(zero.run('energyBalance(editDate,body,weight,burnByDay).canCompare'),false);
  assert.equal(zero.run('energyBalance(editDate,body,weight,burnByDay).burn'),0);
  zero.run(`store={'${day}':{breakfast:[{name:'零热量条目',kcal:0}]}};save()`);
  assert.equal(zero.run('energyBalance(editDate,body,weight,burnByDay).hasIntake'),true);
  assert.equal(zero.run('energyBalance(editDate,body,weight,burnByDay).canCompare'),true);
  // 当天能量始终是累计进度，不能因旧完成标记而展示全天差额。
  const ongoing = harness(); ongoing.run('editDate=todayKey()');
  ongoing.run(`store={[editDate]:{lunch:[${JSON.stringify(food)}]}};save()`);
  ongoing.node('energyActive').value='600'; ongoing.node('energyBasal').value='1400'; ongoing.node('btnSaveEnergy').click();
  ongoing.run('commitData({completion:{[editDate]:{food:true,energy:true}}})');
  assert.equal(ongoing.run('energyBalance(editDate,body,weight,burnByDay).canCompare'),false);
  assert.equal(ongoing.run('energyBalance(editDate,body,weight,burnByDay).hasDayEnergy'),false);
  assert.equal(ongoing.run('energyBalance(editDate,body,weight,burnByDay).burn'),2000);
  assert.ok(backup(ongoing).burn[ongoing.run('editDate')].updatedAt);
  assert.equal(backup(harness(Object.fromEntries(ongoing.storage))).burn[ongoing.run('editDate')].updatedAt,backup(ongoing).burn[ongoing.run('editDate')].updatedAt);
  const automatic = harness({'kcal.entries.v1':JSON.stringify({[day]:{lunch:[food]}}),'kcal.burn.v1':JSON.stringify({[day]:{active:600,basal:1400}})});
  assert.equal(automatic.run(`energyBalance('${day}',body,weight,burnByDay).canCompare`),true);
  assert.deepEqual(backup(automatic).completion,{});

  // 不接受损坏、未来版本、非法日期或非法能量；失败不会触发覆盖。
  for (const bad of ['{"entries":', JSON.stringify({app:'other',entries:{}}), JSON.stringify({...full,version:8}),
    JSON.stringify({...full,burn:{ [day]:{active:-1,basal:1400} }}),
    JSON.stringify({...full,weight:{'2026-02-30':70}}), JSON.stringify({version:5,entries:{}})]){
    const prev = state(edited), writes = edited.writes();
    assert.equal(await edited.run(`applyImport(${JSON.stringify(bad)})`),false);
    assert.equal(state(edited),prev); assert.equal(edited.writes(),writes);
  }
  const corrupt = harness({ 'kcal.data.v5':'{broken' });
  assert.equal(corrupt.run('storageReadError'),true); assert.equal(corrupt.run('commitData({})'),false);
  assert.equal(JSON.parse(corrupt.run('buildBackup()')).raw['kcal.data.v5'],'{broken');
  corrupt.choose('replace'); assert.equal(await corrupt.run(`applyImport(${JSON.stringify(JSON.stringify(full))})`),true);
  assert.deepEqual(backup(corrupt),full);

  // 最终参考目标、差额与理论换算一致；极低消耗不会伪造正缺口。
  const clipped = h.run("suggestTarget(1600,'male')");
  assert.equal(clipped.target,1500); assert.equal(clipped.gap,100);
  assert.equal(clipped.weeklyKg,100*7/7700);
  assert.equal(h.run("suggestTarget(1000,'male').gap"),-500);
  assert.equal(h.run("suggestTarget(Infinity,'male').ok"),false);
  assert.equal(h.run("suggestTarget(2225.78,'male').clipped"),false);
  h.run("body={sex:'male',birthYear:1990,heightCm:175,weightKg:70,activity:1.375}");
  const estimateBefore=h.run(`energyBalance('${day}',body,weight,burnByDay).burn`);
  h.run(`store={'${day}':{breakfast:[{name:'食物',kcal:2000}]}}`);
  assert.equal(h.run(`energyBalance('${day}',body,weight,burnByDay).burn`),estimateBefore);
  assert.equal(h.run(`energyBalance('${day}',body,weight,burnByDay).tef`),0);

  // 长历史滚动窗口、独立传参、减重与增重方向、缺失日、未来称重过滤。
  const rolling = harness(), entries={}, weights={};
  const asOf='2026-10-07';
  for(let i=0;i<120;i++){
    const date=rolling.run(`shiftDay('${asOf}',-${119-i})`);
    entries[date]={lunch:[{name:'全天',kcal:2000}]};
    weights[date]=80-i*.02;
  }
  weights['2026-10-08']=130;
  const code=(e=entries,w=weights) => `reverseTDEE(${JSON.stringify(e)},${JSON.stringify(w)},{asOf:'${asOf}'})`;
  const result=rolling.run(code()); assert.equal(result.ok,true); assert.equal(result.days,27);
  assert.ok(Math.abs(result.value-2154)<.001); assert.equal(result.logged,27);
  const upward=Object.fromEntries(Object.keys(weights).map((k,i)=>[k,60+i*.02]));
  assert.ok(rolling.run(code(entries,upward)).value<2000);
  const missing={...entries}; delete missing['2026-10-02']; assert.equal(rolling.run(code(missing,weights)).reason,'fewLogs');
  assert.equal(rolling.run(code(entries,{[asOf]:70})).reason,'noWeight');

  // 历史清空只操作选中日期；保留今天及健康能量。
  const clearing=harness({ 'kcal.entries.v1':JSON.stringify({ [day]:{breakfast:[food]},[h.run('todayKey()')]:{lunch:[food]} }) });
  clearing.run(`editDate='${day}'`); clearing.choose(true); clearing.node('btnReset').click();
  assert.equal(clearing.run(`store['${day}']`),undefined);
  assert.ok(clearing.run('store[todayKey()]'));
  console.log('PASS: long history, v5 migration/reload, complete backups, atomic restore/cancel/failure, concurrent-window protection, empty/legacy restore, duplicate multiplicity, legacy flag compatibility, automatic history comparisons, partial-day exclusion, zero vs missing, energy timestamps, malformed data recovery, target/TEF corrections, rolling trends and selected-date clearing');
}
main().catch(err=>{console.error(err);process.exitCode=1;});

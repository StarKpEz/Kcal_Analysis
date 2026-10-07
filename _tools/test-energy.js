/* 零依赖回归测试：node _tools/test-energy.js */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script); // 完整生产脚本语法检查。
const slice = (a, b) => script.slice(script.indexOf(a), script.indexOf(b, script.indexOf(a)));
function harness(seed = {}) {
  const storage = seed instanceof Map ? seed : new Map(Object.entries(seed));
  const nodes = new Map(), messages = [];
  let failWrite = false, choice = 'merge', writes = 0;
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, { value: '', hidden: false, textContent: '', innerHTML: '',
      handlers: {}, addEventListener(event, handler) { this.handlers[event] = handler; },
      click() { return this.handlers.click?.(); } });
    return nodes.get(id);
  };
  const ctx = vm.createContext({ Date, console, $: node,
    N: v => Math.round(v * 10) / 10,
    toast: msg => messages.push(msg), render: () => {}, closeSet: () => {},
    window: { confirm: () => choice === true },
    askMergeOrReplace: async () => choice, askChoice: async () => choice,
    parseChatDoc: () => ({}),
    localStorage: { getItem: k => storage.get(k) ?? null, setItem(k, v) {
      writes++; if (failWrite) throw Error('quota'); storage.set(k, v);
    } }
  });
  vm.runInContext([
    slice("const LSK =", '/* ---------------- 提示词'),
    slice('/* TEST-EXTRACT-BURN-A */', '/* TEST-EXTRACT-BURN-B */'),
    slice('function countParsed(', 'function askChoice('),
    slice('function buildBackup(', '/* ---- 从对话/文档导入的弹窗'),
    slice('function allItemsOf(', '/* TEST-EXTRACT-B */'),
    slice("for (const id of ['energyActive'", '/* 启动：分步容错'),
    slice('function setEditDate(', 'function render(){'),
    slice('function addItems(', '/* ================= 第二屏'),
    slice("$('btnSaveSet').addEventListener", '/* ---- 身体数据 & 体重 ---- */'),
    slice("$('btnReset').addEventListener", "$('btnExport').addEventListener")
  ].join('\n'), ctx);
  const run = code => vm.runInContext(code, ctx);
  return { run, node, storage, messages, writes: () => writes,
    fail: v => { failWrite = v; }, choose: v => { choice = v; } };
}
async function main() {
  const day = '2026-10-05';
  const food = { [day]: { lunch: [{name:'测试餐', kcal:1500, protein:20}] } };
  const h = harness({'kcal.entries.v1':JSON.stringify(food)});
  const run = h.run;
  run(`editDate='${day}'`);
  h.node('energyActive').value = '600.5'; h.node('energyBasal').value = '1399.5';
  h.node('btnSaveEnergy').click();
  let eb = run(`energyBalance(editDate, body, weight, burnByDay)`);
  assert.equal(eb.burn, 2000); assert.equal(eb.deficit, 500); assert.equal(eb.tef, 0);
  assert.equal(eb.hasBody, false); assert.equal(eb.hasBurn, true); assert.equal(eb.source, 'manual');
  assert.deepEqual(JSON.parse(run('JSON.stringify(store)')), food);
  assert.equal(h.storage.get('kcal.entries.v1'), JSON.stringify(food)); // 旧数据保留，不覆写迁移来源。
  assert.equal(run(`energyBalance('2026-10-04',body,weight,burnByDay).hasBurn`), false);
  const fresh = harness(Object.fromEntries(h.storage));
  assert.equal(fresh.run(`energyBalance('${day}',body,weight,burnByDay).burn`),2000);
  run("body={sex:'male',birthYear:new Date().getFullYear()-30,heightCm:175,weightKg:70,activity:1.375}");
  assert.equal(run('energyBalance(editDate,body,weight,burnByDay).burn'),2000);
  const estimate = run(`energyBalance('2026-10-04',body,weight,burnByDay)`);
  assert.equal(estimate.burn, 1648.75 * 1.375); assert.equal(estimate.source,'estimate');
  // 不用未来体重推算过去；允许使用所选日期之前最近的体重。
  run(`weight={'2026-10-03':68,'2026-10-06':90}`);
  assert.equal(run(`energyBalance('2026-10-04',body,weight,burnByDay).bmr`),1628.75);
  const saved = h.storage.get('kcal.data.v5');
  for (const [a,b] of [['','1344'],['-1','1344'],['Infinity','1344'],['abc','1344'],['616','']]) {
    h.node('energyActive').value=a; h.node('energyBasal').value=b;
    h.node('btnSaveEnergy').click(); assert.equal(h.storage.get('kcal.data.v5'),saved);
  }
  h.node('energyActive').value='0'; h.node('energyBasal').value='0';
  h.node('btnSaveEnergy').click();
  assert.equal(run('energyBalance(editDate,body,weight,burnByDay).burn'),0);
  assert.equal(run('energyBalance(editDate,body,weight,burnByDay).hasBurn'),true);
  h.fail(true); h.node('energyActive').value='600'; h.node('energyBasal').value='1300';
  h.node('btnSaveEnergy').click();
  assert.equal(run('burnByDay[editDate].active'),0); assert.match(h.messages.at(-1),/保存失败/);
  h.fail(false);
  // 日期切换恢复对应值，重渲染不会丢掉同日期尚未保存的输入。
  run("energyEditDate='';renderEnergyInputs()"); assert.equal(h.node('energyActive').value,0);
  h.node('energyActive').value='42'; run('renderEnergyInputs()'); assert.equal(h.node('energyActive').value,'42');
  run("editDate='2026-10-04';renderEnergyInputs()"); assert.equal(h.node('energyActive').value,'');
  run(`editDate='${day}'`);
  const backup = JSON.parse(run('buildBackup()'));
  assert.equal(backup.version,5); assert.equal(backup.burn[day].active,0);
  const restore = harness(); await restore.run(`applyImport(${JSON.stringify(JSON.stringify(backup))})`);
  assert.deepEqual(JSON.parse(restore.run('buildBackup()')).burn,backup.burn);
  // 取消恢复时所有数据都不变，包括身体档案与能量。
  const before = run('buildBackup()'); h.choose(null);
  await run(`applyImport(${JSON.stringify(JSON.stringify({...backup,body:{heightCm:190},burn:{[day]:{active:999,basal:1400}}}))})`);
  const after = JSON.parse(run('buildBackup()')), prior = JSON.parse(before);
  assert.deepEqual(after.body,prior.body); assert.deepEqual(after.burn,prior.burn); assert.deepEqual(after.entries,prior.entries);
  h.choose('replace');
  await run(`applyImport(${JSON.stringify(JSON.stringify({version:3,entries:food}))})`);
  assert.equal(run('burnByDay[editDate].active'),0); // 旧备份不能擦掉新字段。
  h.choose('merge');
  await run(`applyImport(${JSON.stringify(JSON.stringify({entries:{},burn:{'2026-10-04':{active:500,basal:1400}}}))})`);
  assert.equal(run("burnByDay['2026-10-04'].active"),500); assert.equal(run('burnByDay[editDate].active'),0);
  h.choose('replace');
  await run(`applyImport(${JSON.stringify(JSON.stringify({entries:food,burn:{[day]:{active:600,basal:1300}}}))})`);
  assert.equal(run('Object.keys(burnByDay).length'),1); assert.equal(run('burnByDay[editDate].active'),600);
  h.choose(false); await h.node('btnClearEnergy').click(); assert.equal(run('burnByDay[editDate].active'),600);
  h.choose(true); await h.node('btnClearEnergy').click(); assert.equal(run('burnByDay[editDate]'),undefined);
  assert.equal(run('energyBalance(editDate,body,weight,burnByDay).source'),'estimate');
  assert.equal(run(`Object.keys(normalizeBurn({'2026-02-30':{active:1,basal:2},'2026-10-05':{active:-1,basal:2},'2026-10-04':{active:Infinity,basal:2},'2026-10-03':{active:'',basal:2},'2026-10-02':{active:0,basal:0}})).length`),1);
  console.log('PASS: energy calculation, date isolation, validation, storage failure, reload, backup/restore, cancellation and clearing');
}
module.exports = { harness };
if (require.main === module) main().catch(err => { console.error(err); process.exitCode=1; });

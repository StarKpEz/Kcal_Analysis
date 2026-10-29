// Bundle the whole existing application for iOS, without editing any PWA resource.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),nativeRoot=path.join(root,'native-ios'),target=path.join(nativeRoot,'Web');
const bridge=['native-platform.js','native-health.js','native-app.js','native.css'];
// Only these reviewed public files belong in the app; extra source files are ignored.
const docs=['health-import-example.json','health-samples-example.json','health-energy-example.json','健康数据导入格式.md','shortcuts-guide.html','energy-shortcuts-guide.html','energy-single-day-guide.html','能量导出步骤与接续-2026-10-12.md'];
function statIfPresent(file){
  try{return fs.lstatSync(file);}catch(error){if(error.code==='ENOENT')return null;throw error;}
}
function rejectLinkedAncestors(file){
  for(let current=path.resolve(file);;current=path.dirname(current)){
    const stat=statIfPresent(current);
    if(stat?.isSymbolicLink())throw new Error('Refusing linked iOS build path: '+current);
    if(path.dirname(current)===current)break;
  }
}
function checkTarget(){
  if(path.relative(nativeRoot,target)!=='Web')throw new Error('iOS output must be native-ios/Web');
  rejectLinkedAncestors(target);
  const stat=statIfPresent(target);
  if(stat && !stat.isDirectory())throw new Error('iOS output must be a directory: '+target);
}
checkTarget();
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const fingerprint=file=>crypto.createHash('sha256').update(read(file)).digest('hex');
const production=['index.html','app.css','navigation.js','sw.js'];
const before=production.map(fingerprint);
let html=read('index.html');
const matches=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
if(matches.length!==1)throw new Error('Expected one application script; update the iOS builder after structural changes.');
let script=matches[0][1];
const boundary=script.indexOf('/* ---------------- 版本与更新');
if(boundary<0)throw new Error('Missing update boundary');
const version=script.match(/const APP_VERSION = '([^']+)'/)[1];
script=script.slice(0,boundary).replace(/\blocalStorage\b/g,'nativeStorage');
function replaceOnce(find,replacement){
  if(!script.includes(find))throw new Error('Native adaptation boundary missing: '+find.slice(0,70));
  script=script.replace(find,()=>replacement);
}
function replaceSection(start,end,replacement){
  const a=script.indexOf(start),b=script.indexOf(end,a);
  if(a<0||b<0)throw new Error('Native adaptation section missing: '+start);
  script=script.slice(0,a)+replacement+'\n\n'+script.slice(b);
}
replaceOnce('await navigator.clipboard.writeText(prompt)',"await KcalNative.call('clipboard.write',{text:prompt})");
replaceOnce('if (navigator.clipboard && navigator.clipboard.readText) text = await navigator.clipboard.readText();',"text = (await KcalNative.call('clipboard.read')).text || '';");
replaceSection('function launchDeepSeek(){',"$('btnCopy').addEventListener",`async function launchDeepSeek(){
  const requested=settings.dsScheme || DS_WEB;
  try{await KcalNative.call('external.open',{url:requested});}
  catch(error){
    if(requested===DS_WEB){toast(error.message);return;}
    try{await KcalNative.call('external.open',{url:DS_WEB});}
    catch(fallback){toast(fallback.message);}
  }
}`);
replaceOnce("$('btnExport').addEventListener('click', () => {","$('btnExport').addEventListener('click', async () => {");
const csvStart=script.indexOf("    const blob = new Blob(['\\ufeff' + s]");
const csvEnd=script.indexOf("    toast('已导出 CSV（含各餐小计）');",csvStart);
if(csvStart<0||csvEnd<0)throw new Error('CSV share boundary missing');
script=script.slice(0,csvStart)+"    const result=await KcalNative.call('share.text',{text:'\\ufeff'+s,filename:'kcal-'+editDate+'.csv'});\n    if(!result?.completed){toast('已取消分享');return;}\n"+script.slice(csvEnd).replace("toast('已导出 CSV（含各餐小计）');","toast('已完成分享，请核对导出的 CSV');");
replaceSection('function doBackup(){','function validateBackup(',`async function doBackup(){
  try{
    const json=JSON.stringify(JSON.parse(buildBackup()));
    const result=await KcalNative.call('share.text',{text:json,filename:(storageReadError?'kcal-recovery-':'kcal-backup-')+todayKey()+'.json'});
    if(!result?.completed){toast('已取消分享');return;}
    if(storageReadError)toast('已分享原始恢复文件，请确认文件保存');
    else if(commitData({meta:{lastBackup:todayKey()}}))toast('已完成分享，请确认备份已保存到文件');
  }catch(error){toast('备份未完成：'+error.message);}
  refreshRisk();
}`);
replaceSection("$('btnRestore').addEventListener('click', () => {",'/* 按日期取某天全部条目',`$('btnRestore').addEventListener('click',async()=>{
  try{const file=await KcalNative.call('file.pick');if(file?.text!=null)await applyImport(file.text);}
  catch(error){toast('恢复未完成：'+error.message);}
});`);
replaceSection("$('btnChooseHealthFile').addEventListener('click',", "$('wellDate').addEventListener",`$('btnChooseHealthFile').addEventListener('click',async()=>{
  try{
    const file=await KcalNative.call('file.pick');if(file?.text==null)return;
    if(new TextEncoder().encode(file.text).length>5*1024*1024)throw new Error('健康 JSON 超过5MB，请缩小导出范围');
    $('healthJson').value=file.text;checkHealthImport();
  }catch(error){$('healthPreview').textContent=error.message;}
});`);
script=script.replace('数据保存在当前浏览器或主屏幕应用中','数据保存在此 iOS App 的本机文件中')
  .replace('全部历史持续保留，受浏览器存储空间限制。','全部历史持续保留，网页与 App 的记录分别存储。')
  .replace('删除图标、清理浏览器数据或换手机可能丢失数据，请先保存完整备份。','卸载 App 或换手机可能丢失本机数据，请先保存完整备份。');
script+='\nconst APP_VERSION = '+JSON.stringify(version)+';\n';
new vm.Script(script,{filename:'iOS/index.html'});
html=html.replace(matches[0][0],()=>'<script src="native-platform.js"></script>\n<script>'+script+'</script>');
html=html.replace(/<link[^>]+rel="(?:manifest|icon|apple-touch-icon)"[^>]*>\r?\n/g,'')
  .replace(/<meta[^>]+name="apple-mobile-web-app-[^"]+"[^>]*>\r?\n/g,'');
html=html.replace('<section id="healthPage" aria-labelledby="pageTitle" hidden>',`<section id="healthPage" aria-labelledby="pageTitle" hidden>
<section class="card" id="nativeHealth" aria-label="Apple 健康连接">
  <h2>Apple 健康</h2>
  <p class="hint">首次连接后可直接读取体重、能量、训练和睡眠，不再需要快捷指令导出。</p>
  <div class="native-range"><label>开始日期<input type="date" id="nativeFrom"></label><label>结束日期<input type="date" id="nativeThrough"></label></div>
  <label id="nativeSleepLabel" for="nativeSleepSource" hidden>睡眠来源</label><select id="nativeSleepSource" hidden aria-label="睡眠来源"></select>
  <button class="wide primary" id="btnNativeSync">连接并同步 Apple 健康</button>
  <label class="native-auto"><input type="checkbox" id="nativeAutoSync">打开 App 时自动刷新最近7天</label>
  <p id="nativeSyncStatus" class="hint" role="status">首次使用可先到设置恢复网页的完整备份；网页与 App 的记录分别保存。</p>
  <details id="nativeSyncDetails" class="hint" hidden><summary>同步详情</summary><p id="nativeSyncNotes"></p></details>
</section>`);
if(!html.includes('id="nativeHealth"'))throw new Error('Health page insertion point missing');
html=html.replace('</head>',`<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">\n<link rel="stylesheet" href="native.css">\n</head>`);
html=html.replace('</body>','<script src="native-health.js"></script>\n<script src="native-app.js"></script>\n</body>');
if(/navigator\.serviceWorker|\blocalStorage\b|URL\.createObjectURL|new FileReader/.test(html))throw new Error('Browser-only platform operation leaked into native bundle');
// Prepare a complete sibling tree before replacing the generated folder. In-place
// copying would leave stale or unreviewed files in Xcode's Web folder reference.
const transaction=fs.mkdtempSync(path.join(nativeRoot,'.web-build-'));
const staging=path.join(transaction,'Web'),previous=path.join(transaction,'previous-Web');
let originalMoved=false;
try{
  fs.mkdirSync(path.join(staging,'docs'),{recursive:true});
  fs.writeFileSync(path.join(staging,'index.html'),html);
  for(const file of ['app.css','navigation.js'])fs.copyFileSync(path.join(root,file),path.join(staging,file));
  for(const file of bridge){
    const content=read('native-ios/bridge/'+file);
    if(file.endsWith('.js'))new vm.Script(content,{filename:file});
    fs.writeFileSync(path.join(staging,file),content);
  }
  for(const file of docs)fs.copyFileSync(path.join(root,'docs',file),path.join(staging,'docs',file));
  if(JSON.stringify(before)!==JSON.stringify(production.map(fingerprint)))throw new Error('iOS build changed production files');
  checkTarget();
  if(statIfPresent(target)){fs.renameSync(target,previous);originalMoved=true;}
  try{fs.renameSync(staging,target);}
  catch(error){
    if(originalMoved){
      try{checkTarget();fs.renameSync(previous,target);originalMoved=false;}
      catch(rollback){throw new AggregateError([error,rollback],'iOS output replacement failed; original Web retained at '+previous);}
    }
    throw error;
  }
  originalMoved=false;
}finally{
  // Never delete the retained original if rollback itself was interrupted.
  if(!originalMoved){
    if(path.dirname(transaction)!==nativeRoot || !path.basename(transaction).startsWith('.web-build-'))throw new Error('Unsafe iOS temporary directory');
    rejectLinkedAncestors(transaction);
    try{fs.rmSync(transaction,{recursive:true,force:true});}
    catch(error){console.warn('Could not remove iOS build temporary directory: '+transaction+' ('+error.message+')');}
  }
}
console.log('Built native-ios/Web from the complete PWA; production unchanged. Web version '+version);

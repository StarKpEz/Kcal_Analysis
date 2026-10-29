// Exercise iOS packaging in disposable repositories, without Chrome or user data.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),vm=require('node:vm');
const assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const bridge=['native-platform.js','native-health.js','native-app.js','native-navigation.js','native.css'];
const docs=['health-import-example.json','health-samples-example.json','health-energy-example.json','健康数据导入格式.md','shortcuts-guide.html','energy-shortcuts-guide.html','energy-single-day-guide.html','能量导出步骤与接续-2026-10-12.md'];
const sourceFiles=['_tools/build-ios.js','index.html','app.css','navigation.js','sw.js',...bridge.map(file=>'native-ios/bridge/'+file),...docs.map(file=>'docs/'+file)];
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'kcal-ios-packaging-'));
function copySource(repo){
  for(const file of sourceFiles){
    const destination=path.join(repo,file);fs.mkdirSync(path.dirname(destination),{recursive:true});
    fs.copyFileSync(path.join(root,file),destination);
  }
}
function inventory(directory,prefix=''){
  return fs.readdirSync(directory,{withFileTypes:true}).flatMap(entry=>{
    assert(!entry.isSymbolicLink(),'Generated output must not contain links');
    const file=path.join(directory,entry.name),relative=prefix+entry.name;
    return entry.isDirectory()?inventory(file,relative+'/'):[relative];
  }).sort();
}
function snapshot(directory){
  return inventory(directory).map(file=>[file,crypto.createHash('sha256').update(fs.readFileSync(path.join(directory,file))).digest('hex')]);
}
function run(repo){return spawnSync(process.execPath,[path.join(repo,'_tools/build-ios.js')],{encoding:'utf8'});}
function success(repo){const result=run(repo);assert.equal(result.status,0,result.stdout+'\n'+result.stderr);}
function noTemporaryTrees(repo){assert.deepEqual(fs.readdirSync(path.join(repo,'native-ios')).filter(file=>file.startsWith('.web-build-')),[]);}
try{
  const repo=path.join(scratch,'repo');copySource(repo);
  const web=path.join(repo,'native-ios','Web');fs.mkdirSync(path.join(web,'docs'),{recursive:true});
  fs.writeFileSync(path.join(web,'obsolete-backup.json'),'{"fictional":true}');
  fs.writeFileSync(path.join(web,'docs','old-draft.md'),'Fictional obsolete documentation');
  fs.writeFileSync(path.join(repo,'native-ios','bridge','unreviewed.js'),'throw new Error("Must not ship")');
  fs.writeFileSync(path.join(repo,'docs','unreviewed.json'),'{"fictional":true}');
  const production=['index.html','app.css','navigation.js','sw.js'].map(file=>fs.readFileSync(path.join(repo,file)));
  success(repo);
  assert.deepEqual(inventory(web),['index.html','app.css','navigation.js',...bridge,...docs.map(file=>'docs/'+file)].sort());
  for(const [index,file] of ['index.html','app.css','navigation.js','sw.js'].entries())assert.deepEqual(fs.readFileSync(path.join(repo,file)),production[index]);
  const expected=snapshot(web);success(repo);assert.deepEqual(snapshot(web),expected,'Repeated packaging must be deterministic');noTemporaryTrees(repo);
  console.log('PASS exact public allowlist, obsolete-file exclusion, deterministic rebuild and unchanged PWA sources');

  fs.unlinkSync(path.join(repo,'native-ios','bridge','native-app.js'));
  const missing=run(repo);assert.notEqual(missing.status,0);assert.match(missing.stderr,/native-app\.js/);
  assert.deepEqual(snapshot(web),expected,'A preparation failure must preserve the previous Web');noTemporaryTrees(repo);
  fs.copyFileSync(path.join(root,'native-ios','bridge','native-app.js'),path.join(repo,'native-ios','bridge','native-app.js'));

  // Fail only the final activation rename; the following rollback must restore Web.
  let injected=false;
  const testFS=new Proxy(fs,{get(target,property){
    if(property!=='renameSync')return Reflect.get(target,property);
    return (from,to)=>{
      if(!injected && path.basename(from)==='Web' && path.dirname(from)!==path.dirname(web) && to===web){
        injected=true;throw Object.assign(new Error('Synthetic activation failure'),{code:'EACCES'});
      }
      return fs.renameSync(from,to);
    };
  }});
  assert.throws(()=>vm.runInNewContext(fs.readFileSync(path.join(repo,'_tools','build-ios.js'),'utf8'),{
    require:name=>name==='node:fs'?testFS:require(name),__dirname:path.join(repo,'_tools'),console
  },{filename:'build-ios-rollback-fixture.js'}),/Synthetic activation failure/);
  assert(injected);assert.deepEqual(snapshot(web),expected,'An activation failure must roll back the previous Web');noTemporaryTrees(repo);
  console.log('PASS preparation failure preservation and activation rollback');

  // Directory junctions are available on Windows without symlink privileges.
  const outside=path.join(scratch,'outside');fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'sentinel.txt'),'fictional external sentinel');
  const linked=path.join(scratch,'linked');copySource(linked);
  fs.symlinkSync(outside,path.join(linked,'native-ios','Web'),'junction');
  const linkedWeb=run(linked);assert.notEqual(linkedWeb.status,0);assert.match(linkedWeb.stderr,/Refusing linked iOS build path/);
  assert.equal(fs.readFileSync(path.join(outside,'sentinel.txt'),'utf8'),'fictional external sentinel');
  assert.deepEqual(fs.readdirSync(outside),['sentinel.txt']);
  const linkedAncestor=path.join(scratch,'linked-ancestor');fs.mkdirSync(linkedAncestor);
  fs.mkdirSync(path.join(linkedAncestor,'_tools'));fs.copyFileSync(path.join(root,'_tools','build-ios.js'),path.join(linkedAncestor,'_tools','build-ios.js'));
  fs.symlinkSync(path.join(repo,'native-ios'),path.join(linkedAncestor,'native-ios'),'junction');
  const ancestor=run(linkedAncestor);assert.notEqual(ancestor.status,0);assert.match(ancestor.stderr,/Refusing linked iOS build path/);
  assert.deepEqual(snapshot(web),expected,'A linked ancestor must not mutate its destination');
  console.log('PASS linked Web/ancestor rejection and external destination preservation');
}finally{
  const resolved=path.resolve(scratch);
  assert.equal(path.dirname(resolved),path.resolve(os.tmpdir()));assert(path.basename(resolved).startsWith('kcal-ios-packaging-'));
  fs.rmSync(resolved,{recursive:true,force:true});
}

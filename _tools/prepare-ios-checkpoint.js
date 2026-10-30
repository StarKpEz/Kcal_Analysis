// Local, allowlisted source transfer only. No Git mutation, network or signing.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const root=path.resolve(__dirname,'..');
const files=[
  '.gitattributes','.gitignore','AGENTS.md','index.html','app.css','navigation.js','sw.js','manifest.webmanifest','icons/icon-512-v3.png',
  '_tools/build-ios.js','_tools/test-ios.js','_tools/test-ios-packaging.js','_tools/prepare-ios-checkpoint.js','_tools/test-ios-checkpoint.js',
  '_tools/build-native-domain.js','_tools/test-native-domain.js','_tools/test-native-project.js',
  'native-ios/README.md','native-ios/FIRST-MAC-BUILD.md','native-ios/project.yml',
  'native-ios/scripts/build-unsigned.sh','native-ios/scripts/preflight.sh','native-ios/ci/ios-unsigned.yml',
  'native-ios/scripts/simulator-tests.sh','native-ios/scripts/prepare-project.sh',
  'native-ios/App/AppDelegate.swift','native-ios/App/SceneDelegate.swift','native-ios/App/WebViewController.swift',
  'native-ios/App/NativeBridge.swift','native-ios/App/SnapshotStore.swift','native-ios/App/HealthKitService.swift',
  'native-ios/App/NativeTabBar.swift','native-ios/App/ExternalAppLauncher.swift',
  'native-ios/App/NativeAppModel.swift','native-ios/App/NativeDomain.swift','native-ios/App/NativeRootView.swift',
  'native-ios/App/NativeFoodViews.swift','native-ios/App/NativeSettingsView.swift','native-ios/App/NativeHealthViews.swift','native-ios/App/NativeHealthSync.swift',
  'native-ios/App/NativeHealthAutoSync.swift',
  'native-ios/domain/adapter.js','native-ios/SWIFTUI-MIGRATION.md',
  'native-ios/Tests/NativeDomainTests.swift','native-ios/Tests/NativeHealthSyncTests.swift','native-ios/Tests/NativeHealthViewTests.swift',
  'native-ios/UITests/NativeAppUITests.swift',
  'native-ios/Tests/NativeBridgeIntegrationTests.swift','native-ios/Tests/ExternalAppLauncherTests.swift',
  'native-ios/App/Info.plist','native-ios/App/KcalAnalysis.entitlements','native-ios/App/PrivacyInfo.xcprivacy',
  'native-ios/App/Assets.xcassets/Contents.json','native-ios/App/Assets.xcassets/AppIcon.appiconset/Contents.json',
  'native-ios/bridge/native-platform.js','native-ios/bridge/native-health.js','native-ios/bridge/native-app.js','native-ios/bridge/native-navigation.js','native-ios/bridge/native.css',
  'native-ios/fixtures/synthetic-backup-v7.json',
  'docs/health-import-example.json','docs/health-samples-example.json','docs/health-energy-example.json',
  'docs/健康数据导入格式.md','docs/shortcuts-guide.html','docs/energy-shortcuts-guide.html',
  'docs/energy-single-day-guide.html','docs/能量导出步骤与接续-2026-10-12.md'
].sort();
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');
function regularFile(base,file){
  const full=path.resolve(base,file);
  if(!full.startsWith(base+path.sep))throw new Error('Path outside source root: '+file);
  for(let current=full;current!==path.dirname(base);current=path.dirname(current)){
    if(fs.lstatSync(current).isSymbolicLink())throw new Error('Linked source/output path: '+file);
    if(current===base)break;
  }
  if(!fs.lstatSync(full).isFile())throw new Error('Not a regular source file: '+file);
  return full;
}
function verify(base){
  const manifest=JSON.parse(fs.readFileSync(regularFile(base,'ios-checkpoint.json'),'utf8'));
  if(manifest.format!==1||JSON.stringify(Object.keys(manifest.files).sort())!==JSON.stringify(files))throw new Error('Checkpoint file allowlist mismatch');
  for(const [file,expected] of Object.entries(manifest.files)){
    if(hash(fs.readFileSync(regularFile(base,file)))!==expected)throw new Error('Checkpoint checksum mismatch: '+file);
  }
  if(fs.existsSync(path.join(base,'.github','workflows')))throw new Error('Transfer checkpoint must not activate workflows');
  const generatedDirectories=new Set(['native-ios/Web','native-ios/build','native-ios/KcalAnalysis.xcodeproj','native-ios/KcalAnalysis.xcworkspace']);
  const generatedIcon='native-ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png';
  const generatedFiles=new Set([generatedIcon,'native-ios/domain/domain.js','native-ios/domain/manifest.json']);
  const actual=[];
  function inventory(relative=''){
    for(const entry of fs.readdirSync(path.join(base,relative),{withFileTypes:true})){
      const file=relative?relative+'/'+entry.name:entry.name;
      if(entry.isSymbolicLink())throw new Error('Linked checkpoint path: '+file);
      if(generatedDirectories.has(file)){
        if(!entry.isDirectory())throw new Error('Generated output must be a directory: '+file);
        continue;
      }
      if(entry.isDirectory())inventory(file);
      else if(!generatedFiles.has(file))actual.push(file);
    }
  }
  inventory();
  if(JSON.stringify(actual.sort())!==JSON.stringify([...files,'ios-checkpoint.json'].sort()))throw new Error('Checkpoint contains unexpected source files');
  console.log('PASS checkpoint checksums/inventory: '+files.length+' allowlisted source files; no active workflow');
  return manifest;
}
function prepare(){
  const git=args=>cp.execFileSync('git',args,{cwd:root,encoding:'utf8'}).trim();
  const inputs=new Map(files.map(file=>[file,fs.readFileSync(regularFile(root,file))]));
  for(const file of files.filter(file=>file.endsWith('.sh'))){
    if(inputs.get(file).includes(13))throw new Error('Shell entry point must use LF: '+file);
  }
  const checksums=Object.fromEntries([...inputs].map(([file,data])=>[file,hash(data)]));
  const id=hash(JSON.stringify(checksums)).slice(0,12);
  const build=path.join(root,'native-ios','build');
  // Validate every existing ancestor before creating the ignored local checkpoint.
  for(let current=build;current!==root;current=path.dirname(current)){
    if(fs.existsSync(current)&&fs.lstatSync(current).isSymbolicLink())throw new Error('Linked checkpoint parent: '+current);
  }
  fs.mkdirSync(build,{recursive:true});
  const destination=fs.mkdtempSync(path.join(build,'checkpoint-'+id+'-'));
  for(const [file,data] of inputs){
    const target=path.join(destination,file);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,data,{flag:'wx'});
  }
  const html=inputs.get('index.html').toString(),sw=inputs.get('sw.js').toString(),project=inputs.get('native-ios/project.yml').toString();
  const manifest={format:1,sourceId:id,createdAt:new Date().toISOString(),
    git:{branch:git(['branch','--show-current']),head:git(['rev-parse','HEAD']),uncommitted:true},
    pwa:{appVersion:html.match(/const APP_VERSION = '([^']+)'/)[1],cache:sw.match(/const CACHE = '([^']+)'/)[1]},
    native:{version:project.match(/MARKETING_VERSION: "([^"]+)"/)[1],build:project.match(/CURRENT_PROJECT_VERSION: "([^"]+)"/)[1],compiled:false},
    data:'Fictional acceptance backup only; no PWA/browser or phone storage read.',files:checksums};
  fs.writeFileSync(path.join(destination,'ios-checkpoint.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
  verify(destination);
  console.log('Local iOS source checkpoint: '+destination);
  console.log('Copy this folder to macOS, then follow native-ios/FIRST-MAC-BUILD.md. No commit, upload or build was triggered.');
  return destination;
}
if(require.main===module){
  try{
    if(process.argv.length===3&&process.argv[2]==='--verify')verify(root);
    else if(process.argv.length===2)prepare();
    else throw new Error('Usage: node _tools/prepare-ios-checkpoint.js [--verify]');
  }catch(error){console.error(error.message);process.exitCode=1;}
}
module.exports={files,prepare,verify};

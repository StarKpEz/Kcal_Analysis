// Check transfer completeness and fail-closed verification using fictional data.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),cp=require('node:child_process');
const {files,prepare,verify}=require('./prepare-ios-checkpoint');
const directory=prepare(),manifest=verify(directory);
function inventory(base,relative=''){
  return fs.readdirSync(path.join(base,relative),{withFileTypes:true}).flatMap(entry=>{
    const file=relative+entry.name;
    return entry.isDirectory()?inventory(base,file+'/'):[file];
  }).sort();
}
assert.deepEqual(inventory(directory),[...files,'ios-checkpoint.json'].sort());
assert.equal(manifest.native.compiled,false);
assert.equal(JSON.parse(fs.readFileSync(path.join(directory,'native-ios/fixtures/synthetic-backup-v7.json'),'utf8')).version,7);
const extra=path.join(directory,'native-ios/App/Extra.swift');
fs.writeFileSync(extra,'// Fictional unexpected source\n');
try{assert.throws(()=>verify(directory),/unexpected source files/);}
finally{fs.unlinkSync(extra);}
const fixture=path.join(directory,'native-ios/fixtures/synthetic-backup-v7.json'),original=fs.readFileSync(fixture);
try{
  fs.appendFileSync(fixture,' ');
  assert.throws(()=>verify(directory),/checksum mismatch/);
}finally{fs.writeFileSync(fixture,original);}
const workflow=path.join(directory,'.github','workflows');fs.mkdirSync(workflow,{recursive:true});
try{assert.throws(()=>verify(directory),/must not activate workflows/);}
finally{fs.rmdirSync(workflow);fs.rmdirSync(path.dirname(workflow));}
const manifestPath=path.join(directory,'ios-checkpoint.json'),rawManifest=fs.readFileSync(manifestPath);
try{
  fs.writeFileSync(manifestPath,JSON.stringify({...manifest,files:{...manifest.files,'../outside':'invalid'}}));
  assert.throws(()=>verify(directory),/allowlist mismatch/);
}finally{fs.writeFileSync(manifestPath,rawManifest);}
verify(directory);
// Execute the actual preparation checks from the copy, not from the working
// repository: a matching allowlist alone cannot reveal a missing dependency.
for(const script of ['_tools/test-native-domain.js','_tools/test-native-project.js']) {
  cp.execFileSync(process.execPath,[script],{cwd:directory,encoding:'utf8'});
}
verify(directory);
console.log('PASS standalone native checks, complete transfer, extra-source rejection, source tamper detection, manifest path rejection and inactive-CI guard');

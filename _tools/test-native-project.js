// Source/package audit on Windows. This is not a Swift compiler or UI renderer.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const project=read('native-ios/project.yml');
const appSources=project.slice(project.indexOf('    sources:'),project.indexOf('    settings:',project.indexOf('    sources:')));
const excluded=[...appSources.matchAll(/^          - (.+\.swift)$/gm)].map(match=>match[1]);
const sources=fs.readdirSync(path.join(root,'native-ios/App')).filter(file=>file.endsWith('.swift')&&!excluded.includes(file));
assert(sources.includes('NativeRootView.swift')&&sources.includes('NativeHealthSync.swift'));
for(const file of sources) {
  const code=read('native-ios/App/'+file);
  assert(!/\b(?:import WebKit|WKWebView|evaluateJavaScript)\b/.test(code),'Web interface still compiled: '+file);
}
assert(/UIHostingController\(rootView: root\)/.test(read('native-ios/App/SceneDelegate.swift')));
assert(!/- path: Web\b/.test(appSources));
assert(/- path: domain\/domain\.js\s+buildPhase: resources/.test(appSources));
assert(!appSources.includes('fixtures'));
assert(project.includes('sdk: JavaScriptCore.framework'));
assert(project.includes('KcalAnalysisUITests: [test]'));
const swiftUITests=read('native-ios/UITests/NativeAppUITests.swift');
assert(swiftUITests.includes('KCAL_UI_TESTING')&&swiftUITests.includes('app.webViews.count'));
const {buildNativeDomain}=require('./build-native-domain');
const {manifest,code}=buildNativeDomain();
assert.equal(manifest.sections.length,11);
assert(!/\b(?:document|window|navigator|localStorage|fetch|XMLHttpRequest|WebSocket|WKWebView)\b/.test(code));
for(const file of ['prepare-project.sh','simulator-tests.sh','build-unsigned.sh','preflight.sh']) {
  const bytes=fs.readFileSync(path.join(root,'native-ios/scripts',file));
  assert(!bytes.includes(13),'Bash script contains CRLF: '+file);
}
const build=read('native-ios/scripts/build-unsigned.sh');
assert(build.indexOf('scripts/simulator-tests.sh')<build.indexOf('  build\n'),'Simulator gate must run before Release package');
assert(build.includes('"$app_path/domain.js"')&&build.includes('-e "$app_path/Web"'));
const version=project.match(/MARKETING_VERSION: "([^"]+)"/)[1],number=project.match(/CURRENT_PROJECT_VERSION: "([^"]+)"/)[1];
assert(build.includes('== "'+version+'"')&&build.includes('== "'+number+'"'),'Version differs between Xcode and packaging gate');
console.log('PASS SwiftUI-only compiled source inventory ('+sources.length+' Swift files), one offline domain resource, isolated UI tests, LF shell scripts and gated package version '+version+'/'+number);
console.log('Pending: macOS Swift compilation, XCTest/XCUITest execution, native screenshots and signed-device HealthKit.');

#!/bin/bash
# Run hosted XCTest on a fresh, empty iPhone simulator. No Apple account, real
# iPhone, existing simulator app data, or signing credentials are involved.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
native_root="$repo_root/native-ios"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_root="$native_root/build/simulator-runs/$run_id"
simulator_id=""
simulator_created=false
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Hosted iOS XCTest needs macOS + Xcode; Windows bridge checks cannot replace it." >&2
  exit 1
fi
cd "$repo_root"
mkdir -p "$run_root"
exec > >(tee "$run_root/test.log") 2>&1
cleanup() {
  test_status=$?
  trap - EXIT
  # Only this invocation's newly created simulator may be shut down/deleted.
  if [[ "$simulator_created" == true && "$simulator_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || echo "Could not delete temporary simulator $simulator_id" >&2
  fi
  echo "Simulator tests exit: $test_status; evidence: $run_root"
  exit "$test_status"
}
trap cleanup EXIT
bash "$native_root/scripts/preflight.sh"
bash "$native_root/scripts/prepare-project.sh"
xcrun simctl list devices available --json > "$run_root/devices.json"
xcrun simctl list runtimes --json > "$run_root/runtimes.json"
xcrun simctl list devicetypes --json > "$run_root/device-types.json"
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"

# Select installed iOS 26+ that the chosen SDK can test. Reuse only the device
# type/runtime configuration; create an empty simulator instead of its data.
selection="$(node - "$run_root" "$simulator_sdk" <<'NODE'
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [root,sdk]=process.argv.slice(2);
const {devices}=JSON.parse(fs.readFileSync(path.join(root,'devices.json'),'utf8'));
const {runtimes}=JSON.parse(fs.readFileSync(path.join(root,'runtimes.json'),'utf8'));
const {devicetypes}=JSON.parse(fs.readFileSync(path.join(root,'device-types.json'),'utf8'));
assert(devices&&Array.isArray(runtimes)&&Array.isArray(devicetypes),'Unexpected simctl JSON inventory; raw output is retained for diagnosis.');
function deviceType(device){return device.deviceTypeIdentifier||device.deviceType?.identifier||devicetypes.find(type=>type.productFamily==='iPhone'&&type.name===device.name)?.identifier;}
function compare(a,b){
  const left=a.split('.').map(Number),right=b.split('.').map(Number);
  for(let i=0;i<Math.max(left.length,right.length);i++){const delta=(left[i]||0)-(right[i]||0);if(delta)return delta;}
  return 0;
}
const candidates=runtimes.filter(runtime=>runtime.isAvailable&&runtime.identifier.includes('.iOS-')&&compare(runtime.version,'26')>=0&&compare(runtime.version,sdk)<=0)
  .flatMap(runtime=>(devices[runtime.identifier]||[]).filter(device=>device.isAvailable&&/^iPhone\b/.test(device.name)&&deviceType(device))
    .map(device=>({name:device.name,deviceType:deviceType(device),runtime:runtime.identifier,version:runtime.version})));
candidates.sort((a,b)=>compare(b.version,a.version)||a.name.localeCompare(b.name));
assert(candidates.length,'No available iPhone simulator with installed iOS 26+ compatible with SDK '+sdk+'. Install an iOS simulator runtime in Xcode before retrying.');
const selected=candidates[0];
assert(/^com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[A-Za-z0-9.-]+$/.test(selected.deviceType),'Unexpected iPhone device type');
assert(/^com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+$/.test(selected.runtime),'Unexpected iOS runtime identifier');
fs.writeFileSync(path.join(root,'destination.json'),JSON.stringify({...selected,emptySimulator:true,sdk},null,2)+'\n');
process.stdout.write(selected.deviceType+'\t'+selected.runtime);
NODE
)"
IFS=$'\t' read -r device_type runtime_id <<< "$selection"
simulator_id="$(xcrun simctl create "KcalAnalysis-tests-$run_id" "$device_type" "$runtime_id")"
if [[ ! "$simulator_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "simctl did not return a valid temporary simulator UUID." >&2
  exit 1
fi
simulator_created=true
echo "Testing on fresh iPhone simulator: $simulator_id ($runtime_id)"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild \
  -project "$native_root/KcalAnalysis.xcodeproj" \
  -scheme KcalAnalysis \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -destination-timeout 120 \
  -parallel-testing-enabled NO \
  -derivedDataPath "$run_root/DerivedData" \
  -resultBundlePath "$run_root/Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  test
xcrun xcresulttool get test-results summary --path "$run_root/Tests.xcresult" > "$run_root/test-summary.json"
node - "$run_root/test-summary.json" <<'NODE'
const fs=require('node:fs'),assert=require('node:assert/strict');
const summary=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
assert(Number.isInteger(summary.passedTests)&&summary.passedTests>0,'Simulator test gate requires a non-zero passedTests count; inspect the retained raw summary if its schema changed.');
assert.equal(summary.failedTests,0,'Simulator test gate rejects failed XCTest results.');
if(summary.result!=null)assert.equal(summary.result,'Passed','Simulator test session must be Passed.');
console.log('PASS native simulator XCTest: '+summary.passedTests+' tests passed.');
NODE
echo "Simulator XCTest passed. Device installation and HealthKit grants still require iPhone acceptance."

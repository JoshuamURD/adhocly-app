#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adhocly-ui.XXXXXX")"
device=""
cleanup() {
    status=$?
    if [ -n "$device" ]; then
        xcrun simctl shutdown "$device" 2>/dev/null || true
        xcrun simctl delete "$device" 2>/dev/null || true
    fi
    if [ "$status" -eq 0 ] && [ "${KEEP_UI_ARTIFACTS:-0}" != 1 ]; then
        rm -rf "$tmp"
    else
        echo "UI test artifacts: $tmp"
    fi
    exit "$status"
}
trap cleanup EXIT
# A separate app bundle and fresh simulator keep tests away from real tasks, tokens and alerts.
cat > "$tmp/project.yml" <<EOF
name: AdhoclySmoke
options:
  deploymentTarget:
    iOS: "17.0"
packages:
  AdhoclyCore:
    path: "$root"
targets:
  Smoke:
    type: application
    platform: iOS
    sources:
      - path: "$root/App"
        excludes: ["*.plist", "*.entitlements"]
    dependencies:
      - package: AdhoclyCore
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.adhocly.uitestsmoke
      SWIFT_VERSION: "6.0"
      CODE_SIGN_ENTITLEMENTS: "$root/App/Adhocly-iOS.entitlements"
    info:
      path: Smoke.plist
      properties:
        UILaunchScreen: {}
  SmokeUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: ["$root/UITests"]
    dependencies:
      - target: Smoke
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.adhocly.uitestsmoke.tests
      GENERATE_INFOPLIST_FILE: YES
schemes:
  Smoke:
    build:
      targets:
        Smoke: all
    test:
      targets: [SmokeUITests]
EOF
(cd "$tmp" && xcodegen generate)
runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "SimRuntime.iOS-" in r["identifier"]]; print(sorted(r, key=lambda r: tuple(map(int, r["version"].split("."))))[-1]["identifier"])')"
device="$(xcrun simctl create 'Adhocly isolated UI test' "${IOS_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}" "$runtime")"
if ! xcodebuild -project "$tmp/AdhoclySmoke.xcodeproj" -scheme Smoke \
    -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$tmp/build" \
    -resultBundlePath "$tmp/result.xcresult" -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO test "$@" > "$tmp/test.log" 2>&1; then
    tail -100 "$tmp/test.log"
    exit 1
fi
grep -E 'passed|TEST SUCCEEDED' "$tmp/test.log"

#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adhocly-ui.XXXXXX")"
device=""
platform="${UI_PLATFORM:-iOS}"
case "$platform" in
    iOS)
        version="17.0"
        sources="$root/UITests"
        entitlements="$root/App/Adhocly-iOS.entitlements"
        bundle="com.adhocly.uitestsmoke"
        signing=(CODE_SIGNING_ALLOWED=NO)
        ;;
    macOS)
        version="14.0"
        sources="$root/UITests/TaskEditorTests.swift"
        entitlements="$tmp/Smoke.entitlements"
        bundle="com.adhocly.uitestsmoke.$(uuidgen | tr '[:upper:]' '[:lower:]')"
        signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
        # Ad-hoc signing supports a sandbox, but not the provisioned Time Sensitive capability.
        cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
        ;;
    *) echo "UI_PLATFORM must be iOS or macOS" >&2; exit 1 ;;
esac
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
# A fresh simulator or unique sandboxed Mac identity keeps tests away from real tasks and tokens.
cat > "$tmp/project.yml" <<EOF
name: AdhoclySmoke
options:
  deploymentTarget:
    $platform: "$version"
packages:
  AdhoclyCore:
    path: "$root"
targets:
  Smoke:
    type: application
    platform: $platform
    sources:
      - path: "$root/App"
        excludes: ["*.plist", "*.entitlements"]
    dependencies:
      - package: AdhoclyCore
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: $bundle
      SWIFT_VERSION: "6.0"
      CODE_SIGN_ENTITLEMENTS: "$entitlements"
    info:
      path: Smoke.plist
      properties:
        UILaunchScreen: {}
  SmokeUITests:
    type: bundle.ui-testing
    platform: $platform
    sources: ["$sources"]
    dependencies:
      - target: Smoke
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: $bundle.tests
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
if [ "$platform" = iOS ]; then
    runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "SimRuntime.iOS-" in r["identifier"]]; print(sorted(r, key=lambda r: tuple(map(int, r["version"].split("."))))[-1]["identifier"])')"
    device="$(xcrun simctl create 'Adhocly isolated UI test' "${IOS_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}" "$runtime")"
    destination="platform=iOS Simulator,id=$device"
else
    destination="platform=macOS"
fi
if ! xcodebuild -project "$tmp/AdhoclySmoke.xcodeproj" -scheme Smoke \
    -destination "$destination" -derivedDataPath "$tmp/build" \
    -resultBundlePath "$tmp/result.xcresult" -parallel-testing-enabled NO \
    "${signing[@]}" "${UI_ACTION:-test}" "$@" > "$tmp/test.log" 2>&1; then
    tail -100 "$tmp/test.log"
    exit 1
fi
grep -E 'passed|TEST SUCCEEDED|TEST BUILD SUCCEEDED' "$tmp/test.log"

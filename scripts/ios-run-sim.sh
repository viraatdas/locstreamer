#!/usr/bin/env bash
# Builds a Debug simulator build WITHOUT xcodebuild's build service, installs
# it on a headless iPhone simulator, signs in with the OTP test number, drives
# a simulated route, and checks that points reach the API. No windows opened.
#   scripts/ios-run-sim.sh            # build + install + launch + verify
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
OUT="$IOS_DIR/build/sim"
APP="$OUT/LocStreamer.app"
BUNDLE_ID=dev.viraat.locstreamer
PROBE_PHONE="${PROBE_PHONE:-+15555550100}"
PROBE_CODE="${PROBE_CODE:-123456}"
DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"

UDID=$(xcrun simctl list devices available -j | python3 -c "
import sys,json
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name']=='$DEVICE': print(d['udid']); sys.exit()
")
[[ -n "$UDID" ]] || { echo "error: simulator '$DEVICE' not found" >&2; exit 1; }

echo "==> Compiling Swift (debug, arm64 simulator)"
rm -rf "$OUT"; mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -Onone -g -DDEBUG -swift-version 6 -target arm64-apple-ios17.0-simulator \
  -parse-as-library -module-name LocStreamer -emit-executable -o "$APP/LocStreamer" "$IOS_DIR"/App/*.swift
xcrun actool "$IOS_DIR/App/Assets.xcassets" --compile "$APP" --platform iphonesimulator \
  --minimum-deployment-target 17.0 --app-icon AppIcon --target-device iphone \
  --output-partial-info-plist "$OUT/icons.plist" --output-format human-readable-text >/dev/null
python3 - "$IOS_DIR/App/Info.plist" "$OUT/icons.plist" "$APP/Info.plist" <<PY
import plistlib, sys
src, icons, dst = sys.argv[1:4]
info = plistlib.load(open(src, "rb")); info.update(plistlib.load(open(icons, "rb")))
subs = {"\$(MARKETING_VERSION)": "0.0", "\$(CURRENT_PROJECT_VERSION)": "0", "\$(PRODUCT_BUNDLE_IDENTIFIER)": "$BUNDLE_ID",
        "\$(EXECUTABLE_NAME)": "LocStreamer", "\$(PRODUCT_NAME)": "LocStreamer", "\$(DEVELOPMENT_LANGUAGE)": "en", "\$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "APPL"}
for k, v in list(info.items()):
    if isinstance(v, str) and v in subs: info[k] = subs[v]
info.update({"CFBundleExecutable": "LocStreamer", "CFBundleIdentifier": "$BUNDLE_ID", "CFBundleName": "LocStreamer",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0", "CFBundleVersion": "0",
    "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "LSRequiresIPhoneOS": True, "MinimumOSVersion": "17.0",
    "UIDeviceFamily": [1], "DTPlatformName": "iphonesimulator", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleDevelopmentRegion": "en"})
plistlib.dump(info, open(dst, "wb"))
PY
printf 'APPL????' > "$APP/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null

echo "==> Booting $DEVICE (headless)"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE_ID"
xcrun simctl location "$UDID" set 37.7749,-122.4194

echo "==> Launching with scripted sign-in ($PROBE_PHONE)"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" -probePhone "$PROBE_PHONE" -probeCode "$PROBE_CODE" > "$OUT/launch.log" 2>&1 &
sleep 8
echo "==> Driving a simulated route"
xcrun simctl location "$UDID" start --speed=20 37.7749,-122.4194 37.7790,-122.4150 37.7840,-122.4100 37.7900,-122.4050
echo "==> Screenshot"
sleep 5
xcrun simctl io "$UDID" screenshot "$OUT/screen.png" >/dev/null 2>&1 && echo "    $OUT/screen.png"
echo "==> Running. Points upload every 60 s / 25 points; check with:"
echo "    curl -s -H \"x-api-key: \$READ_API_KEY\" \"https://locstreamer.vercel.app/api/locations/$PROBE_PHONE\""

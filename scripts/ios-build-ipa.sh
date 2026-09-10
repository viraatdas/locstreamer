#!/usr/bin/env bash
# Builds a signed App Store .ipa WITHOUT xcodebuild's build service (which can
# hang on this Mac at the `clang -v -E -dM` probe): swiftc + actool + codesign.
# Produces ios/build/LocStreamer.ipa. Needs `fastlane prep_signing` first.
#   scripts/ios-build-ipa.sh            # build + sign
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
OUT="$IOS_DIR/build/manual"
APP="$OUT/Payload/LocStreamer.app"
PROFILE="$IOS_DIR/build/profiles/AppStore_dev.viraat.locstreamer.mobileprovision"
BUNDLE_ID=dev.viraat.locstreamer
TEAM_ID=3C4383262W
IDENTITY="Apple Distribution: Viraat Das ($TEAM_ID)"
MARKETING_VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$IOS_DIR/project.yml")
BUILD_NUMBER=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' "$IOS_DIR/project.yml")
[[ -f "$PROFILE" ]] || { echo "error: run 'cd ios && fastlane prep_signing' first" >&2; exit 1; }

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
SDK_BUILD=$(xcrun --sdk iphoneos --show-sdk-build-version)
XCODE_BUILD=$(xcodebuild -version | sed -n 's/Build version //p')
XCODE_VERSION=$(xcodebuild -version | sed -n 's/Xcode \([0-9]*\)\.\([0-9]*\).*/\1\2/p')0
OS_BUILD=$(sw_vers -buildVersion)

rm -rf "$OUT"; mkdir -p "$APP"
echo "==> Compiling Swift (release, arm64, iOS 17)"
xcrun -sdk iphoneos swiftc -O -swift-version 6 -target arm64-apple-ios17.0 -parse-as-library \
  -module-name LocStreamer -emit-executable -o "$APP/LocStreamer" "$IOS_DIR"/App/*.swift \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks

echo "==> Compiling asset catalog"
xcrun actool "$IOS_DIR/App/Assets.xcassets" --compile "$APP" --platform iphoneos \
  --minimum-deployment-target 17.0 --app-icon AppIcon --target-device iphone \
  --output-partial-info-plist "$OUT/icons.plist" --output-format human-readable-text >/dev/null

echo "==> Writing Info.plist"
python3 - "$IOS_DIR/App/Info.plist" "$OUT/icons.plist" "$APP/Info.plist" <<PY
import plistlib, sys
src, icons, dst = sys.argv[1:4]
info = plistlib.load(open(src, "rb"))
info.update(plistlib.load(open(icons, "rb")))
subs = {"\$(MARKETING_VERSION)": "$MARKETING_VERSION", "\$(CURRENT_PROJECT_VERSION)": "$BUILD_NUMBER",
        "\$(PRODUCT_BUNDLE_IDENTIFIER)": "$BUNDLE_ID", "\$(EXECUTABLE_NAME)": "LocStreamer",
        "\$(PRODUCT_NAME)": "LocStreamer", "\$(DEVELOPMENT_LANGUAGE)": "en", "\$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "APPL"}
for k, v in list(info.items()):
    if isinstance(v, str) and v in subs: info[k] = subs[v]
info.update({
    "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "LocStreamer", "CFBundleIdentifier": "$BUNDLE_ID",
    "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "LocStreamer", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$MARKETING_VERSION", "CFBundleVersion": "$BUILD_NUMBER",
    "CFBundleSupportedPlatforms": ["iPhoneOS"], "LSRequiresIPhoneOS": True, "MinimumOSVersion": "17.0",
    "UIDeviceFamily": [1], "UIRequiredDeviceCapabilities": ["arm64"],
    "DTPlatformName": "iphoneos", "DTPlatformVersion": "$SDK_VERSION", "DTPlatformBuild": "$SDK_BUILD",
    "DTSDKName": "iphoneos$SDK_VERSION", "DTSDKBuild": "$SDK_BUILD", "DTXcode": "$XCODE_VERSION",
    "DTXcodeBuild": "$XCODE_BUILD", "DTCompiler": "com.apple.compilers.llvm.clang.1_0", "BuildMachineOSBuild": "$OS_BUILD",
})
plistlib.dump(info, open(dst, "wb"))
PY
printf 'APPL????' > "$APP/PkgInfo"
cp "$PROFILE" "$APP/embedded.mobileprovision"

echo "==> Signing"
security cms -D -i "$PROFILE" | plutil -extract Entitlements xml1 -o "$OUT/entitlements.plist" -
codesign --force --sign "$IDENTITY" --entitlements "$OUT/entitlements.plist" --timestamp=none "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Packaging"
(cd "$OUT" && rm -f LocStreamer.ipa && ditto -c -k --norsrc --keepParent Payload LocStreamer.ipa)
cp "$OUT/LocStreamer.ipa" "$IOS_DIR/build/LocStreamer.ipa"
echo "==> Built $IOS_DIR/build/LocStreamer.ipa ($MARKETING_VERSION build $BUILD_NUMBER)"

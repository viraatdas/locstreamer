#!/usr/bin/env bash
# Archive, export and upload the iOS app to TestFlight:
#   scripts/ios-testflight.sh            # archive + export + upload
#   scripts/ios-testflight.sh archive    # stop after the signed .ipa
# Signing is manual with the API-key-fetched Distribution cert + App Store
# profile (fastlane prep_signing). The App Store Connect app record must exist.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
BUILD_DIR="$IOS_DIR/build"
ARCHIVE="$BUILD_DIR/LocStreamer.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
# shellcheck disable=SC1091
source "$IOS_DIR/fastlane/.asc.env"
: "${ASC_KEY_ID:?fill ios/fastlane/.asc.env}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}" "${APPLE_TEAM_ID:?}"

SKILL=~/.agent-skills/ios-testflight/scripts
export APP_NAME=LocStreamer
echo "==> App Store Connect: bundle id + app record"
ruby "$SKILL/asc.rb" bootstrap
if ! ruby "$SKILL/asc.rb" app; then
  echo "error: no App Store Connect web session. Run once in your terminal:  fastlane spaceauth -u viraat.laldas@gmail.com" >&2
  exit 3
fi
echo "==> Generating Xcode project"
(cd "$IOS_DIR" && xcodegen generate)
echo "==> Fetching Distribution cert + App Store profile"
(cd "$IOS_DIR" && fastlane prep_signing)
# xcodebuild's build service hangs on this Mac at its clang probe (seen
# 2026-09-09 and 2026-09-10), so the .ipa is produced by driving swiftc,
# actool and codesign directly. Same signed result, no build service.
echo "==> Building signed .ipa"
"$REPO_ROOT/scripts/ios-build-ipa.sh"
[[ "${1:-}" == "archive" ]] && exit 0

echo "==> Uploading to TestFlight"
xcrun altool --upload-app --type ios --file "$BUILD_DIR/LocStreamer.ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "==> Uploaded. Waiting for App Store Connect to process the build"
for i in $(seq 1 40); do
  state=$(ruby "$SKILL/asc.rb" status 2>/dev/null | sed -n 's/.*state=//p' | tail -1)
  echo "    $(date +%H:%M:%S) ${state:-not visible yet}"
  case "$state" in VALID|INVALID|FAILED) break;; esac
  sleep 30
done
ruby "$SKILL/asc.rb" status

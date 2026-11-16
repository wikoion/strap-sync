#!/usr/bin/env bash
# Builds Strap Sync and installs it on the iPhone.
#   scripts/install-app.sh          build + install
#   scripts/install-app.sh --pull       copy the app's logs to secrets/logs/
#   scripts/install-app.sh --pull-raw   copy the raw strap archive to secrets/raw/
# Needs Config/Local.xcconfig (team + bundle ID).
set -euo pipefail
cd "$(dirname "$0")/.."
# Homebrew clang in CC/CXX breaks xcodebuild's C compiles.
unset CC CXX

BUNDLE_ID=$(sed -n 's/^APP_BUNDLE_ID *= *//p' Config/Local.xcconfig)
# Away from the Mac: RoamRun bridges the phone over Tailscale (phone unlocked, on Wi-Fi).
ROAMRUN_DEVICE=${ROAMRUN_DEVICE:-iPhone}
roamrun_ready() { command -v roamrun >/dev/null && roamrun status 2>/dev/null | grep -q "^$ROAMRUN_DEVICE: Ready"; }
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available \(paired\)|connected/ && !/unavailable/ {print $3; exit}')
[[ -n "$DEVICE" ]] || roamrun_ready || { echo "No iPhone available: plug it in, or unlock it with Tailscale on and run 'roamrun up $ROAMRUN_DEVICE'." >&2; exit 1; }

if [[ "${1:-}" == "--pull" || "${1:-}" == "--pull-raw" ]]; then
  [[ "$1" == "--pull" ]] && what=logs || what=raw
  mkdir -p "secrets/$what"
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "Documents/$what" --destination "secrets/$what"
  ls -t "secrets/$what" | head
  exit 0
fi

xcodegen generate --quiet
xcodebuild -project WhoopSync.xcodeproj -scheme WhoopSync -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=build/DerivedData/Build/Products/Debug-iphoneos/WhoopSync.app
[[ -d "$APP" ]] || { echo "build failed" >&2; exit 1; }
if roamrun_ready; then
  roamrun install "$ROAMRUN_DEVICE" "$APP"
else
  xcrun devicectl device install app --device "$DEVICE" "$APP"
fi

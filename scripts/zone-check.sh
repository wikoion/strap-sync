#!/usr/bin/env bash
# The end-to-end check of zoneRedo1 against Apple Health, in a new Simulator that's deleted afterwards: writes made-up
# nights and heart rate through the app's own writer, stamps some with the wrong zone and leaves stale rows in the
# outbox, runs the redo and checks what Health has (App/WhoopSync/Support/ZoneCheck.swift). Nothing touches a phone.
set -euo pipefail
cd "$(dirname "$0")/zone-check"
unset CC CXX
xcodegen generate --quiet
SDK=$(xcrun --sdk iphonesimulator --show-sdk-version | cut -d. -f1)
RUNTIME=$(xcrun simctl list runtimes available | grep -E "^iOS $SDK\." | tail -1 | sed -E 's/.* - (com\.apple[^ ]+).*/\1/')
UDID=$(xcrun simctl create "strapsync-zone-check" "iPhone 16 Pro" "$RUNTIME")
trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; xcrun simctl delete "$UDID"' EXIT
xcodebuild test -project ZoneCheck.xcodeproj -scheme ZoneCheck -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath ../../build/ZoneCheck 2>&1 | grep -E "ZONECHECK|error:|\*\* TEST"

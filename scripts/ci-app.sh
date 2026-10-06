#!/usr/bin/env bash
# Builds the iOS app and runs its tests on the newest available iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((key for key in devices if "iOS" in key), reverse=True)
for runtime in runtimes:
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("no iPhone simulator available")
')
echo "Using simulator $UDID"

xcodebuild test \
  -project Remote.xcodeproj \
  -scheme Remote \
  -destination "id=$UDID" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  | tee xcodebuild.log | grep -E "error:|warning: .*(Sendable|actor)|Test (Suite|Case)|✔|✘|passed|failed|\*\* " || true
test "${PIPESTATUS[0]}" -eq 0

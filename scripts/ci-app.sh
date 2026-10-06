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

set +e
xcodebuild test \
  -project Remote.xcodeproj \
  -scheme Remote \
  -destination "id=$UDID" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  > xcodebuild.log 2>&1
status=$?
set -e

grep -E "error:|Test (Suite|Case)|✔|✘|\*\* (BUILD|TEST)" xcodebuild.log || true
if [ "$status" -ne 0 ]; then
  echo "---- last 150 lines of xcodebuild.log ----"
  tail -150 xcodebuild.log
fi
exit "$status"

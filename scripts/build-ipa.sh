#!/usr/bin/env bash
# Builds an unsigned Release .ipa for sideloading (Sideloadly / AltStore re-sign it
# with your Apple ID). Output: build/Remote.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build/ipa build/Remote.ipa
set +e
xcodebuild build \
  -project Remote.xcodeproj \
  -scheme Remote \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  > build-ipa.log 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
  grep -E "error:" build-ipa.log || tail -100 build-ipa.log
  exit "$status"
fi

mkdir -p build/ipa/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/Remote.app build/ipa/Payload/
(cd build/ipa && zip -qry ../Remote.ipa Payload)
ls -lh build/Remote.ipa

#!/usr/bin/env bash
# Regenerates the Swift protobuf sources for the Android TV driver.
# Needs protoc and protoc-gen-swift:  brew install swift-protobuf
# The output is committed; CI regenerates it and fails if it differs.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Packages/RemoteKit/Sources/RemoteDrivers/AndroidTV/Generated
mkdir -p "$OUT"
protoc \
  --proto_path=Packages/RemoteKit/Protos \
  --swift_out="$OUT" \
  --swift_opt=Visibility=Internal \
  polo.proto remotemessage.proto
echo "Generated: $(ls "$OUT")"

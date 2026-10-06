# Third-party notices

## Vendored files

### androidtvremote2: protobuf schemas
- Files: `Packages/RemoteKit/Protos/polo.proto`, `Packages/RemoteKit/Protos/remotemessage.proto`
  (and the Swift generated from them in `Packages/RemoteKit/Sources/RemoteDrivers/AndroidTV/Generated/`)
- Source: https://github.com/tronikos/androidtvremote2 (`src/androidtvremote2/`)
- License: Apache License 2.0. `polo.proto` is itself derived from Google's
  google-tv-pairing-protocol (Copyright 2009 Google Inc., Apache-2.0), and
  `remotemessage.proto` from https://github.com/louis49/androidtv-remote.
- Changes: a two-line attribution header was added. The schemas are otherwise unmodified.

## Dependencies (Swift Package Manager)

| Package | License |
|---|---|
| [apple/swift-protobuf](https://github.com/apple/swift-protobuf) | Apache-2.0 |
| [apple/swift-certificates](https://github.com/apple/swift-certificates) | Apache-2.0 |
| [apple/swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) (via swift-certificates) | Apache-2.0 |

## Protocol references (no code copied)

The drivers are reimplemented in Swift from an understanding of each protocol. These
projects were read as references:

| Project | Used for | License |
|---|---|---|
| [androidtvremote2](https://github.com/tronikos/androidtvremote2) | Android TV Remote v2 pairing and messages; fixtures are captured by running it | Apache-2.0 |
| Roku External Control Protocol documentation (developer.roku.com) | Roku ECP | n/a |
| [pyatv](https://github.com/postlund/pyatv) | Apple TV Companion protocol (Phase 4) | MIT |
| [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) | Samsung Tizen (Phase 2) | LGPL-3.0, reference only; no code is copied |
| [aiowebostv](https://github.com/home-assistant-libs/aiowebostv) | LG webOS (Phase 2) | Apache-2.0 |

The Apache License 2.0 text is available at https://www.apache.org/licenses/LICENSE-2.0.

# Echo Music for macOS Blueprint

[![CI/CD Pipeline](https://github.com/iamknownstranger/echo-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/iamknownstranger/echo-macos/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/iamknownstranger/echo-macos?label=Release&color=blue)](https://github.com/iamknownstranger/echo-macos/releases)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-black.svg)](https://github.com/iamknownstranger/echo-macos)
[![License](https://img.shields.io/github/license/iamknownstranger/echo-macos)](./LICENSE)

## System Overview

Play YouTube Music, import local audio, and host or join a Listen Together room with Echo on Android. The native SwiftUI app runs on Apple silicon Macs with macOS 14 or later.

This standalone checkout contains the Mac source, tests, license, and artwork from Echo commit `f5f317f`. Cross-platform changes are developed in the Echo repository, which also contains the matching Android client. [Echo source commit](https://github.com/iamknownstranger/echo/commit/f5f317faa894b73e747cb49411cb63854ba491a0) · [Provider and feature roadmap](./macos/ROADMAP.md) · [License](./LICENSE)

## Subdirectories & System Boundaries

- [macos](./macos/README.md): Swift package workspace root containing build tooling, test suites, and subpackages:
  - [Sources](./macos/Sources/README.md): Swift package targets:
    - [CZlib](./macos/Sources/CZlib/README.md): Clang system library bridge exposing macOS system `zlib` to Swift.
    - [EchoMusic](./macos/Sources/EchoMusic/README.md): Core native SwiftUI application, AVPlayer playback engine, InnerTube catalog parser, local library persistence, and Listen Together WebSocket synchronization.

## Build and Run

Install Xcode or the Command Line Tools with Swift 6. From the root of this repository, run the following commands:

```sh
./macos/test.sh
./macos/build.sh
open "macos/build/Echo Music.app"
```

The build also writes `macos/build/Echo-Music-arm64.zip` and signs the app locally with an ad-hoc signature.

## Pair with Android

Open **Listen Together** on the Mac and **Together** on Android. Select the same room server on both devices. Create a room on either device, enter its eight-character code on the other, and approve the listener on the host. Play, pause, change tracks, or seek from the host. Detailed usage instructions can be found in the [Mac guide](./macos/README.md).

## Global Invariants

- YouTube video IDs must be exactly 11 ASCII characters matching `[A-Za-z0-9_-]` [EchoMusic/Models.swift:SongLink.validID]
- Room codes must be exactly 8 ASCII alphanumeric characters [EchoMusic/ListenTogetherView.swift:RoomInvite.isRoomCode]
- Decompressed gzip payload in room wire protocol must not exceed 2MB (2,097,152 bytes) [EchoMusic/RoomWire.swift:RoomWire.gunzip]
- Playback rate micro-adjustments are bounded by multiplier `1 + min(max(error / 2, -0.025), 0.025)` and active only when `abs(error) < 0.180` seconds [EchoMusic/RoomPlayback.swift:RoomPlayback.align]
- Playhead alignment tolerance is dynamically calculated as `min(0.08, 0.012 + Double(session?.oneWayMillis() ?? 0) / 2000)` [EchoMusic/RoomPlayback.swift:RoomPlayback.align]
- Inbound `sync_playback` actions matching `action.originUserId == userId` or matching a recently published local action within 3 seconds are discarded to prevent echo feedback loops [EchoMusic/RoomSession.swift:RoomSession.handle]
- Playhead anchor position is clamped to non-negative: `max(0, position)` and elapsed seconds clamped to positive finite track duration [EchoMusic/RoomPlayback.swift:RoomPlayheadAnchor.init, EchoMusic/RoomPlayback.swift:RoomPlayheadAnchor.seconds]
- WebSocket connections require URL scheme `ws` or `wss` with non-nil host [EchoMusic/RoomSession.swift:RoomSession.connect]
- Connection retry count is capped at 15 with exponential backoff delay capped at 120 seconds [EchoMusic/RoomSession.swift:RoomSession.disconnected]
- Room playback readiness requires `engine.currentItem?.status == .readyToPlay`, `loading == false`, and `failure == nil` [EchoMusic/Player.swift:Player.roomReady]
- Audio file downloads and local audio imports require playable media with non-empty audio tracks [EchoMusic/Library.swift:Library.download, EchoMusic/Library.swift:LocalAudio.read]
- AudioDownload requires `byteCount > 0`, successful destination file creation, HTTP 200 or HTTP 206 chunk range verification, and written file offset matching byteCount [EchoMusic/AudioDownload.swift:AudioDownload.write]
- Library mutations are rejected (`guard canWrite else { return false }`) if the library JSON file failed to load on launch [EchoMusic/Library.swift:Library.update]

## Global Side Effects

- **Audio Playback & System Controls**: Renders audio streams through AVPlayer, binds volume controls, and registers playback notifications with `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.
- **External Network Services**: Executes HTTP POST requests to YouTube Music InnerTube endpoints, queries LRCLIB for synchronized LRC lyrics via HTTP GET, and streams audio media chunks over URLSession.
- **Listen Together Relay Protocol**: Manages full-duplex WebSocket connections to relay servers, exchanging Protobuf/JSON frames, performing continuous clock synchronization ping probes, and handling room join/leave/buffer states.
- **Local Persistence & Filesystem**: Persists application state atomically to `~/Library/Application Support/Echo Music/library.json`, downloads offline audio streams into `Downloads/`, and writes cached album artwork to `Caches/Echo Music/Artwork/<sha256>`.
- **macOS System Integration**: Writes invite codes and share URLs to system pasteboard (`NSPasteboard.general`) and reveals imported local tracks in Finder via `NSWorkspace.shared.activateFileViewerSelecting`.

## System Verification

Run from the repository root:

```sh
./macos/test.sh
```

For live network tests or room integration tests:

```sh
ECHO_LIVE_TESTS=1 ./macos/test.sh
ECHO_ROOM_TEST_URL=ws://127.0.0.1:8080/ws ./macos/test.sh --filter roomPlaybackThroughMetroserver
```

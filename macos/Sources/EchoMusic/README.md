# EchoMusic

## Overview
Core application logic and native SwiftUI interface for Echo Music on macOS. Implements local and remote audio playback (AVPlayer), YouTube Music catalog browsing and streaming extraction, local audio library management, synced lyrics parsing via LRCLIB, and real-time Listen Together room synchronization over WebSocket (Protobuf/JSON with clock sync and drift correction).

## Interface
- Models & Types:
  - `struct Track: Identifiable, Codable, Hashable` [Models.swift:Track]
  - `enum Source: Codable, Hashable` [Models.swift:Source]
  - `struct MusicCollection: Identifiable, Hashable` [Models.swift:MusicCollection]
  - `enum CatalogEntry: Identifiable` [Models.swift:CatalogEntry]
  - `struct Shelf` [Models.swift:Shelf]
  - `struct TrackPage` [Models.swift:TrackPage]
  - `struct EchoError: LocalizedError` [Models.swift:EchoError]
  - `enum SongLink` [Models.swift:SongLink]
  - `func clockText(_ interval: Double) -> String` [Models.swift:clockText]
- Audio Playback Engine:
  - `final class Playhead: ObservableObject` [Player.swift:Playhead]
  - `final class Player: ObservableObject` [Player.swift:Player]
  - `enum AudioDownload` [AudioDownload.swift:AudioDownload]
  - `enum LocalAudio` [Library.swift:LocalAudio]
- Catalog & Discovery:
  - `actor Catalog` [Catalog.swift:Catalog]
  - `enum CatalogParser` [Catalog.swift:CatalogParser]
  - `final class BrowseModel: ObservableObject` [BrowseModel.swift:BrowseModel]
  - `enum Lyrics` [Lyrics.swift:Lyrics]
- Library & Persistence:
  - `final class Library: ObservableObject` [Library.swift:Library]
  - `struct Playlist: Codable, Identifiable` [Library.swift:Playlist]
  - `struct LibraryData: Codable` [Library.swift:LibraryData]
- Listen Together Room Networking:
  - `final class RoomSession: ObservableObject` [RoomSession.swift:RoomSession]
  - `final class RoomPlayback` [RoomPlayback.swift:RoomPlayback]
  - `enum RoomWire` [RoomWire.swift:RoomWire]
  - `struct RoomState` [RoomSession.swift:RoomState]
  - `struct RoomTrack` [RoomSession.swift:RoomTrack]
  - `struct RoomUser` [RoomSession.swift:RoomUser]
  - `struct RoomAction` [RoomSession.swift:RoomAction]
  - `enum RoomRole` [RoomSession.swift:RoomRole]
  - `enum RoomConnection` [RoomSession.swift:RoomConnection]
  - `struct RoomPlayheadAnchor` [RoomPlayback.swift:RoomPlayheadAnchor]
  - `struct BufferedRoomPlayback` [RoomPlayback.swift:BufferedRoomPlayback]
- User Interface & Views:
  - `struct EchoApp: App` [EchoApp.swift:EchoApp]
  - `struct Workspace: View` [Workspace.swift:Workspace]
  - `struct ListenTogetherView: View` [ListenTogetherView.swift:ListenTogetherView]
  - `enum AudioPicker` [EchoApp.swift:AudioPicker]
  - `Cover`, `CoverCard`, `LoadingShelf`, `Notice`, `SongMenu`, `TrackRows`, `Transport`, `Scrubber`, `InspectorView`, `SyncedLyrics` [MusicViews.swift]

## Invariants
- YouTube video IDs must be exactly 11 ASCII characters matching `[A-Za-z0-9_-]` [Models.swift:SongLink.validID]
- Room codes must be exactly 8 ASCII alphanumeric characters [ListenTogetherView.swift:RoomInvite.isRoomCode]
- Decompressed gzip payload in RoomWire must not exceed 2MB (2,097,152 bytes) [RoomWire.swift:RoomWire.gunzip]
- Playback rate micro-adjustments are bounded by multiplier `1 + min(max(error / 2, -0.025), 0.025)` and active only when `abs(error) < 0.180` seconds [RoomPlayback.swift:RoomPlayback.align]
- Playhead alignment tolerance is dynamically calculated as `min(0.08, 0.012 + Double(session?.oneWayMillis() ?? 0) / 2000)` [RoomPlayback.swift:RoomPlayback.align]
- Inbound `sync_playback` actions matching `action.originUserId == userId` or matching a recently published local action within 3 seconds are discarded to prevent echo feedback loops [RoomSession.swift:RoomSession.handle]
- Playhead anchor position is clamped to non-negative: `max(0, position)` and elapsed seconds clamped to positive finite track duration [RoomPlayback.swift:RoomPlayheadAnchor.init, RoomPlayback.swift:RoomPlayheadAnchor.seconds]
- WebSocket connection requires URL scheme `ws` or `wss` with non-nil host [RoomSession.swift:RoomSession.connect]
- Connection retry count is capped at 15 with exponential backoff delay capped at 120 seconds [RoomSession.swift:RoomSession.disconnected]
- Room playback readiness requires `engine.currentItem?.status == .readyToPlay`, `loading == false`, and `failure == nil` [Player.swift:Player.roomReady]
- Audio file downloads and local audio imports require playable media with non-empty audio tracks [Library.swift:Library.download, Library.swift:LocalAudio.read]
- AudioDownload requires `byteCount > 0`, successful destination file creation, HTTP 200 or HTTP 206 chunk range verification, and written file offset matching byteCount [AudioDownload.swift:AudioDownload.write]
- Library mutations are rejected (`guard canWrite else { return false }`) if the library JSON file failed to load on launch [Library.swift:Library.update]

## Side Effects
- AVPlayer audio output, volume mutation, time observers, and remote transport commands via `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` [Player.swift:Player]
- Network requests: HTTP POST to YouTube Music InnerTube API [Catalog.swift:Catalog.request], HTTP GET to LRCLIB API [Lyrics.swift:Lyrics.fetch], audio streaming chunk downloads via URLSession [AudioDownload.swift:AudioDownload.write], and WebSocket communication over URLSessionWebSocketTask [RoomSession.swift:RoomSession.connect]
- File system: atomic JSON persistence to `library.json` [Library.swift:Library.update], audio download storage in `Downloads/<id>.m4a` [Library.swift:Library.download], artwork caching in `Caches/Echo Music/Artwork/<sha256>` [Library.swift:LocalAudio.read]
- System clipboard and Finder: write strings to `NSPasteboard.general` [ListenTogetherView.swift, MusicViews.swift], reveal local files via `NSWorkspace.shared.activateFileViewerSelecting` [MusicViews.swift:SongMenu.body]
- Real-time room telemetry: 2-second heartbeat task transmitting host playhead position, and 5-second WebSocket ping sequences [RoomPlayback.swift, RoomSession.swift]

## Verification
- Run: `swift test --package-path ../..` (or `./macos/test.sh` from repository root)

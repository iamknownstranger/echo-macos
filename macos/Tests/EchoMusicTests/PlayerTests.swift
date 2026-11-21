import Foundation
import AVFoundation
import Testing
@testable import EchoMusic

@Suite struct PlayerTests {
    @Test func trackMultiSourceIdentifiers() {
        let yt = Track(source: .youtube("dQw4w9WgXcQ"), title: "Title", artist: "Artist")
        #expect(yt.id == "youtube:dQw4w9WgXcQ")
        #expect(yt.source.isPlayableDirectly == true)

        let sp = Track(source: .spotify("4cOdK2wGLETKBW3PvgPWqT"), title: "Title", artist: "Artist")
        #expect(sp.id == "spotify:4cOdK2wGLETKBW3PvgPWqT")
        #expect(sp.source.isPlayableDirectly == false)

        let ap = Track(source: .apple("1440818817"), title: "Title", artist: "Artist")
        #expect(ap.id == "apple:1440818817")

        let file = Track(source: .file(URL(fileURLWithPath: "/tmp/song.mp3")), title: "Title", artist: "Artist")
        #expect(file.id == "file:///tmp/song.mp3")
        #expect(file.source.isPlayableDirectly == true)
    }

    @MainActor
    @Test func sleepTimerModes() async {
        let timer = SleepTimer()
        #expect(timer.activeMode == .off)
        #expect(timer.remainingSeconds == nil)

        timer.start(mode: .minutes(15))
        #expect(timer.activeMode == .minutes(15))
        #expect(timer.remainingSeconds == 900)

        timer.cancel()
        #expect(timer.activeMode == .off)
        #expect(timer.remainingSeconds == nil)
    }

    @MainActor
    @Test func playerDurationRespectsAuthoritativeMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("TestAudio.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        try audioFile.write(from: buffer)

        let player = Player(systemControls: false)
        // 1. Authoritative duration should not be overwritten by divergent container duration
        let trackWithMeta = Track(source: .file(url), title: "Track With Meta", artist: "Artist", duration: 180.0)
        player.play([trackWithMeta], at: 0)

        let start1 = Date()
        while player.loading && Date().timeIntervalSince(start1) < 5.0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(player.duration == 180.0)
        let endTime = player.playerEngine.currentItem?.forwardPlaybackEndTime.seconds ?? -1
        #expect(abs(endTime - 180.0) < 0.1)

        // 2. Track with nil duration should adopt valid container duration and hydrate queue
        let trackWithoutMeta = Track(source: .file(url), title: "Track Without Meta", artist: "Artist", duration: nil)
        player.play([trackWithoutMeta], at: 0)

        let start2 = Date()
        while player.loading && Date().timeIntervalSince(start2) < 5.0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(player.duration > 1.5 && player.duration < 2.5)
        #expect(player.queue[0].duration != nil)
        #expect(player.queue[0].duration! > 1.5 && player.queue[0].duration! < 2.5)

        player.pause()
    }

    @MainActor
    @Test func videoPlaybackModeSwitching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("TestSong.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        try audioFile.write(from: buffer)

        let player = Player(systemControls: false)
        let track = Track(source: .file(url), title: "Test Song", artist: "Artist", duration: 120.0)
        player.play([track], at: 0)

        let start = Date()
        while player.loading && Date().timeIntervalSince(start) < 5.0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(player.isVideoMode == false)
        await player.switchPlaybackMode(toVideo: true)
        #expect(player.isVideoMode == true)
        await player.switchPlaybackMode(toVideo: false)
        #expect(player.isVideoMode == false)

        player.pause()
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECHO_LIVE_TESTS"] == "1"))
    func liveVideoStreamResolvesHLSWithAudioAndVideoTracks() async throws {
        let stream = try await Catalog.shared.videoStream(for: "i1o1p_DD6TU", title: "Gehra Hua", artist: "Shashwat Sachdev")
        #expect(stream.url.scheme == "https")
        #expect(stream.track.duration != nil)
        
        let item = AVPlayerItem(url: stream.url)
        let player = AVPlayer(playerItem: item)
        player.play()
        let start = Date()
        while item.status == .unknown && Date().timeIntervalSince(start) < 10.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(item.status == .readyToPlay)
        player.pause()
    }
}

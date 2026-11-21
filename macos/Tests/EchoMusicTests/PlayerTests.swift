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
        let player = Player(systemControls: false)
        // Simulate a track clicked from Discover shelf without initial duration
        let track = Track(source: .youtube("i1o1p_DD6TU"), title: "Gehra Hua", artist: "Shashwat Sachdev")
        #expect(track.duration == nil)
        
        player.play([track], at: 0)
        
        // Wait for stream resolution and AVPlayerItem readyToPlay
        let start = Date()
        while (player.loading || player.duration <= 0) && Date().timeIntervalSince(start) < 15.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        #expect(player.loading == false)
        // The authoritative duration is ~362 seconds; AVPlayerItem's timescale bug reports ~724 seconds.
        #expect(player.duration >= 360.0 && player.duration <= 365.0)
        #expect(player.duration < 500.0)
        #expect(player.queue[0].duration != nil)
        #expect(player.queue[0].duration! >= 360.0 && player.queue[0].duration! <= 365.0)
        
        player.pause()
    }
}

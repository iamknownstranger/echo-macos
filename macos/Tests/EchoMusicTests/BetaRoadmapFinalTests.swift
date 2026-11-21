import Foundation
import Testing
@testable import EchoMusic

@Suite struct BetaRoadmapFinalTests {

    @Test func lyricsTranslationPairingAndCJKSupport() {
        let lrc = """
        [00:12.50]夜に駆ける
        [00:12.50]Racing into the night
        [00:18.20]沈むように溶けてゆくように
        [00:18.20]As if sinking, as if melting away
        """
        let lines = Lyrics.parse(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].time == 12.5)
        #expect(lines[0].text == "夜に駆ける")
        #expect(lines[0].translation == "Racing into the night")
        #expect(lines[1].time == 18.2)
        #expect(lines[1].text == "沈むように溶けてゆくように")
        #expect(lines[1].translation == "As if sinking, as if melting away")
    }

    @Test func lyricsHeaderOffsetAndAdjustedTimestamp() {
        let lrc = """
        [offset:500]
        [00:10.00]First beat
        [00:20.00]Second beat
        """
        let lines = Lyrics.parse(lrc)
        #expect(lines.count == 2)
        // 10.0s + 0.5s header offset = 10.5s
        #expect(abs(lines[0].time - 10.5) < 0.001)

        // Library user offset +0.5s and additional header offset
        let adjusted = lines[0].adjustedTimestamp(offset: 0.5, headerOffset: 0.0)
        #expect(abs(adjusted - 11.0) < 0.001)

        // Negative offset clamped to 0
        let negativeAdjusted = lines[0].adjustedTimestamp(offset: -20.0, headerOffset: 0.0)
        #expect(negativeAdjusted == 0.0)
    }

    @Test func lyricsInstrumentalDetection() {
        #expect(Lyrics.isInstrumental("[au: Instrumental]"))
        #expect(Lyrics.isInstrumental("[ti: Song (Instrumental Version)]"))
        #expect(!Lyrics.isInstrumental("Normal lyric row with words"))
    }

    @Test func libraryLyricOffsetPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lib = await MainActor.run { Library(file: file) }
        let trackId = "track_offset_test_123"

        await MainActor.run {
            #expect(lib.lyricOffset(for: trackId) == 0.0)
            lib.updateTrackOffset(id: trackId, offset: 1.5)
            #expect(lib.lyricOffset(for: trackId) == 1.5)
        }

        // Reload from disk to verify persistence
        let reloaded = await MainActor.run { Library(file: file) }
        await MainActor.run {
            #expect(reloaded.lyricOffset(for: trackId) == 1.5)
            // Reset back to 0
            reloaded.updateTrackOffset(id: trackId, offset: 0.0)
            #expect(reloaded.lyricOffset(for: trackId) == 0.0)
        }
    }

    @Test func roomSessionRelayFailoverAndRotation() async {
        let session = await MainActor.run { RoomSession() }

        await MainActor.run {
            #expect(session.serverURL == RoomSession.defaultRelays[0])
            #expect(session.currentRelayIndex == 0)

            // Simulate consecutive connection failures
            session.simulateConnectionDrop()
            #expect(session.consecutiveFailures == 1)
            #expect(session.currentRelayIndex == 0)

            session.simulateConnectionDrop()
            #expect(session.consecutiveFailures == 2)
            #expect(session.currentRelayIndex == 0)

            // On the 3rd failure, failover to secondary relay occurs
            session.simulateConnectionDrop()
            #expect(session.currentRelayIndex == 1)
            #expect(session.serverURL == RoomSession.defaultRelays[1])
            #expect(session.consecutiveFailures == 0)

            // Manual rotation
            session.rotateRelay()
            #expect(session.currentRelayIndex == 2)
            #expect(session.serverURL == RoomSession.defaultRelays[2])

            // Cycles back to primary
            session.rotateRelay()
            #expect(session.currentRelayIndex == 0)
            #expect(session.serverURL == RoomSession.defaultRelays[0])
        }
    }

    @Test func roomSessionExponentialBackoffWithJitter() {
        // Attempt 0: 2^0 = 1.0s
        let delay0 = RoomSession.calculateBackoffDelay(attempt: 0, jitter: 0.2)
        #expect(delay0 == 1.2)

        // Attempt 1: 2^1 = 2.0s
        let delay1 = RoomSession.calculateBackoffDelay(attempt: 1, jitter: 0.1)
        #expect(delay1 == 2.1)

        // Attempt 2: 2^2 = 4.0s
        let delay2 = RoomSession.calculateBackoffDelay(attempt: 2, jitter: 0.0)
        #expect(delay2 == 4.0)

        // Attempt 3: 2^3 = 8.0s
        let delay3 = RoomSession.calculateBackoffDelay(attempt: 3, jitter: 0.3)
        #expect(abs(delay3 - 8.3) < 0.001)

        // Attempt 4+: max 15.0s capped
        let delay4 = RoomSession.calculateBackoffDelay(attempt: 4, jitter: 0.0)
        #expect(delay4 == 15.0)

        let delay10 = RoomSession.calculateBackoffDelay(attempt: 10, jitter: 0.5)
        #expect(delay10 == 15.5)
    }
}

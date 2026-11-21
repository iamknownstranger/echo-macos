import Foundation
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
}

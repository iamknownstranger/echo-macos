import Foundation

@MainActor
final class PlaybackTracker: ObservableObject {
    static let shared = PlaybackTracker()

    @Published private(set) var accumulatedTime: TimeInterval = 0
    @Published private(set) var hasRecordedCurrentTrack = false

    private var lastObservedTime: TimeInterval = 0
    private var currentTrackID: String?
    private var currentTrack: Track?

    init() {}

    func trackDidChange(to track: Track?) {
        accumulatedTime = 0
        lastObservedTime = 0
        hasRecordedCurrentTrack = false
        currentTrack = track
        currentTrackID = track?.id
    }

    func timeDidUpdate(to currentTime: TimeInterval, track: Track, library: Library? = nil) {
        if track.id != currentTrackID {
            trackDidChange(to: track)
        }

        let delta = currentTime - lastObservedTime
        // Only count continuous playback forward progress. Ignore jumps > 1.5s (user seeking forward)
        // and negative jumps (user seeking backward or looping).
        if delta > 0 && delta <= 1.5 {
            accumulatedTime += delta
        }
        lastObservedTime = currentTime

        let duration = track.durationSeconds ?? 180.0
        let threshold = min(30.0, duration / 2.0)

        if accumulatedTime >= threshold && !hasRecordedCurrentTrack {
            hasRecordedCurrentTrack = true
            let lib = library ?? Library.shared
            lib?.recordPlay(track: track)

            Task {
                await Scrobbler.shared.scrobble(track: track, timestamp: Date())
            }
        }
    }

    func resetForTesting() {
        accumulatedTime = 0
        lastObservedTime = 0
        hasRecordedCurrentTrack = false
        currentTrack = nil
        currentTrackID = nil
    }
}

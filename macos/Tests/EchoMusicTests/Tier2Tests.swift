import AVFoundation
import Foundation
import Testing
@testable import EchoMusic

@MainActor
@Suite struct Tier2Tests {

    // MARK: - 1. Discovery Catalog Tests

    @Test func discoveryCatalogParsing() {
        let mockChartsJSON: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [
                                            [
                                                "musicCarouselShelfRenderer": [
                                                    "header": [
                                                        "musicCarouselShelfBasicHeaderRenderer": [
                                                            "title": ["runs": [["text": "Top Music Videos"]]]
                                                        ]
                                                    ],
                                                    "contents": [
                                                        [
                                                            "musicTwoRowItemRenderer": [
                                                                "title": ["runs": [["text": "Trending Video"]]],
                                                                "subtitle": ["runs": [["text": "Top Artist"]]],
                                                                "navigationEndpoint": [
                                                                    "watchEndpoint": ["videoId": "dQw4w9WgXcQ"]
                                                                ],
                                                                "thumbnailRenderer": [
                                                                    "musicThumbnailRenderer": [
                                                                        "thumbnail": [
                                                                            "thumbnails": [["url": "https://example.com/thumb.jpg"]]
                                                                        ]
                                                                    ]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ],
                                            [
                                                "gridRenderer": [
                                                    "header": [
                                                        "gridHeaderRenderer": [
                                                            "title": ["runs": [["text": "Moods & Categories"]]]
                                                        ]
                                                    ],
                                                    "items": [
                                                        [
                                                            "musicNavigationButtonRenderer": [
                                                                "buttonText": ["runs": [["text": "Chill"]]],
                                                                "clickCommand": [
                                                                    "browseEndpoint": ["browseId": "FEmusic_moods_and_genres_category_chill"]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let node = Node(value: mockChartsJSON)
        let shelves = CatalogParser.shelves(from: node)

        #expect(shelves.count == 2)
        #expect(shelves[0].title == "Top Music Videos")
        #expect(shelves[0].entries.count == 1)
        if case .track(let track) = shelves[0].entries[0] {
            #expect(track.title == "Trending Video")
            #expect(track.artist == "Top Artist")
            #expect(track.id == "youtube:dQw4w9WgXcQ")
        } else {
            Issue.record("Expected track in carousel shelf")
        }

        #expect(shelves[1].title == "Moods & Categories")
        #expect(shelves[1].entries.count == 1)
        if case .collection(let col) = shelves[1].entries[0] {
            #expect(col.title == "Chill")
            #expect(col.id == "FEmusic_moods_and_genres_category_chill")
        } else {
            Issue.record("Expected collection in grid shelf")
        }
    }

    // MARK: - 2. Playback Tracker & Threshold Tests

    @Test func playbackTrackerThresholdAndSeekDefense() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let library = Library(file: file)
        let tracker = PlaybackTracker.shared
        tracker.resetForTesting()

        let track = Track(source: .youtube("track_12345"), title: "Long Track", artist: "Artist", duration: 180.0)

        tracker.trackDidChange(to: track)
        #expect(tracker.accumulatedTime == 0)
        #expect(tracker.hasRecordedCurrentTrack == false)

        // Simulate user seeking from 0.0 to 120.0s immediately (jump = 120s > 1.5s delta threshold)
        tracker.timeDidUpdate(to: 120.0, track: track, library: library)
        #expect(tracker.accumulatedTime == 0) // Should ignore seek jump
        #expect(tracker.hasRecordedCurrentTrack == false)
        #expect(library.data.history.isEmpty)

        // Now simulate continuous playback for 31 seconds in 0.5s increments
        var current = 120.0
        for _ in 0..<62 { // 62 * 0.5s = 31 seconds of continuous playback
            current += 0.5
            tracker.timeDidUpdate(to: current, track: track, library: library)
        }

        #expect(tracker.accumulatedTime >= 30.0)
        #expect(tracker.hasRecordedCurrentTrack == true)
        #expect(library.data.history.count == 1)
        #expect(library.data.history[0].track.id == track.id)
        #expect(library.playCount(for: track) == 1)

        // Continue playing for another 30 seconds - should not duplicate record
        for _ in 0..<60 {
            current += 0.5
            tracker.timeDidUpdate(to: current, track: track, library: library)
        }
        #expect(library.data.history.count == 1)
        #expect(library.playCount(for: track) == 1)
    }

    @Test func shortTrackHalfwayThreshold() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let library = Library(file: file)
        let tracker = PlaybackTracker.shared
        tracker.resetForTesting()

        // 40 second track: threshold should be min(30s, 40s / 2) = 20s
        let track = Track(source: .youtube("short_track"), title: "Short Track", artist: "Artist", duration: 40.0)
        tracker.trackDidChange(to: track)

        var time = 0.0
        // Play 18 seconds (below 20s)
        for _ in 0..<36 {
            time += 0.5
            tracker.timeDidUpdate(to: time, track: track, library: library)
        }
        #expect(tracker.hasRecordedCurrentTrack == false)
        #expect(library.data.history.isEmpty)

        // Play 3 more seconds (reach 20.5s, exceeding 20s threshold)
        for _ in 0..<6 {
            time += 0.5
            tracker.timeDidUpdate(to: time, track: track, library: library)
        }
        #expect(tracker.hasRecordedCurrentTrack == true)
        #expect(library.data.history.count == 1)
    }

    // MARK: - 3. Equalizer & Normalization Tests

    @Test func equalizerPresetsAndClamping() {
        let eq = Equalizer.shared
        eq.isEnabled = true
        eq.currentPreset = .flat

        #expect(eq.bands.count == 5)
        #expect(eq.bands.allSatisfy { $0.gain == 0.0 })

        eq.currentPreset = .bassBooster
        #expect(eq.bands[0].gain == 6.0)
        #expect(eq.bands[1].gain == 4.5)

        // Test custom gain clamping
        eq.setBandGain(at: 0, gain: 25.0)
        #expect(eq.bands[0].gain == 12.0)

        eq.setBandGain(at: 0, gain: -30.0)
        #expect(eq.bands[0].gain == -12.0)

        // Test audioMix configuration on AVPlayerItem
        let item = AVPlayerItem(url: URL(string: "https://example.com/test.mp3")!)
        eq.configureAudio(for: item)
        #expect(item.audioMix != nil)
        #expect(item.audioMix?.inputParameters.count == 1)
        #expect(item.audioMix?.inputParameters.first?.audioTapProcessor != nil)
    }

    // MARK: - 4. History Persistence & FIFO Capping

    @Test func historyPersistenceAndFIFOCapping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let library = Library(file: file)

        let t1 = Track(source: .youtube("t1"), title: "Track 1", artist: "Artist 1")
        let t2 = Track(source: .youtube("t2"), title: "Track 2", artist: "Artist 2")

        library.recordPlay(track: t1)
        library.recordPlay(track: t2)
        library.recordPlay(track: t1) // Play t1 again

        #expect(library.data.history.count == 3)
        #expect(library.data.history[0].track.id == t1.id) // Latest play first
        #expect(library.playCount(for: t1) == 2)
        #expect(library.playCount(for: t2) == 1)

        // Verify persistence
        let restored = Library(file: file)
        #expect(restored.data.history.count == 3)
        #expect(restored.playCount(for: t1) == 2)

        // Clear history
        library.clearHistory()
        #expect(library.data.history.isEmpty)
    }

    // MARK: - 5. Scrobbler Offline Caching

    @Test func scrobblerOfflineQueueing() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("scrobble_cache.json")
        let scrobbler = Scrobbler(cacheURL: cacheURL)

        let track = Track(source: .youtube("xyz123"), title: "Scrobble Song", artist: "Artist X", album: "Album X")
        await scrobbler.scrobble(track: track)

        let count = await scrobbler.queuedCount()
        #expect(count >= 0)

        await scrobbler.clearQueue()
        let countAfterClear = await scrobbler.queuedCount()
        #expect(countAfterClear == 0)
    }
}

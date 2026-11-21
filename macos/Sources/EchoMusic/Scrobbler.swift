import Foundation
import Network

struct ScrobblePayload: Codable, Equatable {
    let trackTitle: String
    let artistName: String
    let albumName: String?
    let timestamp: Date

    init(trackTitle: String, artistName: String, albumName: String? = nil, timestamp: Date = Date()) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumName = albumName
        self.timestamp = timestamp
    }
}

actor Scrobbler {
    static let shared = Scrobbler()

    private var queue: [ScrobblePayload] = []
    private var isFlushing = false
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "fun.echomusic.scrobbler.network")
    private var isOnline = true
    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo Music/scrobble_cache.json")
        self.cacheURL = cacheURL ?? defaultURL

        // Load offline cached scrobbles
        if let data = try? Data(contentsOf: self.cacheURL),
           let cached = try? JSONDecoder().decode([ScrobblePayload].self, from: data) {
            self.queue = cached
        }

        // Setup network observer to flush when online
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.networkStateChanged(isSatisfied: path.status == .satisfied)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func networkStateChanged(isSatisfied: Bool) {
        self.isOnline = isSatisfied
        if isSatisfied && !queue.isEmpty {
            Task { await flush() }
        }
    }

    func scrobble(track: Track, timestamp: Date = Date()) {
        let payload = ScrobblePayload(
            trackTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            timestamp: timestamp
        )
        queue.append(payload)
        persistCache()

        if isOnline {
            Task { await flush() }
        }
    }

    func queuedCount() -> Int {
        return queue.count
    }

    func flush() async {
        guard !isFlushing, !queue.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        var remaining: [ScrobblePayload] = []
        for payload in queue {
            do {
                try await submitToLastFM(payload)
            } catch {
                remaining.append(payload)
            }
        }
        queue = remaining
        persistCache()
    }

    private func submitToLastFM(_ payload: ScrobblePayload) async throws {
        if !isOnline {
            throw EchoError("Offline: queued for sync")
        }
    }

    private func persistCache() {
        do {
            let dir = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(queue)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Best effort cache persistence
        }
    }

    func clearQueue() {
        queue.removeAll()
        persistCache()
    }
}

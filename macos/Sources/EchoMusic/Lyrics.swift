import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    var id: UUID
    var time: Double
    var text: String
    var translation: String?

    var timestamp: TimeInterval { time }
    var original: String { text }

    init(time: Double, text: String, translation: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.time = time
        self.text = text
        self.translation = translation
    }

    init(timestamp: TimeInterval, original: String, translation: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.time = timestamp
        self.text = original
        self.translation = translation
    }

    func adjustedTimestamp(offset: Double = 0, headerOffset: Double = 0) -> Double {
        max(0, time + offset + headerOffset)
    }

    static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        abs(lhs.time - rhs.time) < 0.001 && lhs.text == rhs.text && lhs.translation == rhs.translation
    }
}

enum Lyrics: Equatable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound

    static func parse(_ lrc: String) -> [LyricLine] {
        var headerOffsetSeconds: Double = 0
        let offsetRegex = /\[offset:\s*([+-]?\d+)\]/
        if let match = lrc.firstMatch(of: offsetRegex), let ms = Double(match.1) {
            headerOffsetSeconds = ms / 1000.0
        }

        let timeRegex = /\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
        var rawLines: [(time: Double, text: String)] = []

        for row in lrc.components(separatedBy: .newlines) {
            let trimmedRow = row.trimmingCharacters(in: .whitespaces)
            guard !trimmedRow.isEmpty else { continue }

            let stamps = trimmedRow.matches(of: timeRegex)
            guard let last = stamps.last else { continue }
            let text = String(trimmedRow[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)

            for stamp in stamps {
                guard let minutes = Double(stamp.1), let seconds = Double(stamp.2), seconds < 60 else { continue }
                let fraction = stamp.3.flatMap { Double("0." + String($0)) } ?? 0
                let calculatedTime = minutes * 60 + seconds + fraction + headerOffsetSeconds
                rawLines.append((time: calculatedTime, text: text))
            }
        }

        rawLines.sort { $0.time < $1.time }

        // Translation & CJK pairing pass:
        // Detect consecutive lines with identical/near-identical timestamps (delta < 0.05s)
        // and merge them into a single LyricLine with .translation populated.
        var merged: [LyricLine] = []
        var i = 0
        while i < rawLines.count {
            let current = rawLines[i]
            if i + 1 < rawLines.count {
                let next = rawLines[i + 1]
                if abs(current.time - next.time) < 0.05 && current.text != next.text {
                    merged.append(LyricLine(time: current.time, text: current.text, translation: next.text))
                    i += 2
                    continue
                }
            }
            merged.append(LyricLine(time: current.time, text: current.text, translation: nil))
            i += 1
        }

        return merged
    }

    static func isInstrumental(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("[au: instrumental]") ||
               lower.contains("[ti: instrumental]") ||
               lower.contains("[ar: instrumental]") ||
               lower.contains("instrumental version")
    }

    static func fetch(_ track: Track) async throws -> Lyrics {
        let lyrics = try await LyricsEngine.shared.resolveLyrics(for: track)
        if lyrics == .notFound {
            throw EchoError("No lyrics were found for this recording.")
        }
        return lyrics
    }
}

protocol LyricsProvider: Sendable {
    func fetch(track: Track) async throws -> Lyrics
}

struct LRCLibProvider: LyricsProvider {
    init() {}

    func fetch(track: Track) async throws -> Lyrics {
        struct Match: Decodable {
            let duration: Double?
            let instrumental: Bool?
            let syncedLyrics: String?
            let plainLyrics: String?
            let trackName: String
            let artistName: String
        }
        guard !track.artist.isEmpty else { throw EchoError("Artist information is needed to find lyrics.") }
        var parts = URLComponents(string: "https://lrclib.net/api/search")!
        parts.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        guard let url = parts.url else { throw EchoError("Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 3.0)
        req.setValue("EchoMusic-macOS/0.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EchoError("The lyrics service is unavailable.")
        }
        let matches = try JSONDecoder().decode([Match].self, from: data)
        func score(_ match: Match) -> Double {
            let delta = abs((match.duration ?? 0) - (track.duration ?? match.duration ?? 0))
            let namePenalty: Double = match.trackName.caseInsensitiveCompare(track.title) == .orderedSame ? 0 : 20
            let artistPenalty: Double = match.artistName.caseInsensitiveCompare(track.artist) == .orderedSame ? 0 : 10
            return delta + namePenalty + artistPenalty
        }
        for match in matches.sorted(by: { score($0) < score($1) }) {
            if match.instrumental == true { return .instrumental }
            let durationMatches = track.duration.flatMap { expected in match.duration.map { abs(expected - $0) <= 5 } } ?? true
            if let lrc = match.syncedLyrics, durationMatches {
                if Lyrics.isInstrumental(lrc) { return .instrumental }
                let lines = Lyrics.parse(lrc)
                if !lines.isEmpty { return .synced(lines) }
            }
            if let plain = match.plainLyrics, !plain.isEmpty {
                if Lyrics.isInstrumental(plain) { return .instrumental }
                return .plain(plain)
            }
        }
        return .notFound
    }
}

struct PlainFallbackProvider: LyricsProvider {
    init() {}

    func fetch(track: Track) async throws -> Lyrics {
        if track.title.lowercased().contains("instrumental") {
            return .instrumental
        }
        return .notFound
    }
}

actor LyricsEngine {
    static let shared = LyricsEngine()
    private let timeout: TimeInterval
    private let providers: [LyricsProvider]

    init(timeout: TimeInterval = 3.0, providers: [LyricsProvider] = [LRCLibProvider(), PlainFallbackProvider()]) {
        self.timeout = timeout
        self.providers = providers
    }

    func resolveLyrics(for track: Track) async throws -> Lyrics {
        for (index, provider) in providers.enumerated() {
            let result: Lyrics? = await {
                do {
                    return try await withThrowingTaskGroup(of: Lyrics.self) { group in
                        group.addTask { try await provider.fetch(track: track) }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                            throw EchoError("Lyrics provider timed out")
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                } catch {
                    return nil
                }
            }()

            guard let sheet = result, sheet != .notFound else { continue }
            if case .plain = sheet, index < providers.count - 1 {
                continue
            }
            return sheet
        }
        return .notFound
    }
}

import Foundation

enum Source: Codable, Hashable, Equatable {
    case youtube(String)
    case file(URL)
    case spotify(String)
    case apple(String)
    case tidal(String)
    case deezer(String)

    var isPlayableDirectly: Bool {
        switch self {
        case .youtube, .file: return true
        default: return false
        }
    }
}

struct Track: Identifiable, Codable, Hashable, Equatable {
    let source: Source
    var title: String
    var artist: String
    var album: String?
    var artwork: URL?
    var duration: Double?
    var playbackSource: Source?
    var isrc: String?

    var id: String {
        switch source {
        case .youtube(let id): return "youtube:\(id)"
        case .file(let url): return url.absoluteString
        case .spotify(let id): return "spotify:\(id)"
        case .apple(let id): return "apple:\(id)"
        case .tidal(let id): return "tidal:\(id)"
        case .deezer(let id): return "deezer:\(id)"
        }
    }

    var shareURL: URL? {
        switch source {
        case .youtube(let videoID):
            return URL(string: "https://share.echomusic.fun/watch?v=\(videoID)")
        case .spotify(let id):
            return URL(string: "https://open.spotify.com/track/\(id)")
        default:
            return nil
        }
    }

    var durationSeconds: Double? { duration }

    init(
        source: Source,
        title: String,
        artist: String,
        album: String? = nil,
        artwork: URL? = nil,
        duration: Double? = nil,
        playbackSource: Source? = nil,
        isrc: String? = nil
    ) {
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.playbackSource = playbackSource ?? (source.isPlayableDirectly ? source : nil)
        self.isrc = isrc
    }

    enum CodingKeys: String, CodingKey {
        case source, title, artist, album, artwork, duration, playbackSource, isrc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(Source.self, forKey: .source)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        artwork = try container.decodeIfPresent(URL.self, forKey: .artwork)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        playbackSource = try container.decodeIfPresent(Source.self, forKey: .playbackSource) ?? (source.isPlayableDirectly ? source : nil)
        isrc = try container.decodeIfPresent(String.self, forKey: .isrc)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(artwork, forKey: .artwork)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(playbackSource, forKey: .playbackSource)
        try container.encodeIfPresent(isrc, forKey: .isrc)
    }
}

struct Artist: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var thumbnailURL: URL?
    var bio: String?
    var albums: [Album] = []
    var singles: [Track] = []
}

struct Album: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var artist: String
    var coverURL: URL?
    var year: String?
    var trackCount: Int = 0
    var tracks: [Track] = []
}

struct MusicCollection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
}

enum CatalogEntry: Identifiable {
    case track(Track)
    case collection(MusicCollection)

    var id: String {
        switch self {
        case .track(let track): return track.id
        case .collection(let collection): return collection.id
        }
    }
}

struct Shelf {
    let title: String
    let entries: [CatalogEntry]
}

struct TrackPage {
    var tracks: [Track]
    var continuation: String?
}

struct EchoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SongLink {
    static func videoID(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        let id: String?
        switch (parts.scheme?.lowercased(), host) {
        case ("https", "youtu.be") where path.count == 1:
            id = path[0]
        case ("https", "share.echomusic.fun") where path.count == 1 && path[0] != "watch":
            id = path[0]
        case ("https", "youtube.com"), ("https", "www.youtube.com"), ("https", "m.youtube.com"),
             ("https", "music.youtube.com"), ("https", "share.echomusic.fun"):
            guard path == ["watch"] else { return nil }
            id = parts.queryItems?.first { $0.name == "v" }?.value
        case ("echomusic", "watch") where path.isEmpty:
            id = parts.queryItems?.first { $0.name == "v" }?.value
        default: return nil
        }
        return id.flatMap { validID($0) ? $0 : nil }
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

func clockText(_ interval: Double) -> String {
    guard interval.isFinite, interval >= 0, interval < 1e9 else { return "–:––" }
    let seconds = Int(interval)
    if seconds >= 3600 {
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

// MARK: - Spotify Decodables

struct SpotifyTokenResponse: Codable {
    let clientId: String?
    let accessToken: String
    let accessTokenExpirationTimestampMs: Int64
    let isAnonymous: Bool?
}

struct SpotifyTrackResponse: Codable {
    let id: String
    let name: String
    let duration_ms: Int?
    let artists: [SpotifyArtistObj]?
    let album: SpotifyAlbumObj?
    let external_ids: SpotifyExternalIDs?
}

struct SpotifyArtistObj: Codable {
    let id: String?
    let name: String
}

struct SpotifyAlbumObj: Codable {
    let id: String?
    let name: String?
    let images: [SpotifyImageObj]?
}

struct SpotifyImageObj: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

struct SpotifyExternalIDs: Codable {
    let isrc: String?
}

struct SpotifyPlaylistResponse: Codable {
    let id: String
    let name: String
    let description: String?
    let images: [SpotifyImageObj]?
    let tracks: SpotifyPlaylistTracks
}

struct SpotifyPlaylistTracks: Codable {
    let items: [SpotifyPlaylistItem]
}

struct SpotifyPlaylistItem: Codable {
    let track: SpotifyTrackResponse?
}

// MARK: - Odesli Decodables

struct OdesliResponse: Codable {
    let entityUniqueId: String?
    let userCountry: String?
    let pageUrl: String?
    let entitiesByUniqueId: [String: OdesliEntity]?
}

struct OdesliEntity: Codable {
    let id: String
    let type: String?
    let title: String?
    let artistName: String?
    let thumbnailUrl: String?
}

// MARK: - History & Playback Tracking

struct HistoryEntry: Identifiable, Codable, Hashable {
    public var id = UUID()
    public let track: Track
    public let playedAt: Date

    public init(id: UUID = UUID(), track: Track, playedAt: Date = Date()) {
        self.id = id
        self.track = track
        self.playedAt = playedAt
    }
}

// MARK: - Equalizer Models

struct EQBand: Identifiable, Hashable, Codable {
    public var id: Double { frequency }
    public let frequency: Double // in Hz
    public var gain: Double // in dB (-12.0 ... 12.0)

    public var label: String {
        if frequency >= 1000 {
            return String(format: "%.1fk", frequency / 1000.0)
        }
        return "\(Int(frequency))"
    }

    public init(frequency: Double, gain: Double = 0.0) {
        self.frequency = frequency
        self.gain = min(max(gain, -12.0), 12.0)
    }
}

struct EQPreset: Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    public let gains: [Double] // 5 bands: 60Hz, 230Hz, 910Hz, 3.6kHz, 14kHz

    public init(id: String, name: String, gains: [Double]) {
        self.id = id
        self.name = name
        self.gains = gains
    }

    public static let standardFrequencies: [Double] = [60.0, 230.0, 910.0, 3600.0, 14000.0]

    public static let flat = EQPreset(id: "flat", name: "Flat", gains: [0, 0, 0, 0, 0])
    public static let acoustic = EQPreset(id: "acoustic", name: "Acoustic", gains: [4.5, 3.0, 1.5, 3.5, 4.0])
    public static let bassBooster = EQPreset(id: "bass_booster", name: "Bass Booster", gains: [6.0, 4.5, 2.0, 0.5, 0.0])
    public static let bassReducer = EQPreset(id: "bass_reducer", name: "Bass Reducer", gains: [-6.0, -4.5, -2.0, 0.0, 0.0])
    public static let classical = EQPreset(id: "classical", name: "Classical", gains: [4.0, 3.0, 0.0, 2.5, 3.5])
    public static let electronic = EQPreset(id: "electronic", name: "Electronic", gains: [5.0, 4.0, -1.0, 2.0, 4.5])
    public static let hipHop = EQPreset(id: "hiphop", name: "Hip-Hop", gains: [5.5, 4.5, 0.0, 2.0, 3.5])
    public static let jazz = EQPreset(id: "jazz", name: "Jazz", gains: [3.5, 2.0, -1.5, 1.5, 3.5])
    public static let pop = EQPreset(id: "pop", name: "Pop", gains: [-1.5, 2.0, 5.0, 3.0, -1.0])
    public static let rock = EQPreset(id: "rock", name: "Rock", gains: [5.0, 3.0, -1.0, 3.0, 5.0])
    public static let vocalBooster = EQPreset(id: "vocal_booster", name: "Vocal Booster", gains: [-2.0, 1.0, 5.5, 3.5, 1.0])

    public static let allPresets: [EQPreset] = [
        .flat, .acoustic, .bassBooster, .bassReducer, .classical,
        .electronic, .hipHop, .jazz, .pop, .rock, .vocalBooster
    ]
}

// MARK: - Category & Discovery Items

struct CategoryItem: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let thumbnailURL: URL?
    public let browseId: String?
    public let params: String?

    public init(id: String, title: String, subtitle: String? = nil, thumbnailURL: URL? = nil, browseId: String? = nil, params: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.browseId = browseId
        self.params = params
    }
}

import Foundation

actor MultiSourceResolver {
    static let shared = MultiSourceResolver()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves an arbitrary input URL into a Track with a playable backend.
    func resolve(url: URL) async throws -> Track {
        // 1. Direct YouTube link or songlink
        if let videoID = SongLink.videoID(url) {
            let stream = try await Catalog.shared.stream(for: videoID)
            return stream.track
        }

        // 2. Spotify link or URI
        if let spotify = SpotifySource.parse(url: url) {
            switch spotify.type {
            case "track":
                let track = try await SpotifySource.shared.track(id: spotify.id)
                return try await matchToYouTube(track: track)
            default:
                throw EchoError("Unsupported Spotify link type: \(spotify.type)")
            }
        }

        // 3. Apple Music / Tidal / Deezer / other links via Odesli
        return try await resolveViaOdesli(url: url)
    }

    /// Matches an external metadata Track to a playable YouTube track.
    func matchToYouTube(track: Track) async throws -> Track {
        var copy = track

        // 1. If ISRC is available, search by ISRC first
        if let isrc = track.isrc, !isrc.isEmpty {
            let results = try await Catalog.shared.search(isrc)
            if let matched = findBestMatch(tracks: results.tracks, expected: track) {
                copy.playbackSource = matched.source
                return copy
            }
        }

        // 2. Fall back to title + artist search
        let query = "\(track.title) \(track.artist)"
        let searchResults = try await Catalog.shared.search(query)
        if let matched = findBestMatch(tracks: searchResults.tracks, expected: track) {
            copy.playbackSource = matched.source
            return copy
        }

        if let first = searchResults.tracks.first {
            copy.playbackSource = first.source
            return copy
        }

        throw EchoError("Could not find a playable stream for '\(track.title)' by \(track.artist).")
    }

    private func findBestMatch(tracks: [Track], expected: Track) -> Track? {
        guard !tracks.isEmpty else { return nil }

        let cleanExpectedTitle = expected.title.lowercased().filter { $0.isLetter || $0.isNumber }
        let cleanExpectedArtist = expected.artist.lowercased().filter { $0.isLetter || $0.isNumber }

        // Filter by duration tolerance (within 3.5s)
        let durationMatches = tracks.filter { candidate in
            guard let expDur = expected.duration, let candDur = candidate.duration else { return false }
            return abs(candDur - expDur) <= 3.5
        }

        // Prevent YouTube Music ISRC hallucinations: assert candidate title or artist matches expected metadata
        for candidate in durationMatches {
            let candTitle = candidate.title.lowercased().filter { $0.isLetter || $0.isNumber }
            let candArtist = candidate.artist.lowercased().filter { $0.isLetter || $0.isNumber }
            if candTitle.contains(cleanExpectedTitle) || cleanExpectedTitle.contains(candTitle) ||
               candArtist.contains(cleanExpectedArtist) || cleanExpectedArtist.contains(candArtist) {
                return candidate
            }
        }

        // If duration match didn't confirm metadata, fall back to best title match
        for candidate in tracks {
            let candTitle = candidate.title.lowercased().filter { $0.isLetter || $0.isNumber }
            if candTitle == cleanExpectedTitle || candTitle.contains(cleanExpectedTitle) || cleanExpectedTitle.contains(candTitle) {
                return candidate
            }
        }

        return tracks.first
    }

    private func resolveViaOdesli(url: URL) async throws -> Track {
        guard var components = URLComponents(string: "https://api.song.link/v1-alpha.1/links") else {
            throw EchoError("Invalid Odesli API URL")
        }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let requestURL = components.url else { throw EchoError("Invalid Odesli request") }

        let (data, response) = try await session.data(from: requestURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EchoError("Odesli lookup failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let odesli = try JSONDecoder().decode(OdesliResponse.self, from: data)
        guard let uniqueId = odesli.entityUniqueId,
              let entity = odesli.entitiesByUniqueId?[uniqueId] else {
            throw EchoError("Odesli could not find metadata for link")
        }

        let title = entity.title ?? "Unknown Title"
        let artist = entity.artistName ?? "Unknown Artist"
        let artwork = entity.thumbnailUrl.flatMap(URL.init(string:))

        var source: Source = .youtube("")
        let lower = url.absoluteString.lowercased()
        if lower.contains("apple.com") { source = .apple(entity.id) }
        else if lower.contains("tidal.com") { source = .tidal(entity.id) }
        else if lower.contains("deezer.com") { source = .deezer(entity.id) }

        let draft = Track(
            source: source,
            title: title,
            artist: artist,
            artwork: artwork
        )

        return try await matchToYouTube(track: draft)
    }
}

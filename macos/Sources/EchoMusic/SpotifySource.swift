import Foundation

actor SpotifySource {
    static let shared = SpotifySource()

    private var cachedToken: String?
    private var tokenExpiryMs: Int64 = 0
    private var inFlightTokenTask: Task<String, Error>?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches an anonymous web player token with automatic caching, refresh, and concurrent task coalescing.
    func getAccessToken() async throws -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let token = cachedToken, nowMs < (tokenExpiryMs - 60_000) {
            return token
        }

        if let inFlight = inFlightTokenTask {
            return try await inFlight.value
        }

        let task = Task<String, Error> {
            guard let tokenURL = URL(string: "https://open.spotify.com/get_access_token?reason=transport&productType=web_player") else {
                throw EchoError("Invalid Spotify token URL")
            }

            var request = URLRequest(url: tokenURL)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw EchoError("Failed to fetch Spotify anonymous token: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            return tokenResponse.accessToken
        }

        self.inFlightTokenTask = task
        defer { self.inFlightTokenTask = nil }

        let token = try await task.value
        self.cachedToken = token
        self.tokenExpiryMs = nowMs + 3600_000
        return token
    }

    /// Fetches a Spotify track by ID, extracting metadata and ISRC.
    func track(id: String) async throws -> Track {
        let token = try await getAccessToken()
        guard let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)") else {
            throw EchoError("Invalid Spotify track ID: \(id)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EchoError("Spotify track API failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let decoded = try JSONDecoder().decode(SpotifyTrackResponse.self, from: data)
        let artistNames = (decoded.artists ?? []).map(\.name).joined(separator: ", ")
        let artworkURL = decoded.album?.images?.first.flatMap { URL(string: $0.url) }
        let duration = decoded.duration_ms.map { Double($0) / 1000.0 }

        return Track(
            source: .spotify(decoded.id),
            title: decoded.name,
            artist: artistNames.isEmpty ? "Unknown Artist" : artistNames,
            album: decoded.album?.name,
            artwork: artworkURL,
            duration: duration,
            isrc: decoded.external_ids?.isrc
        )
    }

    /// Fetches a Spotify playlist by ID.
    func playlist(id: String) async throws -> (name: String, tracks: [Track]) {
        let token = try await getAccessToken()
        guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(id)?fields=id,name,description,images,tracks.items(track(id,name,duration_ms,artists,album,external_ids))") else {
            throw EchoError("Invalid Spotify playlist ID: \(id)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EchoError("Spotify playlist API failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let decoded = try JSONDecoder().decode(SpotifyPlaylistResponse.self, from: data)
        let tracks: [Track] = decoded.tracks.items.compactMap { item in
            guard let t = item.track, !t.id.isEmpty else { return nil }
            let artistNames = (t.artists ?? []).map(\.name).joined(separator: ", ")
            let artworkURL = t.album?.images?.first.flatMap { URL(string: $0.url) }
            let duration = t.duration_ms.map { Double($0) / 1000.0 }
            return Track(
                source: .spotify(t.id),
                title: t.name,
                artist: artistNames.isEmpty ? "Unknown Artist" : artistNames,
                album: t.album?.name,
                artwork: artworkURL,
                duration: duration,
                isrc: t.external_ids?.isrc
            )
        }
        return (decoded.name, tracks)
    }

    /// Parses Spotify URL or URI into a track or playlist ID.
    static func parse(url: URL) -> (type: String, id: String)? {
        if url.scheme == "spotify" {
            let parts = url.absoluteString.split(separator: ":").map(String.init)
            if parts.count >= 3 {
                return (parts[1], parts[2])
            }
        }
        guard let host = url.host?.lowercased(), host.contains("spotify.com") else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count >= 2 {
            let type = components[0]
            let id = components[1]
            return (type, id)
        }
        return nil
    }
}

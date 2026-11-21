import Foundation

// InnerTube responses mix renderer types in the same lists. Project only the paths
// belonging to the current shelf, so menu actions never become duplicate songs.
struct Node {
    let value: Any?
    subscript(_ key: String) -> Node { Node(value: (value as? [String: Any])?[key]) }
    var nodes: [Node] { (value as? [Any] ?? []).map(Node.init) }
    var string: String? { value as? String }
    var runs: [Node] { self["runs"].nodes }
    var label: String { runs.compactMap { $0["text"].string }.joined() }
    var image: URL? {
        self["musicThumbnailRenderer"]["thumbnail"]["thumbnails"].nodes.last
            .flatMap { $0["url"].string }.flatMap(URL.init(string:))
    }
    var sectionList: [Node] {
        self["tabs"].nodes.first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].nodes ?? []
    }
}

enum CatalogParser {
    static func song(_ row: Node) -> Track? {
        let columns = row["flexColumns"].nodes.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        guard let title = columns.first, !title.label.isEmpty else { return nil }
        let videoID = row["playlistItemData"]["videoId"].string
            ?? title.runs.first?["navigationEndpoint"]["watchEndpoint"]["videoId"].string
            ?? row["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string
        guard let videoID, SongLink.validID(videoID) else { return nil }
        let metadata = Array(columns.dropFirst())
        let artistRuns = metadata.flatMap(\.runs).filter {
            let browse = $0["navigationEndpoint"]["browseEndpoint"]
            return browse["browseId"].string?.hasPrefix("UC") == true ||
                browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string == "MUSIC_PAGE_TYPE_ARTIST"
        }
        let artist = artistRuns.compactMap { $0["text"].string }.joined(separator: ", ")
        let album = metadata.flatMap(\.runs).first { $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string?.hasPrefix("MPRE") == true }?["text"].string
        let fixed = row["fixedColumns"].nodes.map { $0["musicResponsiveListItemFixedColumnRenderer"]["text"] }
        let time = (fixed + metadata).flatMap(\.runs).compactMap { $0["text"].string }.compactMap(duration).first
        let artistFallback = metadata.first?.label.components(separatedBy: " • ").first ?? ""
        return Track(source: .youtube(videoID), title: title.label, artist: artist.isEmpty ? artistFallback : artist,
                     album: album, artwork: row["thumbnail"].image, duration: time)
    }

    private static func duration(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func page(_ shelf: Node) -> TrackPage {
        let contents = shelf["contents"].nodes
        let token = shelf["continuations"].nodes.first?["nextContinuationData"]["continuation"].string
            ?? contents.last?["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string
        return TrackPage(tracks: contents.compactMap { song($0["musicResponsiveListItemRenderer"]) }, continuation: token)
    }

    static func home(_ response: Node) -> [Shelf] {
        let sections = response["contents"]["singleColumnBrowseResultsRenderer"].sectionList
        return sections.compactMap { section in
            let shelf = section["musicCarouselShelfRenderer"]
            let title = shelf["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].label
            var seen = Set<String>()
            let entries: [CatalogEntry] = shelf["contents"].nodes.compactMap { item in
                if let track = song(item["musicResponsiveListItemRenderer"]) { return .track(track) }
                let row = item["musicTwoRowItemRenderer"]
                let name = row["title"].label
                guard !name.isEmpty else { return nil }
                let endpoint = row["navigationEndpoint"]
                let image = row["thumbnailRenderer"].image
                if let id = endpoint["watchEndpoint"]["videoId"].string, SongLink.validID(id) {
                    return .track(Track(source: .youtube(id), title: name, artist: row["subtitle"].label, artwork: image))
                }
                let browse = endpoint["browseEndpoint"]
                guard let id = browse["browseId"].string, id.hasPrefix("VL") || id.hasPrefix("MPRE") else { return nil }
                return .collection(MusicCollection(id: id, title: name, subtitle: row["subtitle"].label, artwork: image))
            }.filter { seen.insert($0.id).inserted }
            return entries.isEmpty ? nil : Shelf(title: title.isEmpty ? "From YouTube Music" : title, entries: entries)
        }
    }
}

actor Catalog {
    static let shared = Catalog()
    private let session: URLSession
    private var visitor: String?
    private let version = "1.20260213.01.00"

    init(session: URLSession = .shared) { self.session = session }

    private func request(_ endpoint: String, body: [String: Any], player: Bool = false) async throws -> Node {
        var url = URLComponents(string: "https://music.youtube.com/youtubei/v1/\(endpoint)")!
        var query = [URLQueryItem(name: "prettyPrint", value: "false")]
        if let continuation = body["continuation"] as? String {
            query.append(URLQueryItem(name: "continuation", value: continuation))
        }
        url.queryItems = query
        var req = URLRequest(url: url.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var client: [String: Any] = [
            "clientName": player ? "VISIONOS" : "WEB_REMIX", "clientVersion": player ? "0.1" : version,
            "hl": Locale.current.language.languageCode?.identifier ?? "en", "gl": Locale.current.region?.identifier ?? "US"
        ]
        if player {
            client.merge(["osName": "visionOS", "osVersion": "1.3.21O771", "deviceMake": "Apple", "deviceModel": "RealityDevice14,1"]) { _, new in new }
        }
        if let visitor {
            client["visitorData"] = visitor
            req.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        req.setValue(player ? "101" : "67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(player ? "0.1" : version, forHTTPHeaderField: "X-YouTube-Client-Version")
        var payload = body
        payload["context"] = ["client": client]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EchoError("YouTube Music could not complete the request. Try again.")
        }
        let root = Node(value: try JSONSerialization.jsonObject(with: data))
        if let value = root["responseContext"]["visitorData"].string { visitor = value }
        return root
    }

    func home() async throws -> [Shelf] {
        let shelves = CatalogParser.home(try await request("browse", body: ["browseId": "FEmusic_home"]))
        guard !shelves.isEmpty else { throw EchoError("Discovery is unavailable. You can still search for a song.") }
        return shelves
    }

    func search(_ text: String, continuation: String? = nil) async throws -> TrackPage {
        if let continuation {
            let res = try await request("search", body: ["continuation": continuation])
            return CatalogParser.page(res["continuationContents"]["musicShelfContinuation"])
        }
        let res = try await request("search", body: ["query": text, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"])
        let shelves = res["contents"]["tabbedSearchResultsRenderer"].sectionList
        guard let shelf = shelves.first(where: { $0["musicShelfRenderer"].value != nil }) else { return TrackPage(tracks: []) }
        return CatalogParser.page(shelf["musicShelfRenderer"])
    }

    func collection(_ id: String, continuation: String? = nil) async throws -> TrackPage {
        if let continuation {
            let root = try await request("browse", body: ["continuation": continuation])
            let legacy = root["continuationContents"]["musicPlaylistShelfContinuation"]
            if legacy.value != nil { return CatalogParser.page(legacy) }
            let items = (root["onResponseReceivedActions"].nodes + root["onResponseReceivedEndpoints"].nodes)
                .map { $0["appendContinuationItemsAction"]["continuationItems"] }.first { $0.value != nil }
            return CatalogParser.page(Node(value: ["contents": items?.value ?? []]))
        }
        let contents = try await request("browse", body: ["browseId": id])["contents"]
        let sections = contents["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]["contents"].nodes
            + contents["singleColumnBrowseResultsRenderer"].sectionList
        for section in sections {
            for key in ["musicPlaylistShelfRenderer", "musicShelfRenderer"] where section[key].value != nil {
                return CatalogParser.page(section[key])
            }
        }
        throw EchoError("The catalog did not return a track list for this collection.")
    }

    struct Stream {
        let url: URL
        let track: Track
        let audioByteCount: Int64?
    }

    func stream(for videoID: String) async throws -> Stream {
        guard SongLink.validID(videoID) else { throw EchoError("This song link is invalid.") }
        if visitor == nil {
            _ = try await request("browse", body: ["browseId": "FEmusic_home"])
        }
        let root = try await request("player", body: ["videoId": videoID], player: true)
        let status = root["playabilityStatus"]
        guard status["status"].string == "OK" else {
            throw EchoError(status["reason"].string ?? "This song is unavailable from YouTube Music.")
        }
        let media = root["streamingData"]
        let formats = media["adaptiveFormats"].nodes.filter {
            $0["mimeType"].string?.hasPrefix("audio/mp4") == true && $0["url"].string != nil
        }.sorted { ($0["bitrate"].value as? Int ?? 0) > ($1["bitrate"].value as? Int ?? 0) }
        let urls = formats.compactMap { $0["url"].string } + [media["hlsManifestUrl"].string].compactMap { $0 }
        guard let url = urls.compactMap(URL.init(string:)).first(where: { $0.scheme == "https" }) else {
            throw EchoError("This song has no stream that the Mac player can open.")
        }
        let meta = root["videoDetails"]
        let track = Track(source: .youtube(videoID), title: meta["title"].string ?? videoID,
                          artist: meta["author"].string ?? "", artwork: meta["thumbnail"]["thumbnails"].nodes.last?["url"].string.flatMap(URL.init(string:)),
                          duration: meta["lengthSeconds"].string.flatMap(Double.init))
        let bytes = formats.first(where: { $0["url"].string == url.absoluteString })?["contentLength"].string.flatMap(Int64.init)
        return Stream(url: url, track: track, audioByteCount: bytes)
    }

    /// Resolves stream for arbitrary Track, dispatching to MultiSourceResolver if needed.
    func stream(for track: Track) async throws -> Stream {
        let effectiveSource = track.playbackSource ?? track.source
        switch effectiveSource {
        case .youtube(let id):
            return try await stream(for: id)
        case .file(let file):
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw EchoError("The file could not be opened: \(file.lastPathComponent)")
            }
            return Stream(url: file, track: track, audioByteCount: nil)
        default:
            let matched = try await MultiSourceResolver.shared.matchToYouTube(track: track)
            if case .youtube(let id) = matched.playbackSource {
                let streamObj = try await stream(for: id)
                var updatedTrack = track
                updatedTrack.playbackSource = .youtube(id)
                if updatedTrack.artwork == nil { updatedTrack.artwork = streamObj.track.artwork }
                if updatedTrack.duration == nil { updatedTrack.duration = streamObj.track.duration }
                return Stream(url: streamObj.url, track: updatedTrack, audioByteCount: streamObj.audioByteCount)
            }
            throw EchoError("Could not resolve playable stream for \(track.title)")
        }
    }

    /// Resolves high-definition video stream for YouTube video ID with macOS AVPlayer / PiP support.
    func videoStream(for videoID: String) async throws -> Stream {
        guard SongLink.validID(videoID) else { throw EchoError("This video link is invalid.") }
        if visitor == nil {
            _ = try await request("browse", body: ["browseId": "FEmusic_home"])
        }
        let root = try await request("player", body: ["videoId": videoID], player: true)
        let status = root["playabilityStatus"]
        guard status["status"].string == "OK" else {
            throw EchoError(status["reason"].string ?? "This video is unavailable from YouTube.")
        }
        let media = root["streamingData"]
        let allFormats = media["formats"].nodes + media["adaptiveFormats"].nodes
        let videoFormats = allFormats.filter {
            let mime = $0["mimeType"].string ?? ""
            return mime.contains("video/mp4") && $0["url"].string != nil
        }.sorted { ($0["bitrate"].value as? Int ?? 0) > ($1["bitrate"].value as? Int ?? 0) }

        let urls = videoFormats.compactMap { $0["url"].string } + [media["hlsManifestUrl"].string].compactMap { $0 }
        guard let url = urls.compactMap(URL.init(string:)).first(where: { $0.scheme == "https" }) else {
            throw EchoError("This video has no compatible stream that the Mac player can open.")
        }
        let meta = root["videoDetails"]
        let track = Track(
            source: .youtube(videoID),
            title: meta["title"].string ?? videoID,
            artist: meta["author"].string ?? "",
            artwork: meta["thumbnail"]["thumbnails"].nodes.last?["url"].string.flatMap(URL.init(string:)),
            duration: meta["lengthSeconds"].string.flatMap(Double.init),
            playbackSource: .youtube(videoID)
        )
        let bytes = videoFormats.first(where: { $0["url"].string == url.absoluteString })?["contentLength"].string.flatMap(Int64.init)
        return Stream(url: url, track: track, audioByteCount: bytes)
    }

    /// Fetches artist information, discography albums, and singles from YouTube Music.
    func artist(id: String) async throws -> Artist {
        let root = try await request("browse", body: ["browseId": id])
        let header = root["header"]["musicImmersiveHeaderRenderer"]
        let name = header["title"].label
        let thumbnail = header["thumbnail"].image
        let bio = header["description"].label

        var albums: [Album] = []
        var singles: [Track] = []

        let sections = root["contents"]["singleColumnBrowseResultsRenderer"].sectionList
        for section in sections {
            let shelf = section["musicCarouselShelfRenderer"]
            let title = shelf["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].label.lowercased()
            if title.contains("album") {
                for item in shelf["contents"].nodes {
                    let row = item["musicTwoRowItemRenderer"]
                    let albumTitle = row["title"].label
                    let albumID = row["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
                    let cover = row["thumbnailRenderer"].image
                    let subtitle = row["subtitle"].label
                    albums.append(Album(id: albumID, title: albumTitle, artist: name, coverURL: cover, year: subtitle))
                }
            } else if title.contains("single") || title.contains("top song") {
                for item in shelf["contents"].nodes {
                    if let track = CatalogParser.song(item["musicResponsiveListItemRenderer"]) {
                        singles.append(track)
                    }
                }
            }
        }

        return Artist(
            id: id,
            name: name.isEmpty ? "Artist" : name,
            thumbnailURL: thumbnail,
            bio: bio.isEmpty ? nil : bio,
            albums: albums,
            singles: singles
        )
    }

    /// Fetches album tracks and metadata from YouTube Music.
    func album(id: String) async throws -> Album {
        let page = try await collection(id)
        let root = try await request("browse", body: ["browseId": id])
        let header = root["header"]["musicDetailHeaderRenderer"]
        let title = header["title"].label
        let artist = header["subtitle"].label
        let cover = header["thumbnail"].image

        return Album(
            id: id,
            title: title.isEmpty ? "Album" : title,
            artist: artist,
            coverURL: cover,
            trackCount: page.tracks.count,
            tracks: page.tracks
        )
    }
}

import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

struct Playlist: Codable, Identifiable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
}

struct LibraryData: Codable {
    var liked: [Track] = []
    var files: [Track] = []
    var playlists: [Playlist] = []
    var downloads: [Track] = []

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        liked = try box.decode([Track].self, forKey: .liked)
        files = try box.decode([Track].self, forKey: .files)
        playlists = try box.decode([Playlist].self, forKey: .playlists)
        downloads = try box.decodeIfPresent([Track].self, forKey: .downloads) ?? []
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var data = LibraryData()
    @Published var issue: String?
    @Published private(set) var importsInProgress = 0
    @Published private(set) var downloading: Set<String> = []
    private let file: URL
    private var canWrite = true

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo Music/library.json")
        let backupURL = self.file.deletingPathExtension().appendingPathExtension("bak.json")
        do {
            let fileData = try Data(contentsOf: self.file)
            guard fileData.count > 0 else { throw EchoError("Library file was empty (0 bytes).") }
            data = try JSONDecoder().decode(LibraryData.self, from: fileData)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // The library is created on the first edit.
        } catch {
            canWrite = false
            if FileManager.default.fileExists(atPath: backupURL.path),
               let backupData = try? Data(contentsOf: backupURL),
               backupData.count > 0,
               let recovered = try? JSONDecoder().decode(LibraryData.self, from: backupData) {
                self.data = recovered
                self.issue = "Could not read \(self.file.path), loaded backup. Your existing file has been preserved. \(error.localizedDescription)"
            } else {
                issue = "Could not read \(self.file.path). Your existing library has been preserved. \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func update(_ change: (inout LibraryData) -> Void) -> Bool {
        guard canWrite else { issue = "Restore the library at \(file.path) and reopen Echo Music to make changes."; return false }
        var next = data
        change(&next)
        do {
            let dir = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path), ((try? Data(contentsOf: file).count) ?? 0) > 0 {
                let backupURL = file.deletingPathExtension().appendingPathExtension("bak.json")
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: file, to: backupURL)
            }
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            data = next
            return true
        } catch { issue = "Could not save the library. \(error.localizedDescription)"; return false }
    }

    func track(forVideoID id: String) -> Track {
        let source = Source.youtube(id)
        if let track = data.downloads.first(where: { $0.source == source }) ?? data.liked.first(where: { $0.source == source }) {
            return track
        }
        for list in data.playlists {
            if let track = list.tracks.first(where: { $0.source == source }) { return track }
        }
        return Track(source: source, title: id, artist: "")
    }

    func likes(_ track: Track) -> Bool { data.liked.contains { $0.id == track.id } }

    func toggleLike(_ track: Track) {
        update {
            if $0.liked.contains(where: { $0.id == track.id }) { $0.liked.removeAll { $0.id == track.id } }
            else { $0.liked.insert(track, at: 0) }
        }
    }

    @discardableResult
    func newPlaylist(_ text: String) -> UUID? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let list = Playlist(name: name)
        update { $0.playlists.append(list) }
        return data.playlists.contains(where: { $0.id == list.id }) ? list.id : nil
    }

    func add(_ track: Track, to id: UUID) {
        update {
            guard let index = $0.playlists.firstIndex(where: { $0.id == id }),
                  !$0.playlists[index].tracks.contains(where: { $0.id == track.id }) else { return }
            $0.playlists[index].tracks.append(track)
        }
    }

    func remove(_ track: Track, from id: UUID) {
        update {
            guard let index = $0.playlists.firstIndex(where: { $0.id == id }) else { return }
            $0.playlists[index].tracks.removeAll { $0.id == track.id }
        }
    }

    func deletePlaylist(_ id: UUID) { update { $0.playlists.removeAll { $0.id == id } } }

    func forgetFile(_ track: Track) {
        update {
            $0.files.removeAll { $0.id == track.id }
            $0.liked.removeAll { $0.id == track.id }
            for index in $0.playlists.indices { $0.playlists[index].tracks.removeAll { $0.id == track.id } }
        }
    }

    private func downloadPath(_ track: Track) -> URL? {
        guard case .youtube(let id) = track.source, SongLink.validID(id) else { return nil }
        return file.deletingLastPathComponent().appendingPathComponent("Downloads/\(id).m4a")
    }

    func offlineURL(_ track: Track) -> URL? {
        guard data.downloads.contains(where: { $0.id == track.id }), let url = downloadPath(track),
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    func download(_ track: Track) async {
        guard case .youtube(let id) = track.source, let destination = downloadPath(track),
              offlineURL(track) == nil, downloading.insert(track.id).inserted else { return }
        defer { downloading.remove(track.id) }
        do {
            let stream = try await Catalog.shared.stream(for: id)
            guard let bytes = stream.audioByteCount, bytes > 0 else {
                throw EchoError("This recording is only available for streaming.")
            }
            let fm = FileManager.default
            let directory = destination.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // AVFoundation needs the media suffix even while validating a staged file.
            let temp = directory.appendingPathComponent(".\(UUID().uuidString).m4a")
            defer { try? fm.removeItem(at: temp) }
            try await AudioDownload.write(stream.url, byteCount: bytes, to: temp)
            let asset = AVURLAsset(url: temp)
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw EchoError("The service returned a file without playable audio.")
            }
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else { try fm.moveItem(at: temp, to: destination) }
            let saved = update {
                $0.downloads.removeAll { $0.id == track.id }
                $0.downloads.insert(track.title == id ? stream.track : track, at: 0)
            }
            if !saved { try? fm.removeItem(at: destination) }
        } catch { issue = "Could not download \(track.title). \(error.localizedDescription)" }
    }

    func removeDownload(_ track: Track) {
        guard let url = downloadPath(track), !downloading.contains(track.id) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            update { $0.downloads.removeAll { $0.id == track.id } }
        } catch { issue = "Could not remove the downloaded file. \(error.localizedDescription)" }
    }

    func importFiles(_ urls: [URL]) async -> [Track] {
        importsInProgress += 1
        defer { importsInProgress -= 1 }
        var imported: [Track] = []
        var failed: [String] = []
        var known = Dictionary(data.files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for url in urls {
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = known[file.absoluteString] { imported.append(existing); continue }
            do {
                let track = try await LocalAudio.read(file)
                imported.append(track)
                known[track.id] = track
            } catch { failed.append(file.lastPathComponent) }
        }
        if !imported.isEmpty {
            update {
                var ids = Set($0.files.map(\.id))
                $0.files.append(contentsOf: imported.filter { ids.insert($0.id).inserted })
            }
        }
        if !failed.isEmpty { issue = "Could not import \(failed.joined(separator: ", ")). Choose a readable audio file supported by macOS." }
        return imported
    }
}

enum LocalAudio {
    static func read(_ url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw EchoError("This file has no playable audio.")
        }
        let tags = try await asset.load(.commonMetadata)
        func item(_ key: AVMetadataKey) -> AVMetadataItem? { tags.first { $0.commonKey == key } }
        let title = try? await item(.commonKeyTitle)?.load(.stringValue)
        let artist = try? await item(.commonKeyArtist)?.load(.stringValue)
        let album = try? await item(.commonKeyAlbumName)?.load(.stringValue)
        let seconds = try await asset.load(.duration).seconds
        var artwork: URL?
        if let bytes = try? await item(.commonKeyArtwork)?.load(.dataValue) {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo Music/Artwork")
            if (try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)) != nil {
                let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let path = cache.appendingPathComponent(key)
                if FileManager.default.fileExists(atPath: path.path) || (try? bytes.write(to: path, options: .atomic)) != nil { artwork = path }
            }
        }
        return Track(source: .file(url), title: title ?? url.deletingPathExtension().lastPathComponent,
                     artist: artist ?? "", album: album, artwork: artwork,
                     duration: seconds.isFinite && seconds > 0 ? seconds : nil)
    }
}

// MARK: - Interchange: CSV & M3U

extension Library {
    func exportCSV(tracks: [Track]? = nil) -> String {
        let exportTracks = tracks ?? data.liked
        var out = "\"Title\",\"Artist\",\"Album\",Duration,URL\n"
        for t in exportTracks {
            let title = t.title.replacingOccurrences(of: "\"", with: "\"\"")
            let artist = t.artist.replacingOccurrences(of: "\"", with: "\"\"")
            let album = (t.album ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let dur = Int(t.duration ?? 0)
            let url = (t.shareURL?.absoluteString ?? urlString(for: t)).replacingOccurrences(of: "\"", with: "\"\"")
            out += "\"\(title)\",\"\(artist)\",\"\(album)\",\(dur),\"\(url)\"\n"
        }
        return out
    }

    private func urlString(for track: Track) -> String {
        switch track.source {
        case .youtube(let id): return "https://music.youtube.com/watch?v=\(id)"
        case .spotify(let id): return "https://open.spotify.com/track/\(id)"
        case .file(let url): return url.absoluteString
        case .apple(let id): return "https://music.apple.com/song/\(id)"
        case .tidal(let id): return "https://tidal.com/browse/track/\(id)"
        case .deezer(let id): return "https://deezer.com/track/\(id)"
        }
    }

    @discardableResult
    func importCSV(_ text: String, intoPlaylistNamed name: String? = nil) -> [Track] {
        var imported: [Track] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.starts(with: "\"Title\"") || trimmed.starts(with: "Title,") { continue }

            let fields = parseCSVLine(trimmed)
            guard fields.count >= 5 else { continue }
            let title = fields[0]
            let artist = fields[1]
            let album = fields[2].isEmpty ? nil : fields[2]
            let duration = Double(fields[3])
            let rawURL = fields[4]

            let track: Track
            if let url = URL(string: rawURL), let videoID = SongLink.videoID(url) {
                track = Track(source: .youtube(videoID), title: title, artist: artist, album: album, duration: duration)
            } else if let url = URL(string: rawURL), let spotify = SpotifySource.parse(url: url), spotify.type == "track" {
                track = Track(source: .spotify(spotify.id), title: title, artist: artist, album: album, duration: duration)
            } else if rawURL.starts(with: "file://"), let fileURL = URL(string: rawURL) {
                track = Track(source: .file(fileURL), title: title, artist: artist, album: album, duration: duration)
            } else {
                track = Track(source: .youtube(rawURL), title: title, artist: artist, album: album, duration: duration)
            }
            imported.append(track)
        }

        guard !imported.isEmpty else { return [] }
        if let name, let playlistID = newPlaylist(name) {
            for t in imported { add(t, to: playlistID) }
        } else {
            update {
                for t in imported {
                    if !$0.liked.contains(where: { $0.id == t.id }) {
                        $0.liked.append(t)
                    }
                }
            }
        }
        return imported
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    func exportM3U(tracks: [Track]) -> String {
        var out = "#EXTM3U\n"
        for t in tracks {
            let dur = Int(t.duration ?? 0)
            out += "#EXTINF:\(dur),\(t.artist) - \(t.title)\n"
            out += "\(urlString(for: t))\n"
        }
        return out
    }

    @discardableResult
    func importM3U(_ text: String, playlistName: String) -> [Track] {
        var tracks: [Track] = []
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var currentTitle = ""
        var currentArtist = ""
        var currentDuration: Double? = nil

        for line in lines {
            if line.starts(with: "#EXTINF:") {
                let stripped = String(line.dropFirst(8))
                let parts = stripped.split(separator: ",", maxSplits: 1).map(String.init)
                if let durStr = parts.first, let d = Double(durStr) { currentDuration = d }
                if parts.count == 2 {
                    let titleParts = parts[1].split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if titleParts.count == 2 {
                        currentArtist = titleParts[0]
                        currentTitle = titleParts[1]
                    } else {
                        currentTitle = parts[1]
                    }
                }
            } else if !line.isEmpty && !line.starts(with: "#") {
                let track: Track
                if let url = URL(string: line), let videoID = SongLink.videoID(url) {
                    track = Track(source: .youtube(videoID), title: currentTitle.isEmpty ? videoID : currentTitle, artist: currentArtist, duration: currentDuration)
                } else if let url = URL(string: line), let spotify = SpotifySource.parse(url: url), spotify.type == "track" {
                    track = Track(source: .spotify(spotify.id), title: currentTitle.isEmpty ? spotify.id : currentTitle, artist: currentArtist, duration: currentDuration)
                } else if line.starts(with: "file://"), let fileURL = URL(string: line) {
                    track = Track(source: .file(fileURL), title: currentTitle.isEmpty ? fileURL.lastPathComponent : currentTitle, artist: currentArtist, duration: currentDuration)
                } else {
                    track = Track(source: .youtube(line), title: currentTitle.isEmpty ? line : currentTitle, artist: currentArtist, duration: currentDuration)
                }
                tracks.append(track)
                currentTitle = ""
                currentArtist = ""
                currentDuration = nil
            }
        }

        if !tracks.isEmpty, let playlistID = newPlaylist(playlistName) {
            for t in tracks { add(t, to: playlistID) }
        }
        return tracks
    }
}

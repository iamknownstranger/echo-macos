import Foundation
import Testing
@testable import EchoMusic

@MainActor
@Suite struct LibraryTests {
    @Test func backupRecoveryWhenCorrupted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let backupFile = directory.appendingPathComponent("library.bak.json")

        let track = Track(source: .youtube("test_123456"), title: "Saved Song", artist: "Artist A")
        let library = Library(file: file)
        library.toggleLike(track)
        // Second edit triggers backup rotation of existing file
        library.newPlaylist("Saved Playlist")

        // Verify backup was created during update
        #expect(FileManager.default.fileExists(atPath: backupFile.path))

        // Corrupt main file
        try Data("corrupted garbage json".utf8).write(to: file)

        // Re-initialize Library - should recover from backup
        let restored = Library(file: file)
        #expect(restored.data.liked.contains(where: { $0.id == track.id }))
        #expect(restored.issue != nil)
    }

    @Test func zeroByteFileRecoveryFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let backupFile = directory.appendingPathComponent("library.bak.json")

        let track = Track(source: .youtube("xyz_987654"), title: "Important Song", artist: "Artist C")
        let library = Library(file: file)
        library.toggleLike(track)
        library.newPlaylist("Backup Check")

        #expect(FileManager.default.fileExists(atPath: backupFile.path))

        // Simulate crash truncation leaving zero-byte file
        try Data().write(to: file)
        #expect((try? Data(contentsOf: file).count) == 0)

        // Library must recognize 0-byte file and recover from backup
        let recovered = Library(file: file)
        #expect(recovered.data.liked.contains(where: { $0.id == track.id }))
        #expect(recovered.issue != nil)
    }

    @Test func csvExportAndImportParity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let library = Library(file: file)

        let t1 = Track(source: .youtube("dQw4w9WgXcQ"), title: "Never Gonna Give You Up", artist: "Rick Astley", album: "Whenever You Need Somebody", duration: 213)
        let t2 = Track(source: .spotify("4cOdK2wGLETKBW3PvgPWqT"), title: "Song 2", artist: "Artist B", album: "Album B", duration: 180)

        let csv = library.exportCSV(tracks: [t1, t2])
        #expect(csv.contains("\"Never Gonna Give You Up\""))
        #expect(csv.contains("\"Rick Astley\""))
        #expect(csv.contains("\"Title\",\"Artist\",\"Album\",Duration,URL"))

        let imported = library.importCSV(csv, intoPlaylistNamed: "Imported Playlist")
        #expect(imported.count == 2)
        #expect(imported[0].title == "Never Gonna Give You Up")
        #expect(imported[1].title == "Song 2")
        #expect(library.data.playlists.contains(where: { $0.name == "Imported Playlist" }))
    }

    @Test func m3uExportAndImportParity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("library.json")
        let library = Library(file: file)

        let t1 = Track(source: .youtube("dQw4w9WgXcQ"), title: "Track One", artist: "Artist One", duration: 150)
        let m3u = library.exportM3U(tracks: [t1])
        #expect(m3u.starts(with: "#EXTM3U"))
        #expect(m3u.contains("#EXTINF:150,Artist One - Track One"))

        let imported = library.importM3U(m3u, playlistName: "M3U List")
        #expect(imported.count == 1)
        #expect(imported[0].title == "Track One")
        #expect(imported[0].artist == "Artist One")
        #expect(imported[0].duration == 150)
    }
}

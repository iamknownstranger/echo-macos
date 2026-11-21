import Foundation
import AVFoundation
import Testing
@testable import EchoMusic

@Suite struct AudioCacheTests {

    @Test func audioCacheURLEncodingAndDecodingRoundTrip() {
        let streamURL = URL(string: "https://rr1---sn-abc.googlevideo.com/videoplayback?expire=12345&ei=6789&id=abc&dur=180.5")!
        let key = "yt_dQw4w9WgXcQ"

        let customURL = AudioCacheURL.encode(streamURL: streamURL, key: key)
        #expect(customURL.scheme == AudioCacheURL.scheme)
        #expect(customURL.lastPathComponent == key)

        let decoded = AudioCacheURL.decode(url: customURL)
        #expect(decoded != nil)
        #expect(decoded?.key == key)
        #expect(decoded?.streamURL == streamURL)
    }

    @Test func audioCacheMetadataPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AudioCache(directory: tempDir)
        let key = "yt_test_meta"

        await cache.saveMeta(key: key, contentLength: 5_242_880, mimeType: "audio/mp4")
        let loaded = await cache.loadMeta(key: key)

        #expect(loaded != nil)
        #expect(loaded?.contentLength == 5_242_880)
        #expect(loaded?.mimeType == "audio/mp4")
    }

    @Test func audioCacheChunkWritingAndAtomicCommit() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AudioCache(directory: tempDir)
        let key = "yt_chunk_test"

        #expect(await cache.isCached(key: key) == false)
        #expect(await cache.cachedURL(for: key) == nil)

        // Write 2 chunks
        let chunk1 = Data([0x01, 0x02, 0x03, 0x04])
        let chunk2 = Data([0x05, 0x06, 0x07, 0x08])

        try await cache.writeChunk(key: key, offset: 0, data: chunk1)
        try await cache.writeChunk(key: key, offset: 4, data: chunk2)

        // Still not committed to final .m4a
        #expect(await cache.isCached(key: key) == false)

        // Commit with expected length 8
        try await cache.commit(key: key, expectedLength: 8)

        #expect(await cache.isCached(key: key) == true)
        let cachedURL = await cache.cachedURL(for: key)
        #expect(cachedURL != nil)

        let fileData = try Data(contentsOf: #require(cachedURL))
        #expect(fileData == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
    }

    @Test func audioCacheLRUPruningEvictsOldestFirst() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AudioCache(directory: tempDir)

        // Create 3 files of 100 KB each: file1 (oldest), file2 (middle), file3 (newest)
        let file1 = await cache.fileURL(for: "yt_oldest")
        let file2 = await cache.fileURL(for: "yt_middle")
        let file3 = await cache.fileURL(for: "yt_newest")

        let payload = Data(repeating: 0xAA, count: 100 * 1024)
        try payload.write(to: file1)
        try payload.write(to: file2)
        try payload.write(to: file3)

        let fm = FileManager.default
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: file1.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-1800)], ofItemAtPath: file2.path)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: file3.path)

        await cache.saveMeta(key: "yt_oldest", contentLength: 100 * 1024, mimeType: "audio/mp4")
        await cache.saveMeta(key: "yt_middle", contentLength: 100 * 1024, mimeType: "audio/mp4")
        await cache.saveMeta(key: "yt_newest", contentLength: 100 * 1024, mimeType: "audio/mp4")

        let initialSize = await cache.totalSize()
        #expect(initialSize == 300 * 1024)

        // Prune to max 150 KB -> should delete file1 (100KB), leaving 200KB -> then delete file2 (100KB), leaving file3 (100KB <= 150KB)
        try await cache.prune(maxBytes: 150 * 1024)

        #expect(await cache.isCached(key: "yt_oldest") == false)
        #expect(await cache.isCached(key: "yt_middle") == false)
        #expect(await cache.isCached(key: "yt_newest") == true)
        #expect(await cache.totalSize() == 100 * 1024)
    }

    @Test func audioCacheKeyResolutionForSources() async {
        let cache = AudioCache()
        #expect(await cache.cacheKey(for: .youtube("dQw4w9WgXcQ")) == "yt_dQw4w9WgXcQ")
        #expect(await cache.cacheKey(for: .spotify("4cOdK2wGLETKBW3PvgPWqT")) == "sp_4cOdK2wGLETKBW3PvgPWqT")
        #expect(await cache.cacheKey(for: .apple("1440818817")) == "ap_1440818817")
        #expect(await cache.cacheKey(for: .file(URL(fileURLWithPath: "/tmp/song.mp3"))) == nil)
    }
}

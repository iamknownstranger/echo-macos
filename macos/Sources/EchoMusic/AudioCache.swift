import Foundation
import AVFoundation

actor AudioCache {
    static let shared = AudioCache()

    let directory: URL
    private let fileManager = FileManager()
    private var activeDownloads: [String: Task<Void, Never>] = [:]

    struct ByteRange: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
    }

    struct Meta: Codable, Equatable, Sendable {
        let contentLength: Int64
        let mimeType: String
        let lastAccess: Date
        var ranges: [ByteRange]
    }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.directory = caches.appendingPathComponent("EchoMusic/AudioCache", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func cacheKey(for source: Source) -> String? {
        switch source {
        case .youtube(let id): return "yt_\(id)"
        case .spotify(let id): return "sp_\(id)"
        case .apple(let id): return "ap_\(id)"
        case .file, .tidal, .deezer: return nil
        }
    }

    func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).m4a")
    }

    func tempURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).downloading")
    }

    func metaURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).meta.json")
    }

    func isCached(key: String) -> Bool {
        let path = fileURL(for: key).path
        guard fileManager.fileExists(atPath: path),
              let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64,
              size > 0 else {
            return false
        }
        return true
    }

    func cachedURL(for key: String) -> URL? {
        guard isCached(key: key) else { return nil }
        touch(key: key)
        return fileURL(for: key)
    }

    func cachedURL(for source: Source) -> URL? {
        guard let key = cacheKey(for: source) else { return nil }
        return cachedURL(for: key)
    }

    func touch(key: String) {
        let url = fileURL(for: key)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func saveMeta(key: String, contentLength: Int64, mimeType: String, ranges: [ByteRange] = []) {
        let meta = Meta(contentLength: contentLength, mimeType: mimeType, lastAccess: Date(), ranges: ranges)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(for: key), options: .atomic)
        }
    }

    func loadMeta(key: String) -> Meta? {
        guard let data = try? Data(contentsOf: metaURL(for: key)),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return nil
        }
        return meta
    }

    func isContiguous(ranges: [ByteRange], expectedLength: Int64) -> Bool {
        guard !ranges.isEmpty else { return false }
        let sorted = ranges.sorted { $0.start < $1.start }
        var currentEnd: Int64 = 0
        for r in sorted {
            if r.start > currentEnd {
                return false
            }
            currentEnd = max(currentEnd, r.end)
        }
        return currentEnd >= expectedLength
    }

    func writeChunk(key: String, offset: Int64, data: Data) throws {
        let temp = tempURL(for: key)
        if !fileManager.fileExists(atPath: temp.path) {
            fileManager.createFile(atPath: temp.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)

        var meta = loadMeta(key: key) ?? Meta(contentLength: 0, mimeType: "audio/mp4", lastAccess: Date(), ranges: [])
        let newRange = ByteRange(start: offset, end: offset + Int64(data.count))
        meta.ranges.append(newRange)
        saveMeta(key: key, contentLength: meta.contentLength, mimeType: meta.mimeType, ranges: meta.ranges)

        if meta.contentLength > 0 && isContiguous(ranges: meta.ranges, expectedLength: meta.contentLength) {
            try? commit(key: key, expectedLength: meta.contentLength)
        }
    }

    func commit(key: String, expectedLength: Int64) throws {
        let temp = tempURL(for: key)
        let destination = fileURL(for: key)
        guard fileManager.fileExists(atPath: temp.path) else { return }
        let attrs = try fileManager.attributesOfItem(atPath: temp.path)
        guard let size = attrs[.size] as? Int64, size >= expectedLength else {
            return
        }
        if let meta = loadMeta(key: key), !isContiguous(ranges: meta.ranges, expectedLength: expectedLength) {
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
    }

    /// Background prefetching of full audio stream into cache.
    func prefetch(key: String, remoteURL: URL, expectedBytes: Int64?) async {
        guard !isCached(key: key), activeDownloads[key] == nil else { return }
        let task = Task {
            do {
                var request = URLRequest(url: remoteURL, timeoutInterval: 45)
                request.setValue("bytes=0-", forHTTPHeaderField: "Range")
                let (tempFile, response) = try await URLSession.shared.download(for: request)
                defer { try? fileManager.removeItem(at: tempFile) }

                guard let http = response as? HTTPURLResponse,
                      (http.statusCode == 200 || http.statusCode == 206) else {
                    return
                }
                let totalBytes: Int64
                if let cl = http.value(forHTTPHeaderField: "Content-Length"), let parsed = Int64(cl), parsed > 0 {
                    totalBytes = parsed
                } else if let expectedBytes, expectedBytes > 0 {
                    totalBytes = expectedBytes
                } else {
                    totalBytes = try Int64(tempFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }

                let mime = http.mimeType ?? "audio/mp4"
                saveMeta(key: key, contentLength: totalBytes, mimeType: mime, ranges: [ByteRange(start: 0, end: totalBytes)])

                let destination = fileURL(for: key)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: tempFile)
                } else {
                    try fileManager.moveItem(at: tempFile, to: destination)
                }
                try prune()
            } catch {
                // Background caching failure is non-fatal; playback continues over streaming.
            }
        }
        activeDownloads[key] = task
        _ = await task.result
        activeDownloads.removeValue(forKey: key)
    }

    func prune(maxBytes: Int64 = 2 * 1024 * 1024 * 1024) throws {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) else {
            return
        }
        let audioFiles = items.filter { $0.pathExtension == "m4a" || $0.pathExtension == "mp4" }
        var fileList: [(url: URL, date: Date, size: Int64)] = []
        var currentTotal: Int64 = 0

        for file in audioFiles {
            let res = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(res.fileSize ?? 0)
            let date = res.contentModificationDate ?? Date.distantPast
            fileList.append((file, date, size))
            currentTotal += size
        }

        fileList.sort { $0.date < $1.date }

        for file in fileList {
            if currentTotal <= maxBytes { break }
            try? fileManager.removeItem(at: file.url)
            let baseKey = file.url.deletingPathExtension().lastPathComponent
            try? fileManager.removeItem(at: metaURL(for: baseKey))
            currentTotal -= file.size
        }
    }

    func totalSize() -> Int64 {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else {
            return 0
        }
        let audioFiles = items.filter { $0.pathExtension == "m4a" || $0.pathExtension == "mp4" }
        return audioFiles.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(size)
        }
    }

    func clearAll() throws {
        let items = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in items {
            try fileManager.removeItem(at: item)
        }
    }
}

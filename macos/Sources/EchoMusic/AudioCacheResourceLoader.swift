import Foundation
import AVFoundation

enum AudioCacheURL {
    static let scheme = "echo-cache"

    static func encode(streamURL: URL, key: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "audio"
        components.path = "/\(key)"
        components.queryItems = [URLQueryItem(name: "remote", value: streamURL.absoluteString)]
        return components.url ?? streamURL
    }

    static func decode(url: URL) -> (streamURL: URL, key: String)? {
        guard url.scheme == scheme else { return nil }
        let key = url.lastPathComponent
        guard !key.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let remoteStr = components.queryItems?.first(where: { $0.name == "remote" })?.value,
              let remoteURL = URL(string: remoteStr) else {
            return nil
        }
        return (remoteURL, key)
    }
}

final class AudioCacheResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = AudioCacheResourceLoader()

    let queue = DispatchQueue(label: "echo.music.audiocache.resourceLoader", qos: .userInitiated)
    private var activeTasks: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]
    private let lock = NSLock()

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let customURL = loadingRequest.request.url,
              let (streamURL, key) = AudioCacheURL.decode(url: customURL) else {
            return false
        }

        Task {
            await handleRequest(loadingRequest, streamURL: streamURL, key: key)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let task = activeTasks.removeValue(forKey: loadingRequest)
        lock.unlock()
        task?.cancel()
    }

    private func handleRequest(_ loadingRequest: AVAssetResourceLoadingRequest, streamURL: URL, key: String) async {
        // 1. Content Information Request
        if let infoRequest = loadingRequest.contentInformationRequest {
            if let meta = await AudioCache.shared.loadMeta(key: key) {
                infoRequest.contentType = meta.mimeType.contains("audio") ? meta.mimeType : "public.mpeg-4-audio"
                infoRequest.contentLength = meta.contentLength
                infoRequest.isByteRangeAccessSupported = true
            } else {
                // Perform lightweight HEAD or Range probe to resolve metadata
                var headReq = URLRequest(url: streamURL, timeoutInterval: 15)
                headReq.httpMethod = "HEAD"
                if let (_, response) = try? await URLSession.shared.data(for: headReq),
                   let http = response as? HTTPURLResponse {
                    let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                    let mime = http.mimeType ?? "public.mpeg-4-audio"
                    infoRequest.contentType = mime
                    infoRequest.contentLength = length
                    infoRequest.isByteRangeAccessSupported = true
                    if length > 0 {
                        await AudioCache.shared.saveMeta(key: key, contentLength: length, mimeType: mime)
                    }
                } else {
                    infoRequest.contentType = "public.mpeg-4-audio"
                    infoRequest.isByteRangeAccessSupported = true
                }
            }
            if loadingRequest.dataRequest == nil {
                loadingRequest.finishLoading()
                return
            }
        }

        // 2. Data Request
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)

        // Check if fully cached locally on disk
        if await AudioCache.shared.isCached(key: key) {
            let fileURL = await AudioCache.shared.fileURL(for: key)
            if let handle = try? FileHandle(forReadingFrom: fileURL) {
                defer { try? handle.close() }
                do {
                    try handle.seek(toOffset: UInt64(requestedOffset))
                    let chunk = handle.readData(ofLength: Int(requestedLength))
                    dataRequest.respond(with: chunk)
                    loadingRequest.finishLoading()
                    return
                } catch {
                    // Fall back to network on read error
                }
            }
        }

        // Fetch requested range from network
        let endOffset = requestedOffset + requestedLength - 1
        var rangeReq = URLRequest(url: streamURL, timeoutInterval: 30)
        rangeReq.setValue("bytes=\(requestedOffset)-\(endOffset)", forHTTPHeaderField: "Range")

        do {
            var (data, response) = try await URLSession.shared.data(for: rangeReq)
            if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                let videoID = key.hasPrefix("yt_") ? String(key.dropFirst(3)) : key
                if let freshStream = try? await Catalog.shared.stream(for: videoID) {
                    var retryReq = URLRequest(url: freshStream.url, timeoutInterval: 30)
                    retryReq.setValue("bytes=\(requestedOffset)-\(endOffset)", forHTTPHeaderField: "Range")
                    if let (retryData, retryResp) = try? await URLSession.shared.data(for: retryReq) {
                        data = retryData
                        response = retryResp
                    }
                }
            }

            guard let http = response as? HTTPURLResponse,
                  (http.statusCode == 200 || http.statusCode == 206) else {
                loadingRequest.finishLoading(with: EchoError("Failed to stream audio range (\(requestedOffset)-\(endOffset))"))
                return
            }

            dataRequest.respond(with: data)
            loadingRequest.finishLoading()

            // Concurrently save chunk to cache temp file
            try? await AudioCache.shared.writeChunk(key: key, offset: requestedOffset, data: data)
        } catch {
            if !loadingRequest.isCancelled {
                loadingRequest.finishLoading(with: error)
            }
        }
    }
}

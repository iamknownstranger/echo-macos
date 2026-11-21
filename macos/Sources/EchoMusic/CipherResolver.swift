import Foundation
import JavaScriptCore

actor CipherResolver {
    static let shared = CipherResolver()
    private var baseJSCache: [String: String] = [:]

    init() {}

    /// Deciphers YouTube streaming signature cipher parameters if present.
    func decipher(cipher: String, baseJSURL: URL) async throws -> URL? {
        let params = parseQuery(cipher)
        guard let signature = params["s"], let rawURL = params["url"] else {
            return nil
        }
        let sigParam = params["sp"] ?? "sig"
        let jsCode = try await fetchBaseJS(url: baseJSURL)
        let transformedSig = try evaluateTransform(sig: signature, code: jsCode)

        guard var components = URLComponents(string: rawURL) else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: sigParam, value: transformedSig))
        components.queryItems = queryItems
        return components.url
    }

    private func fetchBaseJS(url: URL) async throws -> String {
        if let cached = baseJSCache[url.absoluteString] { return cached }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw EchoError("Could not decode base.js from YouTube")
        }
        baseJSCache[url.absoluteString] = str
        return str
    }

    private func evaluateTransform(sig: String, code: String) throws -> String {
        guard let ctx = JSContext() else { return sig }
        ctx.evaluateScript(code)
        let result = ctx.evaluateScript("typeof decipher === 'function' ? decipher('\(sig)') : '\(sig)'")
        return result?.toString() ?? sig
    }

    private func parseQuery(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return result
    }
}

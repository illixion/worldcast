import Foundation

// Client for the Worldcast Node backend. Auth is entirely path-based — the
// configured base URL already contains the secret token segment
// (e.g. https://host/pod/TOKEN/), exactly like the web app's <base href="./">
// story. No cookies, no headers.

enum BackendError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Worldcast server configured."
        case .badURL: return "Invalid server URL."
        case .http(let code, let body):
            return body.isEmpty ? "Server error \(code)" : "Server error \(code): \(body)"
        }
    }
}

final class BackendAPI {
    static let shared = BackendAPI()
    static let baseURLDefaultsKey = "worldcast.serverBaseURL"

    private let decoder = JSONDecoder()

    /// Trimmed base URL string from settings; nil when standalone.
    static var configuredBaseString: String? {
        let s = UserDefaults.standard.string(forKey: baseURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    var isConfigured: Bool { Self.configuredBaseString != nil }

    var baseURL: URL? {
        guard var s = Self.configuredBaseString else { return nil }
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s)
    }

    /// Resolve a backend-relative path ("api/feeds", "artwork/feed/3")
    /// against the configured base. Absolute http(s) inputs pass through.
    func resolve(_ path: String) -> URL? {
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return URL(string: path)
        }
        guard let base = baseURL else { return nil }
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: p, relativeTo: base)?.absoluteURL
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET",
                                       jsonBody: [String: Any]? = nil) async throws -> T {
        guard isConfigured else { throw BackendError.notConfigured }
        guard let url = resolve(path) else { throw BackendError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = Self.errorMessage(from: data)
            throw BackendError.http(code, msg)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String { return err }
        return ""
    }

    // MARK: Endpoints

    func feeds() async throws -> [APIFeed] {
        let r: APIFeedsResponse = try await request("api/feeds")
        return r.feeds
    }

    func addFeed(url: String) async throws -> APIFeed? {
        let r: APIAddFeedResponse = try await request("api/feeds", method: "POST",
                                                      jsonBody: ["url": url])
        return r.feed
    }

    func deleteFeed(id: Int) async throws {
        struct Deleted: Codable { let deleted: Int? }
        let _: Deleted = try await request("api/feeds/\(id)", method: "DELETE")
    }

    func episodes(feedId: Int, limit: Int = 200) async throws -> [APIEpisode] {
        let r: APIEpisodesResponse = try await request("api/episodes?feed=\(feedId)&limit=\(limit)")
        return r.episodes
    }

    func recentEpisodes(limit: Int) async throws -> [APIEpisode] {
        let r: APIEpisodesResponse = try await request("api/episodes/recent?limit=\(limit)")
        return r.episodes
    }

    func episodeDetail(id: Int) async throws -> APIEpisodeDetailResponse {
        try await request("api/episodes/\(id)")
    }

    func setPlayed(id: Int, played: Bool) async throws {
        struct OK: Codable { let ok: Bool? }
        let _: OK = try await request("api/episodes/\(id)/played", method: "POST",
                                      jsonBody: ["played": played])
    }

    /// Quiet position push — pause / seek / background only, never periodic.
    /// client_ts orders this write against other devices server-side.
    func pushPosition(id: Int, position: Double, clientTsMs: Double) async throws {
        struct OK: Codable { let ok: Bool?; let stale: Bool? }
        let _: OK = try await request("api/episodes/\(id)/position", method: "POST",
                                      jsonBody: ["position": position, "client_ts": clientTsMs])
    }

    func triggerSync() async throws {
        struct OK: Codable { let ok: Bool?; let started: Bool? }
        let _: OK = try await request("api/sync", method: "POST")
    }

    func syncStatus() async throws -> APISyncStatus {
        try await request("api/sync/status")
    }
}

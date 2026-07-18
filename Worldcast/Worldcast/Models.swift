import Foundation

// MARK: - Local store models
//
// The app is local-first: these are the persisted (JSON-encoded) types the UI
// renders from. A Worldcast backend, when configured, syncs into/out of this
// same store — `serverId` links a local record to its backend row. Episodes
// are matched across modes by RSS `guid`, so connecting a backend later
// adopts existing standalone records instead of duplicating them.

struct StoredFeed: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var serverId: Int?
    var url: String
    var title: String?
    var author: String?
    var feedDescription: String?
    var artworkURL: String?      // absolute http(s) or backend-relative ("artwork/feed/3")
    var addedAtMs: Double = Date().timeIntervalSince1970 * 1000
    var lastRefreshedAtMs: Double?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return url
    }

    var isDocumentsLibrary: Bool {
        url.hasPrefix(LocalDocumentsLibrary.feedURLPrefix)
    }
}

struct StoredChapter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String?
    var startSeconds: Double
    var endSeconds: Double?
    var artworkURL: String?      // absolute or backend-relative ("artwork/chapter/9")
    var linkURL: String?
}

enum ChapterSource: String, Codable {
    case none        // not fetched yet / episode has none
    case backend     // server-extracted ID3 CHAP
    case json        // Podcasting 2.0 podcast:chapters
    case localID3    // ID3 CHAP frames from a Documents-library MP3
}

struct StoredEpisode: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var serverId: Int?
    var feedId: UUID
    var guid: String
    var title: String
    var episodeDescription: String?
    var audioURL: String?        // enclosure URL, or backend-virtualized ("api/audio/42")
    var audioType: String?
    var durationSeconds: Double?
    var pubDateMs: Double?
    var artworkURL: String?
    var chaptersJSONURL: String? // podcast:chapters URL from the RSS item
    var chapters: [StoredChapter] = []
    var chapterSource: ChapterSource = .none
    var backendChapterCount: Int?  // count reported by list endpoints before detail fetch
    var audioAvailable: Bool = true
    var played: Bool = false
    var positionSeconds: Double = 0
    var lastPlayedAtMs: Double?
    // Position observed locally but not yet accepted by the backend. Pushed
    // (with its client timestamp) before the next pull so offline listening
    // survives a refresh.
    var positionDirty: Bool = false
    var positionClientTsMs: Double?
    var downloadedFileName: String?
    var isVideo: Bool = false

    var displayTitle: String { title.isEmpty ? "—" : title }
    var isUnavailable: Bool { !audioAvailable }
    var isDownloaded: Bool { downloadedFileName != nil }
    var knownChapterCount: Int { chapters.isEmpty ? (backendChapterCount ?? 0) : chapters.count }
    var progressFraction: Double? {
        guard let d = durationSeconds, d > 0, positionSeconds > 0, !played else { return nil }
        return min(1, positionSeconds / d)
    }
}

// MARK: - Backend API DTOs (src/routes/*.js JSON shapes)

struct APIFeed: Codable {
    let id: Int
    let url: String
    let title: String?
    let author: String?
    let description: String?
    let artwork_url: String?
    let episode_count: Int?
    let unplayed_count: Int?
}

struct APIEpisode: Codable {
    let id: Int
    let feed_id: Int?
    let guid: String?
    let title: String?
    let description: String?
    let audio_url: String?
    let audio_type: String?
    let durationSecondsRaw: Double?
    let pub_date: Double?
    let artwork_url: String?
    let feed_artwork_url: String?
    let audio_available: Int?
    let position_seconds: Double?
    let played: Int?
    let chapter_count: Int?
    let feed_title: String?
    let is_video: Int?
    let last_played_at: Double?
    let chapters_status: String?

    enum CodingKeys: String, CodingKey {
        case id, feed_id, guid, title, description, audio_url, audio_type
        case durationSecondsRaw = "duration_seconds"
        case pub_date, artwork_url, feed_artwork_url, audio_available
        case position_seconds, played, chapter_count, feed_title, is_video
        case last_played_at, chapters_status
    }
}

struct APIChapter: Codable {
    let id: Int
    let ordinal: Int?
    let title: String?
    let start_ms: Double
    let end_ms: Double?
    let url: String?
    let artwork_mime: String?
    let artwork_url: String?
}

struct APISyncStatus: Codable {
    let chaptersPending: Int
    let chaptersErrored: Int?
    let lastFeedSyncAt: Double?

    var statusText: String {
        if chaptersPending > 0 {
            return "extracting chapters for \(chaptersPending) episode(s)…"
        }
        if let t = lastFeedSyncAt {
            return "synced \(Formatters.date(ms: t))"
        }
        return ""
    }
}

struct APIFeedsResponse: Codable { let feeds: [APIFeed] }
struct APIEpisodesResponse: Codable { let episodes: [APIEpisode] }
struct APIEpisodeDetailResponse: Codable { let episode: APIEpisode; let chapters: [APIChapter]? }
struct APIAddFeedResponse: Codable { let feed: APIFeed?; let newEpisodes: Int? }

// MARK: - Formatting helpers

enum Formatters {
    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    static func date(ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        return Date(timeIntervalSince1970: ms / 1000)
            .formatted(date: .abbreviated, time: .omitted)
    }

    static func speed(_ r: Double) -> String {
        let s = r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)
        return s.replacing(/\.?0+$/, with: "") + "×"
    }
}

import Foundation
import Observation

nonisolated enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Worldcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var libraryFile: URL { supportDirectory.appendingPathComponent("library.json") }
    static var downloadsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

@Observable
final class LibraryStore {
    private struct Snapshot: Codable {
        var feeds: [StoredFeed]
        var episodes: [StoredEpisode]
    }

    private(set) var feeds: [StoredFeed] = []
    private(set) var episodes: [StoredEpisode] = []
    private(set) var isRefreshing = false
    var syncStatusText = ""
    var lastError: String?

    private let api = BackendAPI.shared

    var backendConfigured: Bool { api.isConfigured }

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.libraryFile),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        feeds = snap.feeds
        episodes = snap.episodes
    }

    func save() {
        let snap = Snapshot(feeds: feeds, episodes: episodes)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: AppPaths.libraryFile, options: .atomic)
    }

    // MARK: - Queries

    var sortedFeeds: [StoredFeed] {
        feeds.sorted { $0.displayTitle.lowercased() < $1.displayTitle.lowercased() }
    }

    func feed(id: UUID) -> StoredFeed? { feeds.first { $0.id == id } }
    func episode(id: UUID) -> StoredEpisode? { episodes.first { $0.id == id } }

    func episodes(inFeed feedId: UUID) -> [StoredEpisode] {
        episodes.filter { $0.feedId == feedId }
            .sorted { ($0.pubDateMs ?? 0, $0.id.uuidString) > ($1.pubDateMs ?? 0, $1.id.uuidString) }
    }

    func episodeCounts(feedId: UUID) -> (total: Int, unplayed: Int) {
        let eps = episodes.filter { $0.feedId == feedId }
        return (eps.count, eps.filter { !$0.played }.count)
    }

    func recentEpisodes(limit: Int) -> [StoredEpisode] {
        episodes.filter { $0.lastPlayedAtMs != nil }
            .sorted { ($0.lastPlayedAtMs ?? 0) > ($1.lastPlayedAtMs ?? 0) }
            .prefix(limit).map { $0 }
    }

    func randomNeverPlayed() -> StoredEpisode? {
        episodes.filter { !$0.played && $0.lastPlayedAtMs == nil && $0.audioAvailable && $0.audioURL != nil }
            .randomElement()
    }

    /// Chronologically-forward next playable episode in the same feed —
    /// mirrors the backend's /episodes/:id/next ordering so auto-advance
    /// behaves identically in both modes.
    func nextEpisode(after ep: StoredEpisode) -> StoredEpisode? {
        let curDate = ep.pubDateMs ?? 0
        return episodes
            .filter {
                $0.feedId == ep.feedId && $0.id != ep.id
                    && $0.audioAvailable && !$0.played
                    && ($0.pubDateMs ?? 0) > curDate
            }
            .min { ($0.pubDateMs ?? 0, $0.id.uuidString) < ($1.pubDateMs ?? 0, $1.id.uuidString) }
    }

    /// Resolve artwork/audio that may be backend-relative ("artwork/feed/3",
    /// "api/audio/42") or absolute (RSS CDN). nil when unresolvable — the UI
    /// falls back to a placeholder.
    func resolveURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("file://") {
            return URL(string: raw)
        }
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return URL(string: raw)
        }
        return api.resolve(raw)
    }

    /// Playback URL for an episode: downloaded file first, then stream.
    func playbackURL(for ep: StoredEpisode) -> URL? {
        if let name = ep.downloadedFileName {
            let f = AppPaths.downloadsDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return resolveURL(ep.audioURL)
    }

    // MARK: - Mutations

    func update(_ ep: StoredEpisode) {
        guard let i = episodes.firstIndex(where: { $0.id == ep.id }) else { return }
        episodes[i] = ep
        save()
    }

    func markPlayed(_ ep: StoredEpisode, played: Bool) {
        guard var e = episode(id: ep.id) else { return }
        e.played = played
        if played { e.positionSeconds = 0 }
        update(e)
        if backendConfigured, let sid = e.serverId {
            Task { try? await api.setPlayed(id: sid, played: played) }
        }
    }

    /// Record a locally observed playback position. `push` follows the quiet
    /// contract: only pause / seek / background edges pass true.
    func recordPosition(episodeId: UUID, position: Double, push: Bool) {
        guard var e = episode(id: episodeId) else { return }
        let ts = Date().timeIntervalSince1970 * 1000
        e.positionSeconds = position
        e.lastPlayedAtMs = ts
        e.positionClientTsMs = ts
        e.positionDirty = true
        update(e)
        guard push else { return }
        if backendConfigured, let sid = e.serverId {
            let epId = e.id
            Task {
                do {
                    try await BackendAPI.shared.pushPosition(id: sid, position: position, clientTsMs: ts)
                    if var cur = self.episode(id: epId), cur.positionClientTsMs == ts {
                        cur.positionDirty = false
                        self.update(cur)
                    }
                } catch { /* stays dirty; retried before next pull */ }
            }
        }
    }

    /// Full local wipe — used when disconnecting from a server so none of
    /// the synced library lingers. Removes feeds, episodes, downloaded audio
    /// and leaves the store empty (standalone, no subscriptions).
    func eraseAllData() {
        try? FileManager.default.removeItem(at: AppPaths.downloadsDirectory)
        episodes = []
        feeds = []
        syncStatusText = ""
        lastError = nil
        save()
    }

    // MARK: - Feed management

    func addFeed(urlString: String) async throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http"), URL(string: trimmed) != nil else {
            throw NSError(domain: "Worldcast", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid http(s) feed URL."])
        }
        guard !feeds.contains(where: { $0.url == trimmed }) else {
            throw NSError(domain: "Worldcast", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Already subscribed to this feed."])
        }
        if backendConfigured {
            _ = try await api.addFeed(url: trimmed)
            try await pullFromBackend()
        } else {
            var feed = StoredFeed(url: trimmed)
            feeds.append(feed)
            try await refreshStandaloneFeed(&feed)
            save()
        }
    }

    func removeFeed(_ feed: StoredFeed) {
        // Delete downloaded audio belonging to this feed.
        for ep in episodes where ep.feedId == feed.id {
            if let name = ep.downloadedFileName {
                try? FileManager.default.removeItem(
                    at: AppPaths.downloadsDirectory.appendingPathComponent(name))
            }
        }
        episodes.removeAll { $0.feedId == feed.id }
        feeds.removeAll { $0.id == feed.id }
        save()
        if backendConfigured, let sid = feed.serverId {
            Task { try? await BackendAPI.shared.deleteFeed(id: sid) }
        }
    }

    // MARK: - Refresh

    /// Refresh the whole library. Backend mode: optionally kick a server-side
    /// RSS sync first, then push dirty positions and pull everything.
    /// Standalone: fetch and parse every feed directly.
    func refreshAll(triggerServerSync: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastError = nil
        importDocumentsLibrary()
        do {
            if backendConfigured {
                if triggerServerSync {
                    try await api.triggerSync()
                    // Server sync is fire-and-forget; give it a moment.
                    try? await Task.sleep(for: .seconds(1.5))
                }
                try await pullFromBackend()
                await updateBackendStatusText()
            } else {
                for var feed in feeds {
                    do { try await refreshStandaloneFeed(&feed) }
                    catch { lastError = "\(feed.displayTitle): \(error.localizedDescription)" }
                }
                save()
                let last = feeds.compactMap(\.lastRefreshedAtMs).max()
                syncStatusText = last != nil ? "updated \(Formatters.date(ms: last))" : ""
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateBackendStatusText() async {
        guard backendConfigured else { return }
        if let status = try? await api.syncStatus() {
            syncStatusText = status.statusText
        }
    }

    // MARK: - Backend sync

    /// Push positions observed while offline (or before the backend was
    /// linked). The server's client_ts ordering discards stale ones.
    private func pushDirtyPositions() async {
        for ep in episodes where ep.positionDirty {
            guard let sid = ep.serverId, let ts = ep.positionClientTsMs else { continue }
            do {
                try await api.pushPosition(id: sid, position: ep.positionSeconds, clientTsMs: ts)
                if var cur = episode(id: ep.id) { cur.positionDirty = false; update(cur) }
            } catch { /* keep dirty */ }
        }
    }

    private func pullFromBackend() async throws {
        // 1. Push dirty positions first so the pull can't clobber them.
        await pushDirtyPositions()

        // 2. Adopt standalone-era feeds the server doesn't know about yet.
        var serverFeeds = try await api.feeds()
        let serverURLs = Set(serverFeeds.map(\.url))
        var adoptedAny = false
        for feed in feeds where !feed.isDocumentsLibrary
            && feed.serverId == nil && !serverURLs.contains(feed.url) {
            do { _ = try await api.addFeed(url: feed.url); adoptedAny = true }
            catch { /* e.g. server can't reach it; stays local-only */ }
        }
        if adoptedAny { serverFeeds = try await api.feeds() }

        // 3. Upsert feeds by serverId, then by URL.
        for sf in serverFeeds {
            if let i = feeds.firstIndex(where: { $0.serverId == sf.id })
                ?? feeds.firstIndex(where: { $0.url == sf.url }) {
                feeds[i].serverId = sf.id
                feeds[i].title = sf.title ?? feeds[i].title
                feeds[i].author = sf.author ?? feeds[i].author
                feeds[i].feedDescription = sf.description ?? feeds[i].feedDescription
                feeds[i].artworkURL = sf.artwork_url ?? feeds[i].artworkURL
                feeds[i].lastRefreshedAtMs = Date().timeIntervalSince1970 * 1000
            } else {
                var f = StoredFeed(url: sf.url)
                f.serverId = sf.id
                f.title = sf.title
                f.author = sf.author
                f.feedDescription = sf.description
                f.artworkURL = sf.artwork_url
                f.lastRefreshedAtMs = Date().timeIntervalSince1970 * 1000
                feeds.append(f)
            }
        }

        // 4. Feeds removed on the server (e.g. from another device) go away
        //    locally too — but only ones that were server-linked.
        let serverIds = Set(serverFeeds.map(\.id))
        for feed in feeds where feed.serverId != nil && !serverIds.contains(feed.serverId!) {
            removeFeed(feed)
        }

        // 5. Pull episodes per feed. Server is source of truth for
        //    played/position (dirty positions were pushed in step 1).
        for feed in feeds {
            guard let sid = feed.serverId else { continue }
            let apiEps = (try? await api.episodes(feedId: sid)) ?? []
            for ae in apiEps { upsertBackendEpisode(ae, feedId: feed.id) }
        }

        // 6. Merge the server's recently-played list. Older backends omit
        //    last_played_at from the per-feed episode list, so without this
        //    the "Recently played" section never populates from a pull.
        if let recent = try? await api.recentEpisodes(limit: 50) {
            for ae in recent {
                guard let i = episodes.firstIndex(where: { $0.serverId == ae.id }) else { continue }
                var e = episodes[i]
                if let lp = ae.last_played_at { e.lastPlayedAtMs = lp }
                if !e.positionDirty, let p = ae.position_seconds { e.positionSeconds = p }
                episodes[i] = e
            }
        }
        save()
    }

    @discardableResult
    private func upsertBackendEpisode(_ ae: APIEpisode, feedId: UUID) -> UUID {
        let idx = episodes.firstIndex { $0.serverId == ae.id }
            ?? episodes.firstIndex { ep in
                guard let g = ae.guid, !g.isEmpty else { return false }
                return ep.feedId == feedId && ep.guid == g
            }
        var e: StoredEpisode
        if let idx { e = episodes[idx] }
        else {
            e = StoredEpisode(feedId: feedId,
                              guid: ae.guid ?? "server-\(ae.id)",
                              title: ae.title ?? "—")
        }
        e.serverId = ae.id
        e.feedId = feedId
        e.title = ae.title ?? e.title
        if let d = ae.description, !d.isEmpty { e.episodeDescription = d }
        e.audioURL = ae.audio_url ?? e.audioURL
        e.audioType = ae.audio_type ?? e.audioType
        e.durationSeconds = ae.durationSecondsRaw ?? e.durationSeconds
        e.pubDateMs = ae.pub_date ?? e.pubDateMs
        e.artworkURL = ae.artwork_url ?? e.artworkURL
        e.audioAvailable = (ae.audio_available ?? 1) == 1
        e.isVideo = (ae.is_video ?? 0) == 1
        e.backendChapterCount = ae.chapter_count ?? e.backendChapterCount
        if let lp = ae.last_played_at { e.lastPlayedAtMs = lp }
        if !e.positionDirty {
            if let p = ae.position_seconds { e.positionSeconds = p }
            if let pl = ae.played { e.played = pl == 1 }
        }
        if let idx { episodes[idx] = e } else { episodes.append(e) }
        return e.id
    }

    // MARK: - Standalone refresh

    private func refreshStandaloneFeed(_ feed: inout StoredFeed) async throws {
        guard let url = URL(string: feed.url) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "Worldcast", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "feed fetch failed (\(code))"])
        }
        let parsed = try await Task.detached { try RSSFeedParser.parse(data: data) }.value

        guard let i = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[i].title = parsed.title ?? feeds[i].title
        feeds[i].author = parsed.author ?? feeds[i].author
        feeds[i].feedDescription = parsed.feedDescription ?? feeds[i].feedDescription
        feeds[i].artworkURL = parsed.artworkURL ?? feeds[i].artworkURL
        feeds[i].lastRefreshedAtMs = Date().timeIntervalSince1970 * 1000
        feed = feeds[i]

        for item in parsed.items {
            guard let guid = item.effectiveGuid else { continue }
            if let j = episodes.firstIndex(where: { $0.feedId == feed.id && $0.guid == guid }) {
                var e = episodes[j]
                e.title = item.title ?? e.title
                if let d = item.itemDescription, !d.isEmpty { e.episodeDescription = d }
                e.audioURL = item.enclosureURL ?? e.audioURL
                e.audioType = item.enclosureType ?? e.audioType
                e.durationSeconds = item.durationSeconds ?? e.durationSeconds
                e.pubDateMs = item.pubDateMs ?? e.pubDateMs
                e.artworkURL = item.artworkURL ?? e.artworkURL
                e.chaptersJSONURL = item.chaptersJSONURL ?? e.chaptersJSONURL
                e.isVideo = item.isVideo
                episodes[j] = e
            } else {
                var e = StoredEpisode(feedId: feed.id, guid: guid, title: item.title ?? "—")
                e.episodeDescription = item.itemDescription
                e.audioURL = item.enclosureURL
                e.audioType = item.enclosureType
                e.durationSeconds = item.durationSeconds
                e.pubDateMs = item.pubDateMs
                e.artworkURL = item.artworkURL
                e.chaptersJSONURL = item.chaptersJSONURL
                e.isVideo = item.isVideo
                e.audioAvailable = item.enclosureURL != nil
                episodes.append(e)
            }
        }
    }

    // MARK: - Chapters

    /// Ensure chapters are loaded for an episode: server-extracted ID3 CHAP
    /// when a backend is linked, Podcasting 2.0 JSON chapters otherwise (or
    /// as fallback when the backend has none). Cached in the store.
    func ensureChapters(for episodeId: UUID) async -> StoredEpisode? {
        guard var e = episode(id: episodeId) else { return nil }
        if !e.chapters.isEmpty { return e }

        if let raw = e.audioURL, let localURL = URL(string: raw), localURL.isFileURL {
            e.chapters = LocalID3Chapters.read(from: localURL)
            e.chapterSource = .localID3
            update(e)
            return e
        }

        if backendConfigured, let sid = e.serverId {
            if let detail = try? await api.episodeDetail(id: sid) {
                if let d = detail.episode.description, !d.isEmpty { e.episodeDescription = d }
                e.durationSeconds = detail.episode.durationSecondsRaw ?? e.durationSeconds
                let chs = (detail.chapters ?? []).map { c in
                    StoredChapter(title: c.title,
                                  startSeconds: c.start_ms / 1000,
                                  endSeconds: c.end_ms.map { $0 / 1000 },
                                  artworkURL: c.artwork_url,
                                  linkURL: c.url)
                }
                if !chs.isEmpty {
                    e.chapters = chs
                    e.chapterSource = .backend
                    update(e)
                    return e
                }

            }
        }
        if let raw = e.chaptersJSONURL, let url = URL(string: raw) {
            if let chs = try? await JSONChapters.fetch(from: url), !chs.isEmpty {
                e.chapters = chs
                e.chapterSource = .json
            }
        }
        update(e)
        return e
    }

    // MARK: - Documents library

    /// Imports direct MP3 children of Documents/<podcast>/ as local feeds.
    /// Files remains the source of truth: deleting a podcast folder removes
    /// its local feed at the next foreground refresh.
    private func importDocumentsLibrary() {
        let scanned = LocalDocumentsLibrary.scan()
        let activeURLs = Set(scanned.map(\.feedURL))
        var changed = false

        for podcast in scanned {
            let feedIndex = feeds.firstIndex { $0.url == podcast.feedURL }
            let feedId: UUID
            if let feedIndex {
                feedId = feeds[feedIndex].id
                if feeds[feedIndex].title != podcast.title {
                    feeds[feedIndex].title = podcast.title
                    changed = true
                }
            } else {
                var feed = StoredFeed(url: podcast.feedURL)
                feed.title = podcast.title
                feeds.append(feed)
                feedId = feed.id
                changed = true
            }

            for source in podcast.episodes {
                if let index = episodes.firstIndex(where: {
                    $0.feedId == feedId && $0.guid == source.guid
                }) {
                    var episode = episodes[index]
                    let sourceURL = source.fileURL.absoluteString
                    if episode.title != source.title
                        || episode.audioURL != sourceURL
                        || episode.audioType != "audio/mpeg"
                        || !episode.audioAvailable
                        || episode.pubDateMs != source.modifiedAtMs {
                        episode.title = source.title
                        episode.audioURL = sourceURL
                        episode.audioType = "audio/mpeg"
                        episode.audioAvailable = true
                        episode.pubDateMs = source.modifiedAtMs
                        episodes[index] = episode
                        changed = true
                    }
                } else {
                    var episode = StoredEpisode(feedId: feedId, guid: source.guid, title: source.title)
                    episode.audioURL = source.fileURL.absoluteString
                    episode.audioType = "audio/mpeg"
                    episode.audioAvailable = true
                    episode.pubDateMs = source.modifiedAtMs
                    episodes.append(episode)
                    changed = true
                }
            }
        }

        let removed = feeds.filter {
            $0.isDocumentsLibrary && !activeURLs.contains($0.url)
        }
        for feed in removed {
            episodes.removeAll { $0.feedId == feed.id }
            feeds.removeAll { $0.id == feed.id }
            changed = true
        }
        if changed { save() }
    }
}

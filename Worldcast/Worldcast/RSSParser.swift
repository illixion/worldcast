import Foundation

// Standalone-mode RSS parsing. Pure data work — fully nonisolated so it can
// run off the main actor. Understands the subset of RSS the Worldcast backend
// cares about, plus Podcasting 2.0 <podcast:chapters> for JSON chapter
// support (the backend covers ID3 CHAP; standalone covers JSON).

nonisolated struct ParsedFeed: Sendable {
    var title: String?
    var author: String?
    var feedDescription: String?
    var artworkURL: String?
    var items: [ParsedItem] = []
}

nonisolated struct ParsedItem: Sendable {
    var guid: String?
    var title: String?
    var itemDescription: String?
    var enclosureURL: String?
    var enclosureType: String?
    var durationSeconds: Double?
    var pubDateMs: Double?
    var artworkURL: String?
    var chaptersJSONURL: String?
    var link: String?

    /// Stable identity: explicit guid, else enclosure URL, else link+title.
    var effectiveGuid: String? {
        if let guid, !guid.isEmpty { return guid }
        if let enclosureURL, !enclosureURL.isEmpty { return enclosureURL }
        if let link, !link.isEmpty { return link + "#" + (title ?? "") }
        return nil
    }

    var isVideo: Bool {
        let t = (enclosureType ?? "").lowercased()
        if t.hasPrefix("video/") { return true }
        if t.hasPrefix("audio/") { return false }
        let u = (enclosureURL ?? "").lowercased()
        return u.contains(".m4v") || u.contains(".mov") || u.contains(".webm")
    }
}

nonisolated final class RSSFeedParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var currentItem: ParsedItem?
    private var text = ""
    private var elementStack: [String] = []
    private var inImageTag = false   // channel-level <image><url>…

    static func parse(data: Data) throws -> ParsedFeed {
        let p = RSSFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !p.feed.items.isEmpty else {
            throw NSError(domain: "RSSFeedParser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not parse feed XML"
            ])
        }
        return p.feed
    }

    private func localName(_ qName: String) -> String {
        qName.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        elementStack.append(name)
        text = ""
        switch name {
        case "item", "entry":
            currentItem = ParsedItem()
        case "enclosure":
            currentItem?.enclosureURL = attributeDict["url"]
            currentItem?.enclosureType = attributeDict["type"]
        case "media:content":
            if currentItem?.enclosureURL == nil, let u = attributeDict["url"] {
                currentItem?.enclosureURL = u
                currentItem?.enclosureType = attributeDict["type"]
            }
        case "itunes:image":
            let href = attributeDict["href"]
            if currentItem != nil { currentItem?.artworkURL = href ?? currentItem?.artworkURL }
            else if feed.artworkURL == nil { feed.artworkURL = href }
        case "podcast:chapters":
            currentItem?.chaptersJSONURL = attributeDict["url"]
        case "image":
            if currentItem == nil { inImageTag = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        elementStack.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }

        if var item = currentItem {
            switch name {
            case "item", "entry":
                feed.items.append(item)
                currentItem = nil
                return
            case "title": if item.title == nil { item.title = value }
            case "guid": item.guid = value
            case "description", "itunes:summary":
                // content:encoded wins if present; description is fallback.
                if item.itemDescription == nil || item.itemDescription?.isEmpty == true {
                    item.itemDescription = value
                }
            case "content:encoded":
                if !value.isEmpty { item.itemDescription = value }
            case "pubdate":
                item.pubDateMs = Self.parseDateMs(value)
            case "itunes:duration":
                item.durationSeconds = Self.parseDuration(value)
            case "link": if item.link == nil { item.link = value }
            default: break
            }
            currentItem = item
            return
        }

        // Channel-level
        switch name {
        case "title":
            // Only the direct channel title, not <image><title>.
            if feed.title == nil && !inImageTag { feed.title = value }
        case "itunes:author", "author":
            if feed.author == nil { feed.author = value }
        case "description", "itunes:summary":
            if feed.feedDescription == nil { feed.feedDescription = value }
        case "url":
            if inImageTag && feed.artworkURL == nil { feed.artworkURL = value }
        case "image":
            inImageTag = false
        default:
            break
        }
    }

    // MARK: parsing helpers

    static func parseDuration(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let secs = Double(trimmed) { return secs }
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reversed().enumerated().reduce(0) { acc, pair in
            acc + pair.element * pow(60, Double(pair.offset))
        }
    }

    static func parseDateMs(_ s: String) -> Double? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = f
            if let d = df.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        }
        if let d = try? Date(s, strategy: .iso8601) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }
}

// MARK: - Podcasting 2.0 JSON chapters

// https://github.com/Podcastindex-org/podcast-namespace — chapters JSON:
// { "chapters": [{ "startTime": 0, "title": "…", "img": "…", "url": "…" }] }
nonisolated enum JSONChapters {
    struct File: Codable {
        let chapters: [Entry]
    }
    struct Entry: Codable {
        let startTime: Double
        let endTime: Double?
        let title: String?
        let img: String?
        let url: String?
    }

    static func fetch(from url: URL) async throws -> [StoredChapter] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "JSONChapters", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "chapters fetch failed (\(code))"])
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        return file.chapters
            .sorted { $0.startTime < $1.startTime }
            .map { e in
                StoredChapter(title: e.title, startSeconds: e.startTime,
                              endSeconds: e.endTime, artworkURL: e.img, linkURL: e.url)
            }
    }
}

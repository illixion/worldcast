import Foundation

// The app's Documents directory is exposed through Files and Finder file
// sharing. Each direct child folder is a podcast; its direct MP3 children are
// episodes. Keeping this deliberately shallow makes the drop-folder contract
// obvious and avoids treating arbitrary Files documents as media.
nonisolated enum LocalDocumentsLibrary {
    static let feedURLPrefix = "worldcast-documents://"

    struct Podcast {
        let feedURL: String
        let title: String
        let episodes: [Episode]
    }

    struct Episode {
        let guid: String
        let title: String
        let fileURL: URL
        let modifiedAtMs: Double?
    }

    static func scan() -> [Podcast] {
        let fm = FileManager.default
        let root = AppPaths.documentsDirectory
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.compactMap { folder -> Podcast? in
            guard (try? folder.resourceValues(forKeys: keys).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
                  ) else { return nil }
            let episodes = files.compactMap { file -> Episode? in
                let values = try? file.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true,
                      file.pathExtension.lowercased() == "mp3" else { return nil }
                let name = file.deletingPathExtension().lastPathComponent
                let relativePath = "\(folder.lastPathComponent)/\(file.lastPathComponent)"
                return Episode(
                    guid: "documents:\(relativePath)",
                    title: name,
                    fileURL: file,
                    modifiedAtMs: values?.contentModificationDate.map {
                        $0.timeIntervalSince1970 * 1000
                    }
                )
            }
            guard !episodes.isEmpty else { return nil }
            let encodedName = folder.lastPathComponent.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? folder.lastPathComponent
            return Podcast(
                feedURL: feedURLPrefix + encodedName,
                title: folder.lastPathComponent,
                episodes: episodes.sorted { $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

// Minimal ID3v2 CHAP reader for local MP3s. The server remains responsible
// for its richer APIC extraction; this lets standalone Documents imports use
// chapter navigation and lock-screen chapter titles without a backend.
nonisolated enum LocalID3Chapters {
    static func read(from url: URL) -> [StoredChapter] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10),
              header.count == 10,
              Array(header.prefix(3)) == [0x49, 0x44, 0x33] else { return [] }
        let bytes = [UInt8](header)
        let version = bytes[3]
        guard version == 3 || version == 4 else { return [] }
        let tagSize = syncSafe(bytes[6...9])
        guard tagSize > 0, tagSize <= 16 * 1024 * 1024,
              let tag = try? handle.read(upToCount: tagSize), tag.count == tagSize else { return [] }
        return parseTag([UInt8](tag), version: version, hasExtendedHeader: bytes[5] & 0x40 != 0)
    }

    private static func parseTag(_ tag: [UInt8], version: UInt8, hasExtendedHeader: Bool) -> [StoredChapter] {
        var cursor = 0
        if hasExtendedHeader, tag.count >= 4 {
            let length = version == 4 ? syncSafe(tag[0...3]) : bigEndian(tag[0...3])
            cursor = min(tag.count, length + (version == 3 ? 4 : 0))
        }
        var chapters: [StoredChapter] = []
        while cursor + 10 <= tag.count {
            let identifier = String(bytes: tag[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            if identifier.allSatisfy({ $0 == "\0" }) { break }
            let size = version == 4
                ? syncSafe(tag[(cursor + 4)..<(cursor + 8)])
                : bigEndian(tag[(cursor + 4)..<(cursor + 8)])
            cursor += 10
            guard size >= 0, cursor + size <= tag.count else { break }
            if identifier == "CHAP", let chapter = parseChapter(Array(tag[cursor..<(cursor + size)]), version: version) {
                chapters.append(chapter)
            }
            cursor += size
        }
        return chapters.sorted { $0.startSeconds < $1.startSeconds }
    }

    private static func parseChapter(_ bytes: [UInt8], version: UInt8) -> StoredChapter? {
        guard let terminator = bytes.firstIndex(of: 0), terminator + 17 <= bytes.count else { return nil }
        let start = Double(bigEndian(bytes[(terminator + 1)..<(terminator + 5)])) / 1000
        var title: String?
        var cursor = terminator + 17
        while cursor + 10 <= bytes.count {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = version == 4
                ? syncSafe(bytes[(cursor + 4)..<(cursor + 8)])
                : bigEndian(bytes[(cursor + 4)..<(cursor + 8)])
            cursor += 10
            guard size >= 0, cursor + size <= bytes.count else { break }
            if id == "TIT2" {
                title = decodeText(Array(bytes[cursor..<(cursor + size)]))
                break
            }
            cursor += size
        }
        return StoredChapter(title: title, startSeconds: start, endSeconds: nil, artworkURL: nil, linkURL: nil)
    }

    private static func decodeText(_ bytes: [UInt8]) -> String? {
        guard let encoding = bytes.first else { return nil }
        let raw = Array(bytes.dropFirst())
        let text: String?
        switch encoding {
        case 0: text = String(data: Data(raw.prefix { $0 != 0 }), encoding: .isoLatin1)
        case 1: text = String(data: Data(raw), encoding: .utf16)
        case 2: text = String(data: Data(raw), encoding: .utf16BigEndian)
        case 3: text = String(data: Data(raw.prefix { $0 != 0 }), encoding: .utf8)
        default: text = nil
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    private static func syncSafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7f) }
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
}

import CryptoKit
import UIKit

// Two-tier artwork cache: NSCache in memory, files on disk under
// Application Support/Worldcast/Artwork/<sha256(url)>. Every artwork load in
// the app funnels through here, so anything seen once (and everything
// prefetched when an episode is downloaded) keeps working offline.

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    nonisolated static var directory: URL {
        let dir = AppPaths.supportDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    /// Memory → disk → network. Returns nil only when all three miss.
    func image(for url: URL) async -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> { await Self.load(url) }
        inFlight[url] = task
        let img = await task.value
        inFlight[url] = nil
        if let img { memory.setObject(img, forKey: url as NSURL) }
        return img
    }

    /// Fire-and-forget warm-up (e.g. after an episode download completes, so
    /// its chapter/episode art is on disk before the device goes offline).
    func prefetch(_ urls: [URL]) {
        for url in urls {
            guard memory.object(forKey: url as NSURL) == nil else { continue }
            Task { _ = await image(for: url) }
        }
    }

    private nonisolated static func load(_ url: URL) async -> UIImage? {
        if url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }
        let file = fileURL(for: url)
        if let img = UIImage(contentsOfFile: file.path) { return img }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let img = UIImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return img
    }
}

import Foundation
import Observation

// Offline episode downloads via a background URLSession, so a download
// started in-app finishes even if the user backgrounds or iOS suspends us.
// Files land in Application Support/Worldcast/Downloads/<episode-uuid>.<ext>;
// the mapping lives on StoredEpisode.downloadedFileName in the library store.

enum DownloadState: Equatable {
    case downloading(progress: Double)
    case failed(String)
}

@Observable
final class DownloadManager {
    static let sessionIdentifier = "com.illixion.worldcast.downloads"

    /// Called by the app delegate when iOS relaunches us to finish
    /// background session events.
    static var backgroundCompletionHandler: (() -> Void)?

    private(set) var states: [UUID: DownloadState] = [:]
    weak var library: LibraryStore?

    private var session: URLSession!
    private let delegate = SessionDelegate()

    init() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.manager = self
        // Rebuild the progress map for downloads that survived a relaunch.
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let id = Self.episodeId(from: task) else { continue }
                    self.states[id] = .downloading(progress: 0)
                }
            }
        }
    }

    func state(for episodeId: UUID) -> DownloadState? { states[episodeId] }

    func startDownload(for episode: StoredEpisode, url: URL) {
        guard states[episode.id] == nil || {
            if case .failed = states[episode.id] { return true } else { return false }
        }() else { return }
        let ext = Self.fileExtension(for: episode, url: url)
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let task = session.downloadTask(with: req)
        task.taskDescription = "\(episode.id.uuidString)|\(episode.id.uuidString).\(ext)"
        states[episode.id] = .downloading(progress: 0)
        task.resume()
    }

    func cancelDownload(for episodeId: UUID) {
        session.getAllTasks { tasks in
            for task in tasks where Self.episodeId(from: task) == episodeId {
                task.cancel()
            }
        }
        states[episodeId] = nil
    }

    func removeDownload(for episode: StoredEpisode) {
        guard let name = episode.downloadedFileName else { return }
        try? FileManager.default.removeItem(
            at: AppPaths.downloadsDirectory.appendingPathComponent(name))
        guard var e = library?.episode(id: episode.id) else { return }
        e.downloadedFileName = nil
        library?.update(e)
    }

    // MARK: internal plumbing

    private nonisolated static func episodeId(from task: URLSessionTask) -> UUID? {
        guard let desc = task.taskDescription,
              let idPart = desc.split(separator: "|").first else { return nil }
        return UUID(uuidString: String(idPart))
    }

    private nonisolated static func fileName(from task: URLSessionTask) -> String? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|")
        return parts.count == 2 ? String(parts[1]) : nil
    }

    private static func fileExtension(for episode: StoredEpisode, url: URL) -> String {
        let byType: [String: String] = [
            "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a",
            "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/ogg": "ogg",
            "audio/opus": "opus", "video/mp4": "mp4", "video/quicktime": "mov",
            "video/webm": "webm",
        ]
        if let t = episode.audioType?.lowercased(), let e = byType[t] { return e }
        let pathExt = url.pathExtension.lowercased()
        if !pathExt.isEmpty && pathExt.count <= 4 { return pathExt }
        return episode.isVideo ? "mp4" : "mp3"
    }

    fileprivate func taskProgressed(episodeId: UUID, progress: Double) {
        if case .downloading = states[episodeId] ?? .downloading(progress: 0) {
            states[episodeId] = .downloading(progress: progress)
        }
    }

    fileprivate func taskFinished(episodeId: UUID, fileName: String) {
        states[episodeId] = nil
        guard var e = library?.episode(id: episodeId) else { return }
        e.downloadedFileName = fileName
        library?.update(e)
        prefetchOfflineAssets(episodeId: episodeId)
    }

    /// A downloaded episode should be fully usable offline: make sure its
    /// chapters are fetched and every related image (episode, feed, chapter
    /// artwork) is in the on-disk ImageCache.
    private func prefetchOfflineAssets(episodeId: UUID) {
        guard let library else { return }
        Task {
            guard let ep = await library.ensureChapters(for: episodeId) else { return }
            var urls: [URL] = []
            let feedArt = library.feed(id: ep.feedId)?.artworkURL
            if let u = library.resolveURL(ep.artworkURL ?? feedArt) { urls.append(u) }
            if let u = library.resolveURL(feedArt) { urls.append(u) }
            urls.append(contentsOf: ep.chapters.compactMap { library.resolveURL($0.artworkURL) })
            ImageCache.shared.prefetch(urls)
        }
    }

    fileprivate func taskFailed(episodeId: UUID, message: String) {
        states[episodeId] = .failed(message)
    }

    // Delegate callbacks arrive on the session's queue; the temp file must be
    // moved synchronously inside didFinishDownloadingTo, before hopping back
    // to the main actor.
    private nonisolated final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
        // Set once during init before any task runs; only read from delegate callbacks.
        nonisolated(unsafe) weak var manager: DownloadManager?

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let id = DownloadManager.episodeId(from: downloadTask),
                  let name = DownloadManager.fileName(from: downloadTask) else { return }
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                Task { @MainActor [weak manager] in
                    manager?.taskFailed(episodeId: id, message: "HTTP \(http.statusCode)")
                }
                return
            }
            let dest = AppPaths.downloadsDirectory.appendingPathComponent(name)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                Task { @MainActor [weak manager] in
                    manager?.taskFinished(episodeId: id, fileName: name)
                }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor [weak manager] in
                    manager?.taskFailed(episodeId: id, message: msg)
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let id = DownloadManager.episodeId(from: downloadTask),
                  totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor [weak manager] in
                manager?.taskProgressed(episodeId: id, progress: progress)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error, (error as NSError).code != NSURLErrorCancelled,
                  let id = DownloadManager.episodeId(from: task) else { return }
            let msg = error.localizedDescription
            Task { @MainActor [weak manager] in
                manager?.taskFailed(episodeId: id, message: msg)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor in
                DownloadManager.backgroundCompletionHandler?()
                DownloadManager.backgroundCompletionHandler = nil
            }
        }
    }
}

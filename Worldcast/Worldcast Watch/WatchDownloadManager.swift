import Foundation
import Observation

// Offline episode downloads for the watch app, via a background URLSession
// so a download survives the app backgrounding. Unlike the phone's
// DownloadManager, the watch has no persistent library store, so a
// downloaded episode's metadata (title, chapters, artwork URLs) is cached
// alongside the audio file so playback works with no network at all.

enum WatchDownloadState: Equatable {
    case downloading(progress: Double)
    case failed(String)
}

struct DownloadedEpisode: Codable {
    let episode: WatchEpisode
    let chapters: [WatchChapter]
    let fileName: String
}

@Observable
@MainActor
final class WatchDownloadManager {
    static let sessionIdentifier = "com.illixion.worldcast.watch.downloads"
    static var backgroundCompletionHandler: (() -> Void)?

    private(set) var states: [Int: WatchDownloadState] = [:]
    private(set) var downloaded: [Int: DownloadedEpisode] = [:]

    /// Set by `WatchLibrary` to fetch full episode detail (chapters
    /// included) once a download finishes, without duplicating its
    /// networking code here.
    var fetchDetail: ((Int) async throws -> (WatchEpisode, [WatchChapter]))?

    private var session: URLSession!
    private let delegate = SessionDelegate()
    private static let indexFileName = "downloads-index.json"

    init() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.manager = self
        loadIndex()
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let id = Self.episodeId(from: task) else { continue }
                    self.states[id] = .downloading(progress: 0)
                }
            }
        }
    }

    var downloadedEpisodes: [WatchEpisode] {
        downloaded.values.map(\.episode).sorted {
            ($0.title ?? "") < ($1.title ?? "")
        }
    }

    func isDownloaded(_ episodeId: Int) -> Bool { downloaded[episodeId] != nil }
    func state(for episodeId: Int) -> WatchDownloadState? { states[episodeId] }
    func chapters(for episodeId: Int) -> [WatchChapter]? { downloaded[episodeId]?.chapters }

    func localAudioURL(for episodeId: Int) -> URL? {
        guard let entry = downloaded[episodeId] else { return nil }
        let url = Self.downloadsDirectory.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func startDownload(episode: WatchEpisode, chapters: [WatchChapter], audioURL: URL) {
        if case .downloading = states[episode.id] { return }
        let ext = audioURL.pathExtension.isEmpty ? "mp3" : audioURL.pathExtension
        let fileName = "\(episode.id).\(ext)"
        var req = URLRequest(url: audioURL)
        req.timeoutInterval = 60
        let task = session.downloadTask(with: req)
        task.taskDescription = "\(episode.id)|\(fileName)"
        states[episode.id] = .downloading(progress: 0)
        task.resume()
    }

    func cancelDownload(for episodeId: Int) {
        session.getAllTasks { tasks in
            for task in tasks where Self.episodeId(from: task) == episodeId {
                task.cancel()
            }
        }
        states[episodeId] = nil
    }

    func removeDownload(for episodeId: Int) {
        guard let entry = downloaded[episodeId] else { return }
        try? FileManager.default.removeItem(
            at: Self.downloadsDirectory.appendingPathComponent(entry.fileName))
        downloaded[episodeId] = nil
        saveIndex()
    }

    // MARK: internal plumbing

    private nonisolated static var downloadsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private nonisolated static func episodeId(from task: URLSessionTask) -> Int? {
        guard let desc = task.taskDescription,
              let idPart = desc.split(separator: "|").first else { return nil }
        return Int(idPart)
    }

    private nonisolated static func fileName(from task: URLSessionTask) -> String? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|")
        return parts.count == 2 ? String(parts[1]) : nil
    }

    fileprivate func taskProgressed(episodeId: Int, progress: Double) {
        if case .downloading = states[episodeId] ?? .downloading(progress: 0) {
            states[episodeId] = .downloading(progress: progress)
        }
    }

    fileprivate func taskFinished(episodeId: Int, fileName: String) {
        states[episodeId] = nil
        Task {
            guard let fetchDetail, let (episode, chapters) = try? await fetchDetail(episodeId) else { return }
            downloaded[episodeId] = DownloadedEpisode(episode: episode, chapters: chapters, fileName: fileName)
            saveIndex()
        }
    }

    fileprivate func taskFailed(episodeId: Int, message: String) {
        states[episodeId] = .failed(message)
    }

    private func loadIndex() {
        let url = Self.downloadsDirectory.appendingPathComponent(Self.indexFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Int: DownloadedEpisode].self, from: data) else { return }
        downloaded = decoded
    }

    private func saveIndex() {
        let url = Self.downloadsDirectory.appendingPathComponent(Self.indexFileName)
        guard let data = try? JSONEncoder().encode(downloaded) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // Delegate callbacks arrive on the session's queue; the temp file must be
    // moved synchronously inside didFinishDownloadingTo, before hopping back
    // to the main actor.
    private nonisolated final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
        // Set once during init before any task runs; only read from delegate callbacks.
        nonisolated(unsafe) weak var manager: WatchDownloadManager?

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let id = WatchDownloadManager.episodeId(from: downloadTask),
                  let name = WatchDownloadManager.fileName(from: downloadTask) else { return }
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                Task { @MainActor [weak manager] in
                    manager?.taskFailed(episodeId: id, message: "HTTP \(http.statusCode)")
                }
                return
            }
            let dest = WatchDownloadManager.downloadsDirectory.appendingPathComponent(name)
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
            guard let id = WatchDownloadManager.episodeId(from: downloadTask),
                  totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor [weak manager] in
                manager?.taskProgressed(episodeId: id, progress: progress)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error, (error as NSError).code != NSURLErrorCancelled,
                  let id = WatchDownloadManager.episodeId(from: task) else { return }
            let msg = error.localizedDescription
            Task { @MainActor [weak manager] in
                manager?.taskFailed(episodeId: id, message: msg)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor in
                WatchDownloadManager.backgroundCompletionHandler?()
                WatchDownloadManager.backgroundCompletionHandler = nil
            }
        }
    }
}

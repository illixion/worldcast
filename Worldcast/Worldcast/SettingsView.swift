import SwiftUI

// Server configuration. The app is fully standalone with no server; entering
// a Worldcast base URL (which embeds the secret token as a path segment,
// e.g. https://host/pod/TOKEN/) turns on sync of subscriptions, playback
// positions and server-extracted ID3 chapters.

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BackendAPI.baseURLDefaultsKey) private var serverBaseURL = ""

    @State private var draft = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var confirmDisconnect = false
    @AppStorage(WatchConfigurationSync.enabledKey) private var syncServerToWatch = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $draft,
                              prompt: Text(verbatim: "https://host.ts.net/pod/TOKEN/")
                                .foregroundStyle(.secondary))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !draft.isEmpty {
                        Button {
                            testConnection()
                        } label: {
                            if testing { ProgressView() }
                            else { Text("Test connection") }
                        }
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                    }
                } header: {
                    Text("Worldcast server")
                } footer: {
                    Text(serverFooter)
                }

                if !serverBaseURL.isEmpty {
                    Section {
                        Toggle("Sync server to Apple Watch", isOn: $syncServerToWatch)
                    } header: {
                        Text("Apple Watch")
                    } footer: {
                        Text("Sends the server URL and its secret token to your paired Apple Watch. "
                             + "The watch can then connect directly over Wi-Fi or cellular.")
                    }

                    Section {
                        Button("Disconnect server", role: .destructive) {
                            confirmDisconnect = true
                        }
                    } footer: {
                        Text("Stops syncing and erases the synced library, downloads and cached artwork from this device.")
                    }
                }

                Section("About") {
                    LabeledContent("Mode", value: serverBaseURL.isEmpty ? "Standalone" : "Synced")
                    LabeledContent("Feeds", value: "\(library.sortedFeeds.count)")
                    LabeledContent("Downloads", value: downloadsSummary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                }
            }
            .onAppear { draft = serverBaseURL }
            .confirmationDialog(
                "Disconnect and erase library?",
                isPresented: $confirmDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect & Erase", role: .destructive) { disconnect() }
            } message: {
                Text("Removes all feeds, episodes, downloads and cached artwork from this device. The server keeps its data.")
            }
        }
    }

    private func disconnect() {
        serverBaseURL = ""
        syncServerToWatch = false
        WatchConfigurationSync.shared.sendServerURL(nil)
        draft = ""
        testResult = nil
        player.stop()
        library.eraseAllData()
        ImageCache.shared.clear()
    }

    private var downloadsSummary: String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) { acc, f in
            acc + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        return "\(files.count) · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var serverFooter: String {
        "Optional. Leave empty to use the app standalone (direct RSS). "
            + "The URL includes your secret token as a path segment — treat it "
            + "like a password and only use it over trusted transport (e.g. Tailscale)."
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        serverBaseURL = trimmed
        if syncServerToWatch {
            WatchConfigurationSync.shared.sendServerURL(trimmed)
        }
        dismiss()
        Task { await library.refreshAll() }
    }

    private func testConnection() {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: candidate) else {
            testResult = "Invalid URL"
            return
        }
        if !candidate.hasSuffix("/") { url = URL(string: candidate + "/") ?? url }
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            do {
                let feedsURL = url.appending(path: "api/feeds")
                let (data, response) = try await URLSession.shared.data(from: feedsURL)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let r = try? JSONDecoder().decode(APIFeedsResponse.self, from: data) {
                    testResult = "✓ Connected — \(r.feeds.count) feed(s) on server"
                } else if code == 404 {
                    testResult = "404 — check the token path segment"
                } else {
                    testResult = "Unexpected response (\(code))"
                }
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

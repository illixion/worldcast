import SwiftUI

// "Add" tab: subscribe to a feed by URL. Used to be a header "+" button that
// popped an alert; now a full tab so it's reachable without a top toolbar.

struct AddFeedView: View {
    @Environment(LibraryStore.self) private var library

    @State private var urlString = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    @FocusState private var fieldFocused: Bool

    /// Lets the parent switch back to the library tab once the feed lands.
    var onAdded: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Feed URL", text: $urlString,
                              prompt: Text(verbatim: "https://example.com/feed.xml")
                                .foregroundStyle(.secondary))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit { addFeed() }
                } header: {
                    Text("RSS feed URL")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        addFeed()
                    } label: {
                        HStack {
                            Spacer()
                            if isAdding {
                                ProgressView()
                            } else {
                                Text("Add feed").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(trimmedURL.isEmpty || isAdding)
                }
            }
            .navigationTitle("Add Feed")
        }
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addFeed() {
        let url = trimmedURL
        guard !url.isEmpty else { return }
        isAdding = true
        errorMessage = nil
        Task {
            defer { isAdding = false }
            do {
                try await library.addFeed(urlString: url)
                urlString = ""
                fieldFocused = false
                onAdded()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

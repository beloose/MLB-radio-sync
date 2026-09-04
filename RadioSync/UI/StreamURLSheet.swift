import SwiftUI
import UIKit

/// Entry form for the Stream URL source: paste an HLS playlist or an
/// Icecast/Shoutcast stream address, or pick one of the examples.
struct StreamURLSheet: View {
    @Environment(PlayerModel.self) private var model
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    struct Example: Identifiable {
        let name: String
        let detail: String
        let url: String
        var id: String { url }
    }

    static let examples: [Example] = [
        Example(name: "WEEI 93.7 (web stream)", detail: "HLS · Audacy", url: "https://live.amperwave.net/manifest/audacy-weeifmaac-hlsc.m3u8"),
        Example(name: "France Inter", detail: "HLS · 4 s segments", url: "https://stream.radiofrance.fr/franceinter/franceinter_hifi.m3u8"),
        Example(name: "NPR Program Stream", detail: "Icecast · MP3", url: "https://npr-ice.streamguys1.com/live.mp3"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/stream.m3u8", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(commit)
                    HStack {
                        Button {
                            if let pasted = UIPasteboard.general.string { text = pasted }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        if !text.isEmpty {
                            Button("Clear", role: .destructive) { text = "" }
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Stream URL")
                } footer: {
                    Text("An HLS playlist (.m3u8) or a direct Icecast / Shoutcast stream. Audio is downloaded and decoded by the app itself, so the delay controls work on it exactly like on the microphone.")
                }

                Section("Examples") {
                    ForEach(Self.examples) { example in
                        Button {
                            text = example.url
                            problem = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(example.name).foregroundStyle(.primary)
                                Text(example.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Stream URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelStreamURLEntry() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: commit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            text = model.streamURL?.absoluteString ?? ""
            focused = text.isEmpty
        }
        .preferredColorScheme(.dark)
    }

    private func commit() {
        problem = model.setStreamURL(text)
    }
}

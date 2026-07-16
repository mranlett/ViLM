// RebuildFaceIndexView.swift
// Settings tool: scans every actor's photos and caches a Vision face
// fingerprint per photo (content-hash keyed), powering Suggest Actors in
// Video Details. Safe to re-run; unchanged photos are skipped.

import SwiftUI
import LibraryCore

struct RebuildFaceIndexView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL

    private enum Phase {
        case idle
        case running
        case done(RebuildFaceIndexResult)
        case failed(String)
    }

    @State private var phase: Phase = .idle

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                switch phase {
                case .idle:
                    Text("Scans every actor's profile and gallery photos on your device and remembers what their face looks like. This lets \"Suggest Actors\" (in Video Details) recognize them in a video's contact sheet frames.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Text("Safe to re-run any time — only new or changed photos are processed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Rebuild Face Index") {
                        run()
                    }
                    .buttonStyle(.borderedProminent)

                case .running:
                    ProgressView("Scanning actor photos…")
                    Text("This runs entirely on this device — no photos leave your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                case .done(let result):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    VStack(spacing: 6) {
                        Text("Index Updated")
                            .font(.headline)
                        Text("\(result.actorsScanned) actor\(result.actorsScanned == 1 ? "" : "s"), \(result.photosScanned) photo\(result.photosScanned == 1 ? "" : "s") checked.")
                        Text(result.fingerprintsComputed == 0
                             ? "No new fingerprints were needed."
                             : "\(result.fingerprintsComputed) new fingerprint\(result.fingerprintsComputed == 1 ? "" : "s") computed.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .multilineTextAlignment(.center)

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Button("Try Again") {
                        run()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Rebuild Face Index")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func run() {
        phase = .running
        let url = libraryURL
        Task.detached(priority: .userInitiated) {
            do {
                let store = try LibraryStore(at: url)
                let result = try store.rebuildFaceIndex(libraryURL: url)
                await MainActor.run { phase = .done(result) }
            } catch {
                await MainActor.run { phase = .failed("Couldn't rebuild the face index: \(error.localizedDescription)") }
            }
        }
    }
}

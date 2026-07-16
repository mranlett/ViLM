// SuggestActorsView.swift
// The Suggest Actors sheet in Video Details: scans the video's contact sheet
// for faces and lists visually-similar actors (face crop, name, similarity
// percent). Suggestions only - nothing is tagged until the user taps Add.

import SwiftUI
import LibraryCore

/// Suggests actors who may appear in this video by comparing faces detected
/// in its contact sheet against each actor's cached face fingerprint(s).
/// Purely a suggestion tool — nothing is added until the user taps a result.
struct SuggestActorsView: View {
    @Environment(\.dismiss) private var dismiss

    let asset: Asset
    let libraryURL: URL
    /// Called with the actor name to add as an "actor:" tag on this asset.
    let onAddActor: (String) -> Void

    @State private var suggestions: [ActorFaceSuggestion] = []
    @State private var isScanning = true
    @State private var errorMessage: String?
    @State private var addedNames: Set<String> = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Suggest Actors")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await scan() }
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 12) {
                ProgressView("Looking for faces…")
                Text("Checking this video's contact sheet against your actors' reference photos, on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn't Scan This Video",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if suggestions.isEmpty {
            ContentUnavailableView(
                "No Matches Found",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("No faces in this video's contact sheet looked similar enough to an actor's reference photos. This is a rough visual-similarity check, not identification — try adding actors manually, or run \"Rebuild Face Index\" in Settings if you've added new actor photos recently.")
            )
        } else {
            List {
                Section {
                    Text("These are visual-similarity guesses, not confirmed identifications — double-check before adding.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(suggestions) { suggestion in
                    row(for: suggestion)
                }
            }
        }
    }

    private func row(for suggestion: ActorFaceSuggestion) -> some View {
        HStack(spacing: 12) {
            faceCropImage(url: suggestion.faceCropURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.actorName)
                    .font(.callout)
                Text("\(Int(suggestion.similarity * 100))% similar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if asset.actors.contains(suggestion.actorName) || addedNames.contains(suggestion.actorName) {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            } else {
                Button("Add") {
                    addedNames.insert(suggestion.actorName)
                    onAddActor(suggestion.actorName)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func faceCropImage(url: URL) -> some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.2)
        }
        #else
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.2)
        }
        #endif
    }

    private func scan() async {
        let url = libraryURL
        let currentAsset = asset
        do {
            let store = try LibraryStore(at: url)
            let result = try await Task.detached(priority: .userInitiated) {
                try store.suggestActors(for: currentAsset, libraryURL: url)
            }.value
            await MainActor.run {
                self.suggestions = result
                self.isScanning = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isScanning = false
            }
        }
    }
}

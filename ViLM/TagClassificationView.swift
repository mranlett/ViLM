// TagClassificationView.swift
// Settings tool: says what each tag DESCRIBES, so the graph can stop being
// wired by accident.
//
// A tag either describes something that happens in a video or something a
// performer IS — "a video isn't a redhead, an actor is." Until a tag is
// classified it attaches to nothing, so this screen is the gate the rest of the
// taxonomy waits behind.
//
// Deliberately thin: every decision lives in LibraryCore.TagVocabulary, which
// is tested. This file arranges and dispatches, and nothing else.

import SwiftUI
import LibraryCore

struct TagClassificationView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let assets: [Asset]
    let onRefresh: () -> Void

    @State private var items: [TagVocabulary.WorklistItem] = []
    @State private var isLoading = true
    @State private var newlyFound = 0
    @State private var errorMessage: String?

    private var remaining: Int { items.filter { !$0.isClassified }.count }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Reading the vocabulary…")
                } else if items.isEmpty {
                    ContentUnavailableView("No tags yet",
                                           systemImage: "tag",
                                           description: Text("Tags appear here once videos carry them."))
                } else {
                    list
                }
            }
            .navigationTitle("What tags describe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
        // Also on disappear: a sheet swiped away never presses Done, and the
        // classifications are already saved by then — the caller just would not
        // know to reload.
        .onDisappear { onRefresh() }
    }

    private var list: some View {
        List {
            if remaining > 0 {
                Section {
                    // Stated rather than implied: an unclassified tag is not
                    // merely untidy, it cannot be attached to anything.
                    Label("\(remaining) still to classify. Until a tag is classified it can't be added to anything.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
            if newlyFound > 0 {
                Section {
                    Label("\(newlyFound) new since the last check", systemImage: "sparkles")
                        .font(.callout)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            ForEach(items) { item in
                row(item)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TagVocabulary.WorklistItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.record.displayName).font(.headline)
                Spacer()
                Text(item.uses == 1 ? "1 video" : "\(item.uses) videos")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Surfaced so a merge is visible rather than discovered later.
            // Compared against the display name rather than by counting: a tag
            // whose only spelling in the library differs from its stored
            // display name is exactly the case worth showing, and a count of
            // one would hide it.
            let others = item.spellings.filter { $0 != item.record.displayName }
            if !others.isEmpty {
                Text("also spelled \(others.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.uses == 0 {
                Text("no longer used by any video")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // No pre-selection: "Not set" is a real option and the initial one.
            Picker("Describes", selection: kindBinding(for: item)) {
                Text("Not set").tag(String?.none)
                ForEach(TagKind.seed, id: \.name) { kind in
                    Text(label(for: kind)).tag(String?.some(kind.name))
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    private func label(for kind: TagKind) -> String {
        switch kind.name {
        case TagKind.action.name: return "Action in a video"
        case TagKind.videoAttribute.name: return "About the video"
        case TagKind.performerAttribute.name: return "About a performer"
        default: return kind.name
        }
    }

    private func kindBinding(for item: TagVocabulary.WorklistItem) -> Binding<String?> {
        Binding(
            get: { item.record.kind },
            set: { newKind in
                var updated = item.record
                updated.kind = newKind
                // Deferred rather than saved inline: this setter runs while
                // SwiftUI is evaluating the picker, and mutating @State there
                // is a state change during a view update.
                Task { @MainActor in save(updated) }
            }
        )
    }

    private func save(_ record: TagRecord) {
        do {
            let store = try LibraryStore(at: libraryURL)
            try store.saveTagRecord(record)
            items = TagVocabulary.worklist(assets: assets,
                                           vocabulary: try store.fetchTagVocabulary())
            errorMessage = nil
        } catch {
            // Surfaced, never swallowed: a classification that silently failed
            // would leave the operator believing work was done that was not.
            errorMessage = "Couldn't save that: \(error.localizedDescription)"
        }
    }

    private func load() async {
        do {
            let store = try LibraryStore(at: libraryURL)
            newlyFound = try store.promoteTagVocabulary().count
            items = TagVocabulary.worklist(assets: assets,
                                           vocabulary: try store.fetchTagVocabulary())
        } catch {
            errorMessage = "Couldn't read the vocabulary: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

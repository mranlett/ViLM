// EntityRenameSheet.swift
// Renaming a tag, studio, series or actor everywhere it appears.
//
// One sheet for every kind, because the operation genuinely is the same one:
// `renameTagGlobally` takes a prefixed id and rewrites every video that carries
// it. The actor pages have had this for a while; tags and studios had the same
// underlying capability and no way to reach it.
//
// Renaming ONTO an existing name is a merge, and that is not a mistake to be
// prevented — it is how two spellings of one thing get combined. It is called
// out before it happens rather than refused, because the operator asking for it
// usually means it.

import SwiftUI
import LibraryCore

struct EntityRenameSheet: View {
    /// Prefix the library files this kind under: `tag`, `studio`, `actor`.
    let category: String
    let currentName: String
    /// Every name already in use for this category, so a merge can be spotted
    /// before it happens.
    let existingNames: [String]
    var onRenamed: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName: String = ""
    @State private var isWorking = false

    private var trimmed: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renaming onto a name already in use merges the two.
    private var mergesInto: String? {
        existingNames.first {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
                && $0.caseInsensitiveCompare(currentName) != .orderedSame
        }
    }

    /// A pure change of capitalization is still worth doing — it is the whole
    /// point of the spelling repair — so it must not be mistaken for a no-op.
    private var isCaseOnlyChange: Bool {
        trimmed != currentName && trimmed.caseInsensitiveCompare(currentName) == .orderedSame
    }

    private var canRename: Bool {
        !trimmed.isEmpty && trimmed != currentName && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current", value: currentName)
                    TextField("New name", text: $newName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { if canRename { Task { await rename() } } }
                } footer: {
                    Text("Every video using this \(category) is updated, in every open library.")
                }

                if let mergesInto {
                    Section {
                        Label("Merges into “\(mergesInto)”", systemImage: "arrow.triangle.merge")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("That name is already in use. The two become one — which is usually the point, but it cannot be undone in a single step.")
                    }
                }

                if isCaseOnlyChange {
                    Section {
                        Label("Changes capitalization only", systemImage: "textformat")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Rename \(category.capitalized)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isWorking ? "Renaming…" : "Rename") {
                        Task { await rename() }
                    }
                    .disabled(!canRename)
                }
            }
            .onAppear { if newName.isEmpty { newName = currentName } }
        }
        // A single field and an explanation — narrower than the default, but it
        // still needs the grouped style or the label and field lay out in one
        // row wider than the sheet.
        .macFormSheet(minWidth: 460, minHeight: 260)
    }

    private func rename() async {
        guard canRename else { return }
        isWorking = true
        let target = trimmed
        do {
            // Across every OPEN library, matching what the actor rename does:
            // a tag renamed in one and left alone in another would come back on
            // the next sync.
            for libraryURL in LibrarySession.shared.allURLs {
                let store = try LibraryStore(at: libraryURL)
                try store.renameTagGlobally(oldTag: "\(category):\(currentName)",
                                            newTag: "\(category):\(target)")
            }
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
            onRenamed(target)
            dismiss()
        } catch {
            AppErrorReporter.report("Couldn't rename: \(error.localizedDescription)")
        }
        isWorking = false
    }
}

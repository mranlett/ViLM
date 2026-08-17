// PasteCastPanel.swift
// Paste the cast list you just read, instead of typing it a name at a time.
//
// ⭐ Sits directly beneath "Found it somewhere else?" because that is the
// order the work happens in: you found a page, you noted where, and now you are
// copying what it said. Entering five performers meant five round trips through
// one text field, which made the feature usable on a handful of videos rather
// than the hundreds it was built for.
//
// 🚨 IT ADDS ONLY WHAT THE LIBRARY ALREADY KNOWS. Names it does not recognise
// are SHOWN, never adopted — minting a profile from a paste is how a typo
// becomes a permanent record, and you are right here looking at the list.
//
// ⭐ The reading is `NamePaste`, in LibraryCore under test. Only the wording is
// here. That matters more than usual: the canonicalisation it does is what
// stops a source's spelling splitting one performer into two records, and a
// rule inside a view is a rule no test can reach.

import SwiftUI
import LibraryCore

struct PasteCastPanel: View {
    let asset: Asset
    let libraryURL: URL?
    var onAdd: ([String]) -> Void

    @State private var pasted = ""
    @State private var kind: NamePaste.Kind = .actor
    @State private var result: PastedNames?
    @State private var vocabulary: NameVocabulary?
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isOpen {
                open
            } else {
                Button {
                    isOpen = true
                } label: {
                    Label("Paste a cast list", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }
        }
        .task { await loadVocabulary() }
    }

    @ViewBuilder
    private var open: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) {
                Text("Cast").tag(NamePaste.Kind.actor)
                Text("Tags").tag(NamePaste.Kind.tag)
                Text("Studio").tag(NamePaste.Kind.studio)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in result = nil }

            TextField("Paste names separated by commas or new lines",
                      text: $pasted, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                #if os(iOS)
                .autocorrectionDisabled()
                #endif

            if let result {
                if !result.known.isEmpty {
                    // ⚠️ Shown in the LIBRARY's spelling, which is what will be
                    // written — so a difference from what was pasted is visible
                    // before anything is added rather than discovered later.
                    Text("^[\(result.known.count) name](inflect: true) your library knows")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(result.known.joined(separator: ", "))
                        .font(.caption)
                }
                if !result.unknown.isEmpty {
                    Label("Not recognised, and not added: \(result.unknown.joined(separator: ", "))",
                          systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Usually a different spelling. Add one by hand if it is genuinely new.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if result.isEmpty {
                    Text("Nothing readable in that.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel") { close() }.font(.caption)
                Spacer()
                Button("Read") { read() }
                    .font(.caption)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || vocabulary == nil)
                if let result, !result.known.isEmpty {
                    Button("Add \(result.known.count)") { add(result) }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                }
            }

            if vocabulary == nil {
                Text("Reading what your library knows…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func read() {
        guard let vocabulary else { return }
        result = NamePaste.read(pasted, as: kind, vocabulary: vocabulary)
    }

    private func add(_ names: PastedNames) {
        let tags = NamePaste.tags(for: names, as: kind)
        guard !tags.isEmpty else { return }
        onAdd(tags)
        close()
    }

    private func close() {
        isOpen = false
        pasted = ""
        result = nil
    }

    /// ⚠️ Off the main actor. Building the vocabulary reads every asset and
    /// every profile, and `.utility` because nothing is blocked on it — the
    /// field is usable the moment it arrives. See QoSConventionTests.
    private func loadVocabulary() async {
        guard vocabulary == nil, let url = libraryURL else { return }
        vocabulary = await Task.detached(priority: .utility) { () -> NameVocabulary? in
            guard let store = try? LibraryStore(at: url),
                  let assets = try? store.fetchAllAssets() else { return nil }
            let profiles = (try? store.fetchAllEntityProfiles()).map(EntityProfileIndex.init)
            if let profiles {
                return NameVocabulary(assets: assets, profiles: profiles)
            }
            return NameVocabulary(assets: assets)
        }.value
    }
}

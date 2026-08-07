// TagCleanupView.swift
// Settings tool: deletes profiles nothing refers to any more, PER NODE KIND.
//
// 🚨 It used to treat every node kind as one pile: one list, one "Delete All
// Orphans" button. Arriving from Studio Health — which had found an orphaned
// STUDIO — that button also deleted orphaned actors. The node kinds are
// distinct and each gets its own count, its own list and its own button.
//
// The rule itself moved to `OrphanAudit` in LibraryCore, where it can be
// tested, and it gained two exclusions it badly needed: an actor reachable by
// EDGE is not an orphan, and a network with imprints is not an orphan.
//
// It used to also offer a free-text merge — type a source id and a destination
// id — which is now the worst of four ways to do that job. The galleries, the
// profile editor and Repair Tag Spelling all rename globally too, and each of
// them shows you the names rather than asking you to type a prefixed id
// exactly. The merge is gone; this does the one thing nothing else does.

import SwiftUI
import LibraryCore

struct TagCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    
    let libraryURL: URL
    let assets: [Asset]
    let onRefresh: () -> Void
    
    @State private var orphans: [GraphNodeKind: [OrphanFinding]] = [:]
    @State private var isLoading = true
    @State private var isCleaningOrphans = false
    @State private var errorMessage: String?
    /// The kind awaiting confirmation. Deleting profiles is not undoable, and
    /// the old screen did it on a single tap.
    @State private var pendingDeletion: GraphNodeKind?
    
    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section { ProgressView("Reading profiles…") }
                } else if orphans.values.allSatisfy(\.isEmpty) {
                    Section {
                        Label("Nothing orphaned", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Every actor and studio in this library is still referred to by a video, an edge, or — for a network — by an imprint beneath it.")
                    }
                } else {
                    // ⚠️ One section PER KIND, each with its own button. The
                    // single "Delete All Orphans" this replaces deleted actors
                    // when the operator had come to clean up studios.
                    ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                        if let found = orphans[kind], !found.isEmpty {
                            section(for: kind, found: found)
                        }
                    }
                }
            }
            .confirmationDialog(
                pendingDeletion.map { "Delete \(orphans[$0]?.count ?? 0) orphaned \($0.plural)?" } ?? "",
                isPresented: Binding(get: { pendingDeletion != nil },
                                     set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                if let kind = pendingDeletion {
                    Button("Delete \(orphans[kind]?.count ?? 0) \(kind.plural)", role: .destructive) {
                        Task { await deleteOrphans(kind) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This cannot be undone. Only \(pendingDeletion?.plural ?? "profiles") are affected.")
            }
            .navigationTitle("Orphaned Profiles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadProfiles()
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .macFormSheet(minWidth: 560, minHeight: 440)
    }
    
    @ViewBuilder
    private func section(for kind: GraphNodeKind, found: [OrphanFinding]) -> some View {
        Section {
            Text("\(found.count) orphaned \(found.count == 1 ? kind.singular : kind.plural)")
                .font(.subheadline).fontWeight(.semibold)

            ForEach(found.prefix(Self.examplesShown)) { orphan in
                Text(orphan.displayName).font(.caption).foregroundStyle(.secondary)
            }
            if found.count > Self.examplesShown {
                Text("…and \(found.count - Self.examplesShown) more")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Button("Delete \(found.count) orphaned \(found.count == 1 ? kind.singular : kind.plural)",
                   role: .destructive) {
                pendingDeletion = kind
            }
            .disabled(isCleaningOrphans)
        } header: {
            Text(kind == .actor ? "Actors" : "Studios")
        } footer: {
            Text(kind == .actor
                 ? "Actors with no video referring to them, by name or by edge."
                 : "Studios with no video and no imprint beneath them. A network that owns other studios is never listed, even with no videos of its own — that is what a network is.")
        }
    }

    private static let examplesShown = 10

    private func loadProfiles() {
        do {
            self.orphans = try LibraryStore(at: libraryURL).auditOrphans()
            isLoading = false
        } catch {
            self.errorMessage = "Failed to load profiles: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func deleteOrphans(_ kind: GraphNodeKind) async {
        pendingDeletion = nil
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }

        do {
            let store = try LibraryStore(at: libraryURL)
            // ⚠️ Scoped to the one kind. Nothing else is touched.
            for orphan in orphans[kind] ?? [] {
                try store.deleteEntityProfile(for: orphan.id)
            }

            await MainActor.run {
                loadProfiles()
                onRefresh()
            }
        } catch {
            self.errorMessage = "Failed to delete orphans: \(error.localizedDescription)"
        }
    }
}

// TagCleanupView.swift
// Settings tool: deletes entity profiles no video refers to any more.
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
    
    @State private var allProfiles: [EntityProfile] = []
    @State private var isLoading = true
    
    // Merge state
    
    // Orphan state
    @State private var isCleaningOrphans = false
    @State private var errorMessage: String?
    
    private var allUsedTags: Set<String> {
        var tags = Set<String>()
        for asset in assets {
            for tag in asset.tags {
                tags.insert(tag)
            }
        }
        return tags
    }
    
    private var orphanedProfiles: [EntityProfile] {
        allProfiles.filter { !allUsedTags.contains($0.id) }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Orphan Cleanup"), footer: Text("Profiles that exist in the database but have zero videos attached to them.")) {
                    if isLoading {
                        ProgressView("Loading profiles...")
                    } else if orphanedProfiles.isEmpty {
                        Text("No orphaned profiles found.")
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(orphanedProfiles.count) orphaned profile(s) found.")
                        
                        Button("Delete All Orphans", role: .destructive) {
                            Task { await deleteOrphans() }
                        }
                        .disabled(isCleaningOrphans)
                        
                        // List out the orphans (max 10 for performance)
                        ForEach(orphanedProfiles.prefix(10)) { profile in
                            Text(profile.id).font(.caption).foregroundColor(.secondary)
                        }
                        if orphanedProfiles.count > 10 {
                            Text("...and \(orphanedProfiles.count - 10) more").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
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
    
    private func loadProfiles() {
        do {
            let store = try LibraryStore(at: libraryURL)
            self.allProfiles = try store.fetchAllEntityProfiles()
            isLoading = false
        } catch {
            self.errorMessage = "Failed to load profiles: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    private func deleteOrphans() async {
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }
        
        do {
            let store = try LibraryStore(at: libraryURL)
            for orphan in orphanedProfiles {
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

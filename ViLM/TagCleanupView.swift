// TagCleanupView.swift
// Settings tool: merges duplicate tags across the library and deletes
// orphaned entity profiles that no longer match any video.

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
    @State private var sourceTag: String = ""
    @State private var destinationTag: String = ""
    @State private var isMerging = false
    
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
                Section(header: Text("Merge Tags & Actors"), footer: Text("Merging updates all videos to use the Destination Tag. The Source Tag's profile data will be permanently deleted in favor of the Destination Tag's profile.")) {
                    TextField("Source Tag (e.g., actor:John Doe)", text: $sourceTag)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    
                    TextField("Destination Tag (e.g., actor:John Smith)", text: $destinationTag)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    
                    Button("Merge Tag") {
                        Task { await mergeTags() }
                    }
                    .disabled(sourceTag.isEmpty || destinationTag.isEmpty || isMerging || sourceTag == destinationTag)
                }
                
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
            .navigationTitle("Tag & Actor Cleanup")
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
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
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
    
    private func mergeTags() async {
        isMerging = true
        defer { isMerging = false }
        
        do {
            let store = try LibraryStore(at: libraryURL)
            try store.renameTagGlobally(oldTag: sourceTag, newTag: destinationTag)
            
            sourceTag = ""
            destinationTag = ""
            
            await MainActor.run {
                onRefresh()
                loadProfiles() // Reload profiles after merge
            }
        } catch {
            self.errorMessage = "Failed to merge: \(error.localizedDescription)"
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

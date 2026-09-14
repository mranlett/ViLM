import SwiftUI
import LibraryCore

struct MetadataHealthDashboardView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL

    var duplicateView: AnyView?
    var orphanView: AnyView?
    var identityGapsView: AnyView?
    var identityUpgradeView: AnyView?
    var studioConflictsView: AnyView?
    
    @State private var showingDuplicates = false
    @State private var showingOrphans = false
    @State private var showingIdentityGaps = false
    @State private var showingIdentityUpgrade = false
    @State private var showingStudioConflicts = false
    
    @State private var preflight: MigrationPreflight?
    @State private var orphansCount: Int = 0
    @State private var identityGapsCount: Int = 0
    @State private var unkeyableCount: Int = 0
    @State private var duplicatesCount: Int = 0
    
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Metadata Health Dashboard")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh") { Task { await run() } }
                            .disabled(isLoading)
                    }
                }
                .task { await run() }
        }
        .macSheet(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showingDuplicates) { if let view = duplicateView { view } }
        .sheet(isPresented: $showingOrphans) { if let view = orphanView { view } }
        .sheet(isPresented: $showingIdentityGaps) { if let view = identityGapsView { view } }
        .sheet(isPresented: $showingIdentityUpgrade) { if let view = identityUpgradeView { view } }
        .sheet(isPresented: $showingStudioConflicts) { if let view = studioConflictsView { view } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Checking library health…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section(
                    header: Text("Migration Readiness"),
                    footer: Text("Clear these blockers to allow the UUID identity upgrade to proceed.")
                ) {
                    if let preflight {
                        if preflight.canProceed {
                            Label("Ready for Identity Upgrade!", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Button("Run Identity Upgrade…") {
                                showingIdentityUpgrade = true
                            }
                        } else {
                            if duplicatesCount > 0 {
                                HStack {
                                    Label("\(duplicatesCount) Duplicate Performers", systemImage: "person.2.badge.gearshape")
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button("Merge Duplicates") {
                                        showingDuplicates = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            
                            if unkeyableCount > 0 {
                                HStack {
                                    Label("\(unkeyableCount) Unkeyable Profiles", systemImage: "questionmark.folder")
                                        .foregroundStyle(.red)
                                    Spacer()
                                    Text("Requires manual DB fix")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(
                    header: Text("Clean-Up Utilities"),
                    footer: Text("Recommended tools to keep your metadata clean.")
                ) {
                    HStack {
                        Label(orphansCount > 0 ? "\(orphansCount) Orphaned Profiles Found" : "No Orphaned Profiles", systemImage: "trash.slash")
                            .foregroundStyle(orphansCount > 0 ? .orange : .green)
                        Spacer()
                        Button("Remove Orphans") {
                            showingOrphans = true
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        Label(identityGapsCount > 0 ? "\(identityGapsCount) Identity Gaps Found" : "No Identity Gaps", systemImage: "link.badge.plus")
                            .foregroundStyle(identityGapsCount > 0 ? .orange : .green)
                        Spacer()
                        Button("Fix Gaps") {
                            showingIdentityGaps = true
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if let _ = studioConflictsView {
                        HStack {
                            Label("Studio Spelling/Conflicts", systemImage: "building.2.crop.circle")
                            Spacer()
                            Button("Audit Studios") {
                                showingStudioConflicts = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private func run() async {
        isLoading = true
        do {
            let url = libraryURL
            
            // Run preflight
            let result = try await Task.detached(priority: .utility) {
                try LibraryStore(at: url).migrationPreflight()
            }.value
            
            self.preflight = result
            self.duplicatesCount = result.duplicates.count
            self.unkeyableCount = result.unkeyableProfiles.count
            
            // Run orphans audit
            let orphans = try await Task.detached(priority: .utility) {
                try LibraryStore(at: url).auditOrphans()
            }.value
            self.orphansCount = orphans.values.flatMap { $0 }.count
            
            // Run identity gaps check
            let gaps = try await Task.detached(priority: .utility) {
                try LibraryStore(at: url).namelessNodes()
            }.value
            self.identityGapsCount = gaps.count
            
        } catch {
            print("Error checking library health: \(error)")
        }
        isLoading = false
    }
}

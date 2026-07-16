import SwiftUI
import LibraryCore

struct SettingsView: View {
    @AppStorage("defaultHomePage") private var defaultHomePage: String = "dashboard"
    @Environment(\.dismiss) private var dismiss
    
    var libraryURL: URL?
    
    var onOpenLibrary: (() -> Void)?
    var onCheckForChanges: (() -> Void)?
    var onAuditFileName: (() -> Void)?
    var onFindDuplicates: (() -> Void)?
    var onMigrateEpisodes: (() -> Void)?
    var onTagCleanup: (() -> Void)?
    var onRebuildFaceIndex: (() -> Void)?
    var onExportActorLibrary: (() -> Void)?
    var onImportActorLibrary: (() -> Void)?
    var onSelectAsset: ((Asset.ID) -> Void)?
    var onSelectActor: ((String) -> Void)?
    var onSelectTag: ((String) -> Void)?
    var onOpenTagGallery: (() -> Void)?

    @State private var isShowingHelp = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Startup Preferences")) {
                    Picker("Default Home Page", selection: $defaultHomePage) {
                        Text("Dashboard").tag("dashboard")
                        Text("All Assets").tag("allAssets")
                        Text("Actors Gallery").tag("actorGallery")
                        Text("Tags Gallery").tag("tagGallery")
                    }
                }
                
                Section(header: Text("Information")) {
                    NavigationLink {
                        // Deep-link handlers fire immediately; ContentView
                        // defers the navigation until the sheet's onDismiss,
                        // so no timing guess is involved.
                        LibraryStatsView(
                            libraryURL: libraryURL,
                            onSelectAsset: { onSelectAsset?($0) },
                            onSelectActor: { onSelectActor?($0) },
                            onSelectTag: { onSelectTag?($0) },
                            onOpenTagGallery: { onOpenTagGallery?() }
                        )
                    } label: {
                        Label("Library Statistics", systemImage: "chart.bar.doc.horizontal")
                    }

                    Button(action: { isShowingHelp = true }) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                }
                
                Section(header: Text("Library Management")) {
                    Button(action: {
                        dismiss()
                        onOpenLibrary?()
                    }) {
                        Label("Open Library", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        dismiss()
                        onCheckForChanges?()
                    }) {
                        Label("Check for Changes", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        dismiss()
                        onAuditFileName?()
                    }) {
                        Label("File Name Audit", systemImage: "text.magnifyingglass")
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        dismiss()
                        onFindDuplicates?()
                    }) {
                        Label("Find Duplicates", systemImage: "square.on.square.dashed")
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        dismiss()
                        onMigrateEpisodes?()
                    }) {
                        Label("Migrate Episode Info", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        dismiss()
                        onTagCleanup?()
                    }) {
                        Label("Tag & Actor Cleanup", systemImage: "paintbrush")
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        dismiss()
                        onRebuildFaceIndex?()
                    }) {
                        Label("Rebuild Face Index", systemImage: "person.crop.rectangle.stack")
                    }
                    .buttonStyle(.plain)
                }

                Section(header: Text("Actor Library Merge"), footer: Text("Move enriched actor bios and photos from another library (e.g. a portable copy) into this one without losing existing work.")) {
                    Button(action: {
                        dismiss()
                        onExportActorLibrary?()
                    }) {
                        Label("Export Actor Library For Merge", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        dismiss()
                        onImportActorLibrary?()
                    }) {
                        Label("Import and Merge Actor Library", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { isShowingHelp = true }) {
                        Image(systemName: "questionmark.circle")
                    }
                    .help("Help")
                    .accessibilityLabel("Help")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingHelp) {
                HelpView(initialTopicID: HelpContent.settings.id)
            }
        }
        .frame(minWidth: 300, minHeight: 300)
    }
}

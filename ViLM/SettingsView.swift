import SwiftUI
import LibraryCore

struct SettingsView: View {
    @AppStorage("defaultHomePage") private var defaultHomePage: String = "dashboard"
    @Environment(\.dismiss) private var dismiss
    
    var libraryURL: URL?
    
    var onOpenLibrary: (() -> Void)?
    var onCheckForChanges: (() -> Void)?
    var onAuditFileName: (() -> Void)?
    var onTagCleanup: (() -> Void)?
    var onSelectAsset: ((Asset.ID) -> Void)?
    var onSelectActor: ((String) -> Void)?
    
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
                        LibraryStatsView(
                            libraryURL: libraryURL,
                            onSelectAsset: { assetID in
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    onSelectAsset?(assetID)
                                }
                            },
                            onSelectActor: { actorID in
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    onSelectActor?(actorID)
                                }
                            }
                        )
                    } label: {
                        Label("Library Statistics", systemImage: "chart.bar.doc.horizontal")
                    }
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
                        onTagCleanup?()
                    }) {
                        Label("Tag & Actor Cleanup", systemImage: "paintbrush")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 300)
    }
}

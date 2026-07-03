import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultHomePage") private var defaultHomePage: String = "dashboard"
    @Environment(\.dismiss) private var dismiss
    
    var onOpenLibrary: (() -> Void)?
    var onCheckForChanges: (() -> Void)?
    var onAuditFileName: (() -> Void)?
    
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

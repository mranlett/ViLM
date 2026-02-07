import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

// Ensure this is outside the struct so other files can access it
enum SidebarItem: Hashable {
    case allAssets
    case actor(String)
    case tag(String)
}

struct ContentView: View {
    @State private var assets: [Asset] = []
    @State private var selectedLibraryURL: URL?
    @State private var selectedAsset: Asset?
    @State private var sidebarSelection: SidebarItem? = .allAssets
    @State private var searchText = ""
    @State private var gridRefreshID = UUID()
    
    // iOS picker presentation
#if os(iOS)
    @State private var isShowingLibraryPicker = false
#endif
    
    // ✅ Keep security scope open for the active library
    @State private var activeSecurityScopedURL: URL?
    @State private var hasActiveSecurityScope: Bool = false
    
    private let bookmarkKey = "libraryBookmark"
    
    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection, assets: assets, onOpenLibrary: openLibrary)
        } content: {
            AssetsGridView(
                assets: assets,
                sidebarSelection: sidebarSelection,
                searchText: $searchText,
                selectedAsset: $selectedAsset,
                libraryURL: selectedLibraryURL,
                refreshID: gridRefreshID
            )
#if os(iOS)
            .navigationDestination(for: UUID.self) { id in
                if let asset = assets.first(where: { $0.id == id }) {
                    InspectorView(
                        asset: asset,
                        assets: $assets,
                        selectedAsset: $selectedAsset,
                        gridRefreshID: $gridRefreshID,
                        libraryURL: selectedLibraryURL
                    )
                } else {
                    ContentUnavailableView(
                        "Not Found",
                        systemImage: "questionmark.folder",
                        description: Text("That asset is no longer available.")
                    )
                }
            }
#endif
        } detail: {
            if let asset = selectedAsset {
                InspectorView(
                    asset: asset,
                    assets: $assets,
                    selectedAsset: $selectedAsset,
                    gridRefreshID: $gridRefreshID,
                    libraryURL: selectedLibraryURL
                )
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select a video to see details")
                )
            }
        }
        .onAppear { loadLastLibrary() }
        .onDisappear { endSecurityScope() }
        
#if os(iOS)
        .sheet(isPresented: $isShowingLibraryPicker) {
            LibraryFolderPicker { pickedURL in
                guard let pickedURL else { return }
                processFolder(at: pickedURL)
            }
        }
#endif
    }
    
    // MARK: - Library Logic
    
    func openLibrary() {
#if os(macOS)
        openLibrary_macOS()
#else
        isShowingLibraryPicker = true
#endif
    }
    
#if os(macOS)
    private func openLibrary_macOS() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select Library"
        
        if panel.runModal() == .OK, let url = panel.url {
            processFolder(at: url)
        }
    }
#endif
    
    // ✅ Keep security scope open as long as this library is selected
    private func beginSecurityScope(for url: URL) {
        // Stop previous if different
        if let current = activeSecurityScopedURL, current != url, hasActiveSecurityScope {
            current.stopAccessingSecurityScopedResource()
            hasActiveSecurityScope = false
            activeSecurityScopedURL = nil
        }
        
        // Already active
        if hasActiveSecurityScope, activeSecurityScopedURL == url { return }
        
        // Start for new URL
        let started = url.startAccessingSecurityScopedResource()
        if started {
            activeSecurityScopedURL = url
            hasActiveSecurityScope = true
        } else {
            // Not always fatal on macOS; on iOS it often means you picked something non-scoped
            print("⚠️ startAccessingSecurityScopedResource() returned false for: \(url)")
        }
    }
    
    private func endSecurityScope() {
        if let current = activeSecurityScopedURL, hasActiveSecurityScope {
            current.stopAccessingSecurityScopedResource()
        }
        hasActiveSecurityScope = false
        activeSecurityScopedURL = nil
    }
    
    func loadLastLibrary() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        
        var isStale = false
        do {
#if os(macOS)
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
#else
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [], // ✅ iOS: no .withSecurityScope
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
#endif
            
            if isStale {
                // Refresh bookmark if needed
#if os(macOS)
                if let newData = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(newData, forKey: bookmarkKey)
                }
#else
                if let newData = try? url.bookmarkData(
                    options: [], // or [.minimalBookmark]
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(newData, forKey: bookmarkKey)
                }
#endif
            }
            
            // ✅ keep scope open for ongoing access
            beginSecurityScope(for: url)
            
            let store = try LibraryStore(at: url)
            self.selectedLibraryURL = url
            self.assets = try store.fetchAllAssets()
            self.sidebarSelection = .allAssets
            
        } catch {
            print("Bookmark resolution failed: \(error)")
        }
    }
    
    func processFolder(at url: URL) {
        // ✅ keep scope open for the life of the active library (no defer stop)
        beginSecurityScope(for: url)
        
        let catalogURL = url.appendingPathComponent(".catalog")
        let thumbsURL = catalogURL.appendingPathComponent("thumbnails")
        
        // IMPORTANT: align with ContactSheetService output
        let sheetsURL = catalogURL.appendingPathComponent("contactSheets")
        
        do {
            try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sheetsURL, withIntermediateDirectories: true)
            
            let store = try LibraryStore(at: url)
            let scanner = LibraryScanner(store: store)
            let service = ContactSheetService(store: store)
            
            Task {
                do {
                    try await scanner.scan(at: url)
                    let initialAssets = try store.fetchAllAssets()
                    
                    await MainActor.run {
                        self.selectedLibraryURL = url
                        self.assets = initialAssets
                        self.sidebarSelection = .allAssets
                        
#if os(macOS)
                        if let bookmarkData = try? url.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
                        }
#else
                        if let bookmarkData = try? url.bookmarkData(
                            options: [], // or [.minimalBookmark]
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
                        }
#endif
                    }
                    
                    // Generate images (MVP: sequential; parallelize later if desired)
                    for asset in initialAssets {
                        try await service.generateContactSheet(for: asset, libraryURL: url)
                        try await service.generateSingleThumbnail(for: asset, libraryURL: url)
                    }
                    
                    // FINAL REFRESH: ensures the UI sees the new files on disk
                    let finalAssets = try store.fetchAllAssets()
                    await MainActor.run {
                        self.assets = finalAssets
                        self.gridRefreshID = UUID()
                        print("✅ UI Refreshed with generated images.")
                    }
                } catch {
                    print("Scan failed: \(error)")
                }
            }
        } catch {
            print("Init failed: \(error)")
        }
    }
}

#if os(iOS)
// MARK: - iOS Folder Picker (UIDocumentPickerViewController)
private struct LibraryFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
#endif

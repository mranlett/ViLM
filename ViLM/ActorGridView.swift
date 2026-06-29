import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

struct ActorGridView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    
    @State private var actorProfiles: [String: EntityProfile] = [:]
    @State private var alphaFilter: Character? = nil
    
    // CSV Export/Import
    @State private var isShowingExportPicker = false
    @State private var isShowingImportPicker = false
    @State private var csvDocument: CSVDocument?
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        var unique = Set(actorTags)
        
        // Include any actors that have saved profiles, even if they have 0 matched videos
        for key in actorProfiles.keys {
            if key.hasPrefix("actor:") {
                unique.insert(String(key.dropFirst(6)))
            }
        }
        
        return Array(unique).sorted()
    }
    
    var filteredActors: [String] {
        guard let letter = alphaFilter else { return allUniqueActors }
        return allUniqueActors.filter { $0.uppercased().hasPrefix(String(letter)) }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AlphaPickerView(filter: $alphaFilter)
                    .padding(.horizontal)
                    .padding(.bottom)
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 20) {
                    ForEach(filteredActors, id: \.self) { actor in
                        let isSelected = sidebarSelection.contains(.actor(actor))
                        #if os(iOS)
                        Button(action: {
                            sidebarSelection = [.actor(actor)]
                        }) {
                            ActorGridItemView(
                                actor: actor,
                                profile: actorProfiles["actor:\(actor)"],
                                assetsCount: assets.filter { $0.actors.contains(actor) }.count,
                                isSelected: isSelected,
                                libraryURL: libraryURL
                            )
                        }
                        .buttonStyle(.plain)
                        #else
                        Button(action: {
                            toggleSelection(item: .actor(actor))
                        }) {
                            ActorGridItemView(
                                actor: actor,
                                profile: actorProfiles["actor:\(actor)"],
                                assetsCount: assets.filter { $0.actors.contains(actor) }.count,
                                isSelected: isSelected,
                                libraryURL: libraryURL
                            )
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Actors Gallery")
        .toolbar {
            #if !os(iOS)
            let selectedActorsCount = sidebarSelection.filter { item in
                if case .actor = item { return true }
                return false
            }.count
            
            if selectedActorsCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        sidebarSelection.remove(.actorGallery)
                    }) {
                        Text("View Matches")
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            #endif
            
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export to CSV", systemImage: "square.and.arrow.up") {
                        exportCSV()
                    }
                    Button("Import from CSV", systemImage: "square.and.arrow.down") {
                        isShowingImportPicker = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileExporter(
            isPresented: $isShowingExportPicker,
            document: csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "Actors.csv"
        ) { result in
            switch result {
            case .success(let url):
                print("Exported to \(url)")
            case .failure(let error):
                print("Export failed: \(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $isShowingImportPicker,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importCSV(from: url)
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
        .onAppear {
            fetchProfiles()
        }
        .onChange(of: assets.count) { old, new in
            fetchProfiles()
        }
    }
    
    private func toggleSelection(item: SidebarItem) {
        if sidebarSelection.contains(item) {
            sidebarSelection.remove(item)
        } else {
            sidebarSelection.remove(.allAssets)
            sidebarSelection.insert(item)
        }
    }
    
    private func fetchProfiles() {
        guard let url = libraryURL else { return }
        do {
            let store = try LibraryStore(at: url)
            let allProfiles = try store.fetchAllEntityProfiles()
            for profile in allProfiles {
                if profile.id.hasPrefix("actor:") {
                    actorProfiles[profile.id] = profile
                }
            }
        } catch {
            print("Failed to fetch actor profiles: \(error)")
        }
    }
    
    // MARK: - CSV Logic
    
    private func exportCSV() {
        var csvString = "Name,Bio,PhotoURL,HomePage\n"
        for actor in allUniqueActors {
            let profile = actorProfiles["actor:\(actor)"]
            let name = escapeCSV(actor)
            let bio = escapeCSV(profile?.bio ?? "")
            let photoUrl = escapeCSV(profile?.photoUrl ?? "")
            let homePage = escapeCSV(profile?.homePage ?? "")
            csvString.append("\(name),\(bio),\(photoUrl),\(homePage)\n")
        }
        csvDocument = CSVDocument(text: csvString)
        isShowingExportPicker = true
    }
    
    private func escapeCSV(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            escaped = "\"\(escaped)\""
        }
        return escaped
    }
    
    private func importCSV(from url: URL) {
        guard let libraryURL = libraryURL else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else { return }
            
            let store = try LibraryStore(at: libraryURL)
            let records = parseCSV(content)
            
            // Assuming header is first line
            let rows = records.dropFirst()
            
            for columns in rows {
                if columns.count >= 4 {
                    let name = columns[0]
                    if name.isEmpty { continue }
                    
                    let bio = columns[1].isEmpty ? nil : columns[1]
                    let photoUrl = columns[2].isEmpty ? nil : columns[2]
                    let homePage = columns[3].isEmpty ? nil : columns[3]
                    
                    let profile = EntityProfile(id: "actor:\(name)", bio: bio, photoUrl: photoUrl, homePage: homePage)
                    try store.saveEntityProfile(profile)
                }
            }
            
            fetchProfiles()
            
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func parseCSV(_ content: String) -> [[String]] {
        var results: [[String]] = []
        var currentRow: [String] = []
        var currentCell = ""
        var insideQuotes = false
        
        let characters = Array(content)
        var i = 0
        while i < characters.count {
            let char = characters[i]
            
            if char == "\"" {
                if insideQuotes && i + 1 < characters.count && characters[i + 1] == "\"" {
                    currentCell.append("\"")
                    i += 1
                } else {
                    insideQuotes.toggle()
                }
            } else if char == "," && !insideQuotes {
                currentRow.append(currentCell)
                currentCell = ""
            } else if (char == "\n" || char == "\r") && !insideQuotes {
                if char == "\r" && i + 1 < characters.count && characters[i + 1] == "\n" {
                    i += 1
                }
                currentRow.append(currentCell)
                results.append(currentRow)
                currentRow = []
                currentCell = ""
            } else {
                currentCell.append(char)
            }
            i += 1
        }
        if !currentCell.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentCell)
            results.append(currentRow)
        }
        return results
    }
}

struct ActorGridItemView: View {
    let actor: String
    let profile: EntityProfile?
    let assetsCount: Int
    let isSelected: Bool
    let libraryURL: URL?
    
    var body: some View {
        VStack {
            if let photoUrlString = profile?.photoUrl {
                ProfileImageView(libraryURL: libraryURL, entityId: "actor:\(actor)", photoUrl: photoUrlString) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                    )
            }
            
            Text(actor)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 8)
            
            Text("\(assetsCount) Video\(assetsCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .cornerRadius(12)
        #if os(macOS)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}

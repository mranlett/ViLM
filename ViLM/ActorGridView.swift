import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

struct ActorGridView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    @Binding var selectedAssetIDs: Set<Asset.ID>
    let libraryURL: URL?
    @Binding var pendingFilter: ActorFilterCriteria?
    @Binding var pendingSort: ActorFilterCriteria.SortOption?
    @Binding var pendingSortAscending: Bool?
    
    @State private var actorProfiles: [String: EntityProfile] = [:]
    @State private var akaMap: [String: String] = [:]
    @State private var profileImageFileNames: Set<String> = []
    @State private var alphaFilter: Character? = nil
    @State private var hasLoadedDefaults = false
    @Environment(\.usesStackNavigation) private var usesStackNavigation
    
    @AppStorage("defaultActorFiltersStr") private var defaultFilterCriteriaStr: String = ""
    private var defaultFilterCriteria: ActorFilterCriteria {
        get {
            guard let data = defaultFilterCriteriaStr.data(using: .utf8),
                  let result = try? JSONDecoder().decode(ActorFilterCriteria.self, from: data) else {
                return ActorFilterCriteria()
            }
            return result
        }
    }
    @State private var filterCriteria = ActorFilterCriteria()
    @State private var isShowingFilterBuilder = false
    @State private var isSelectionMode = false
    @State private var searchText = ""
    
    var uniqueGenders: [String] {
        let values = actorProfiles.values.compactMap { $0.gender }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted()
    }
    
    var uniqueHairColors: [String] {
        let values = actorProfiles.values.compactMap { $0.hairColor }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted()
    }
    
    var uniqueCountries: [String] {
        let values = actorProfiles.values.compactMap { $0.countryOfOrigin }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted()
    }
    
    // CSV Export/Import
    @State private var isShowingExportPicker = false
    @State private var isShowingImportPicker = false
    @State private var csvDocument: CSVDocument?
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        var unique = Set<String>()
        
        for rawName in actorTags {
            if let mainName = akaMap[rawName] {
                unique.insert(mainName)
            } else {
                unique.insert(rawName)
            }
        }
        
        // Include any actors that have saved profiles, even if they have 0 matched videos
        for key in actorProfiles.keys {
            if key.hasPrefix("actor:") {
                let name = String(key.dropFirst(6))
                if let mainName = akaMap[name] {
                    unique.insert(mainName)
                } else {
                    unique.insert(name)
                }
            }
        }
        
        return Array(unique).sorted()
    }
    
    var allUniqueTags: [String] {
        let values = actorProfiles.values.flatMap { $0.tags }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted()
    }
    
    var filteredActors: [String] {
        var result = allUniqueActors
        
        if !searchText.isEmpty {
            result = result.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        
        if let letter = alphaFilter {
            result = result.filter { $0.uppercased().hasPrefix(String(letter)) }
        }
        
        if filterCriteria.showMissingPhotosOnly {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                if let _ = profile?.photoUrl { return false }
                
                let safeId = "actor:\(actor)".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
                if profileImageFileNames.contains("\(safeId).jpg") {
                    return false
                }
                return !profileImageFileNames.contains { $0.hasPrefix("\(safeId)_") }
            }
        }
        
        if filterCriteria.showMissingGenderOnly {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                return (profile?.gender ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        
        if filterCriteria.showNeedingAttentionOnly {
            result = result.filter { actor in
                let safeId = "actor:\(actor)".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
                let profile = actorProfiles["actor:\(actor)"]
                let hasLocalPhoto = profileImageFileNames.contains("\(safeId).jpg") || profileImageFileNames.contains { $0.hasPrefix("\(safeId)_") }
                let hasPhoto = hasLocalPhoto || profile?.photoUrl != nil
                let hasBio = !(profile?.bio ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                let hasTags = !(profile?.tags ?? []).isEmpty
                return !hasPhoto || !hasBio || !hasTags
            }
        }
        
        if !filterCriteria.selectedGenders.isEmpty {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let values = profile?.gender?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                return !filterCriteria.selectedGenders.isDisjoint(with: values)
            }
        }
        
        if !filterCriteria.hairColor.isEmpty {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let values = profile?.hairColor?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                return values.contains(filterCriteria.hairColor.lowercased())
            }
        }
        
        if !filterCriteria.country.isEmpty {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let values = profile?.countryOfOrigin?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                return values.contains(filterCriteria.country.lowercased())
            }
        }
        
        if !filterCriteria.selectedTags.isEmpty {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let actorTags = Set(profile?.tags ?? [])
                if filterCriteria.tagsLogic == .and {
                    return filterCriteria.selectedTags.isSubset(of: actorTags)
                } else {
                    return !filterCriteria.selectedTags.isDisjoint(with: actorTags)
                }
            }
        }
        
        if let minVid = filterCriteria.minVideos {
            result = result.filter { actor in assetsCount(for: actor) >= minVid }
        }
        if let maxVid = filterCriteria.maxVideos {
            result = result.filter { actor in assetsCount(for: actor) <= maxVid }
        }
        if let minAge = filterCriteria.minAge {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                return (profile?.age ?? 0) >= minAge
            }
        }
        if let maxAge = filterCriteria.maxAge {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                if let age = profile?.age { return age <= maxAge }
                return false
            }
        }
        
        result.sort { a, b in
            let factor = filterCriteria.sortDescending ? -1 : 1
            switch filterCriteria.sortBy {
            case .name:
                return factor == 1 ? a < b : a > b
            case .age:
                let ageA = actorProfiles["actor:\(a)"]?.age ?? 0
                let ageB = actorProfiles["actor:\(b)"]?.age ?? 0
                if ageA != ageB { return factor == 1 ? ageA < ageB : ageA > ageB }
                return factor == 1 ? a < b : a > b
            case .videoCount:
                let countA = assetsCount(for: a)
                let countB = assetsCount(for: b)
                if countA != countB { return factor == 1 ? countA < countB : countA > countB }
                return factor == 1 ? a < b : a > b
            case .dateAdded:
                let dateA = actorProfiles["actor:\(a)"]?.createdAt ?? Date.distantPast
                let dateB = actorProfiles["actor:\(b)"]?.createdAt ?? Date.distantPast
                if dateA != dateB { return factor == 1 ? dateA < dateB : dateA > dateB }
                return factor == 1 ? a < b : a > b
            }
        }
        
        return result
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
                        interactiveGridItem(for: actor, isSelected: isSelected)
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingFilterBuilder) {
            ActorFilterBuilderView(
                allUniqueGenders: uniqueGenders,
                allUniqueHairColors: uniqueHairColors,
                allUniqueCountries: uniqueCountries,
                allUniqueTags: allUniqueTags,
                criteria: $filterCriteria
            )
        }
        .navigationTitle("Actors Gallery")
        .searchable(text: $searchText, prompt: "Search Actors")
        .toolbar {
            let selectedActorsCount = sidebarSelection.filter { item in
                if case .actor = item { return true }
                return false
            }.count
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    withAnimation {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            let actors = sidebarSelection.filter { if case .actor = $0 { return true }; return false }
                            for a in actors { sidebarSelection.remove(a) }
                        }
                    }
                }) {
                    Text(isSelectionMode ? "Cancel" : "Select")
                }
            }
            
            if isSelectionMode && selectedActorsCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        sidebarSelection.remove(.actorGallery)
                        isSelectionMode = false
                    }) {
                        Text("View Matches")
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    let selectedActors = sidebarSelection.compactMap { item -> String? in
                        if case .actor(let a) = item { return a }
                        return nil
                    }
                    NavigationLink(value: AppRoute.batchActors(Set(selectedActors))) {
                        Text("Edit \(selectedActorsCount) Actor\(selectedActorsCount == 1 ? "" : "s")")
                            .font(.headline)
                    }
                }
                #endif
            }
            
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $filterCriteria.sortBy) {
                        ForEach(ActorFilterCriteria.SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Toggle("Descending", isOn: $filterCriteria.sortDescending)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: { isShowingFilterBuilder = true }) {
                    Label("Filter", systemImage: filterCriteria.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            
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
        .onChange(of: pendingFilter) { _, newValue in
            if let newFilter = newValue {
                filterCriteria = newFilter
                pendingFilter = nil
            }
        }
        .onChange(of: pendingSort) { _, newValue in
            if let newSort = newValue {
                filterCriteria.sortBy = newSort
                pendingSort = nil
            }
        }
        .onChange(of: pendingSortAscending) { _, newValue in
            if let newAsc = newValue {
                filterCriteria.sortDescending = !newAsc
                pendingSortAscending = nil
            }
        }
        .onAppear {
            if !hasLoadedDefaults {
                filterCriteria = defaultFilterCriteria
                hasLoadedDefaults = true
            }
            if let newFilter = pendingFilter {
                filterCriteria = newFilter
                pendingFilter = nil
            }
            if let newSort = pendingSort {
                filterCriteria.sortBy = newSort
                pendingSort = nil
            }
            if let newAsc = pendingSortAscending {
                filterCriteria.sortDescending = !newAsc
                pendingSortAscending = nil
            }
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
            // The detail pane shows a selected video with priority over a
            // selected actor, so clear the video selection when picking an actor.
            selectedAssetIDs.removeAll()
        }
    }

    // Plain taps outside batch-selection mode replace the actor selection
    // instead of accumulating it, so the detail pane follows the tapped actor.
    private func selectActor(_ actor: String) {
        var newSelection = sidebarSelection.filter { item in
            if case .actor = item { return false }
            return true
        }
        newSelection.remove(.allAssets)
        newSelection.insert(.actor(actor))
        sidebarSelection = newSelection
        selectedAssetIDs.removeAll()
    }
    
    @ViewBuilder
    private func interactiveGridItem(for actor: String, isSelected: Bool) -> some View {
#if os(iOS)
        if isSelectionMode {
            Button(action: {
                toggleSelection(item: .actor(actor))
            }) {
                ActorGridItemView(
                    actor: actor,
                    profile: actorProfiles["actor:\(actor)"],
                    assetsCount: assetsCount(for: actor),
                    isSelected: isSelected,
                    libraryURL: libraryURL
                )
            }
            .buttonStyle(.plain)
        } else if !usesStackNavigation {
            Button(action: {
                selectActor(actor)
            }) {
                ActorGridItemView(
                    actor: actor,
                    profile: actorProfiles["actor:\(actor)"],
                    assetsCount: assetsCount(for: actor),
                    isSelected: isSelected,
                    libraryURL: libraryURL
                )
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.entityProfile(category: "actor", name: actor)) {
                ActorGridItemView(
                    actor: actor,
                    profile: actorProfiles["actor:\(actor)"],
                    assetsCount: assetsCount(for: actor),
                    isSelected: isSelected,
                    libraryURL: libraryURL
                )
            }
            .buttonStyle(.plain)
        }
#else
        Button(action: {
            if isSelectionMode {
                toggleSelection(item: .actor(actor))
            } else {
                selectActor(actor)
            }
        }) {
            ActorGridItemView(
                actor: actor,
                profile: actorProfiles["actor:\(actor)"],
                assetsCount: assetsCount(for: actor),
                isSelected: isSelected,
                libraryURL: libraryURL
            )
        }
        .buttonStyle(.plain)
#endif
    }
    
    private func assetsCount(for actor: String) -> Int {
        let profile = actorProfiles["actor:\(actor)"]
        let akas = Set(profile?.akas ?? [])
        return assets.filter { asset in
            if asset.actors.contains(actor) { return true }
            return !Set(asset.actors).isDisjoint(with: akas)
        }.count
    }
    
    private func fetchProfiles() {
        guard let url = libraryURL else { return }
        do {
            let store = try LibraryStore(at: url)
            let allProfiles = try store.fetchAllEntityProfiles()
            var newActorProfiles: [String: EntityProfile] = [:]
            for profile in allProfiles {
                if profile.id.hasPrefix("actor:") {
                    newActorProfiles[profile.id] = profile
                }
            }
            actorProfiles = newActorProfiles
            
            var newAkaMap: [String: String] = [:]
            for profile in newActorProfiles.values {
                let mainName = String(profile.id.dropFirst(6))
                for aka in profile.akas {
                    newAkaMap[aka] = mainName
                }
            }
            akaMap = newAkaMap
            
            let profilesDir = url.appendingPathComponent(".catalog/profiles")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path) {
                profileImageFileNames = Set(files.filter { $0.hasSuffix(".jpg") })
            }
        } catch {
            print("Failed to fetch actor profiles: \(error)")
        }
    }
    
    // MARK: - CSV Logic
    
    private func exportCSV() {
        var csvString = "Name,Bio,PhotoURL,HomePage,Gender,HairColor,BirthYear,CountryOfOrigin\n"
        for actor in allUniqueActors {
            let profile = actorProfiles["actor:\(actor)"]
            let name = escapeCSV(actor)
            let bio = escapeCSV(profile?.bio ?? "")
            let photoUrl = escapeCSV("")
            let homePage = escapeCSV(profile?.homePage ?? "")
            let gender = escapeCSV(profile?.gender ?? "")
            let hairColor = escapeCSV(profile?.hairColor ?? "")
            let birthYear = escapeCSV(profile?.birthYear.map { String($0) } ?? "")
            let country = escapeCSV(profile?.countryOfOrigin ?? "")
            
            csvString.append("\(name),\(bio),\(photoUrl),\(homePage),\(gender),\(hairColor),\(birthYear),\(country)\n")
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
                    
                    var gender: String? = nil
                    var hairColor: String? = nil
                    var birthYear: Int? = nil
                    var country: String? = nil
                    
                    if columns.count >= 8 {
                        gender = columns[4].isEmpty ? nil : columns[4]
                        hairColor = columns[5].isEmpty ? nil : columns[5]
                        birthYear = Int(columns[6])
                        country = columns[7].isEmpty ? nil : columns[7]
                    }
                    
                    let profile = EntityProfile(
                        id: "actor:\(name)",
                        bio: bio,
                        photoUrl: photoUrl,
                        homePage: homePage,
                        gender: gender,
                        hairColor: hairColor,
                        birthYear: birthYear,
                        countryOfOrigin: country
                    )
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
            ProfileImageView(libraryURL: libraryURL, entityId: "actor:\(actor)", photoUrl: profile?.photoUrl) { image in
                Color.clear
                    .overlay(
                        image
                            .resizable()
                            .scaledToFill(),
                        alignment: .top
                    )
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                        )
                    if profile?.photoUrl != nil {
                        ProgressView()
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            
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

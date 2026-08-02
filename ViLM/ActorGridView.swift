// ActorGridView.swift
// The Actor Gallery screen: searchable (debounced), A-Z and criteria-filtered
// grid of actor cards, with multi-select batch editing and the CSV
// export/import maintenance tools.

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

    // Loaded once at the ContentView level and shared across every screen
    // that needs actor profiles, instead of each screen independently
    // re-fetching the same data on its own `.onAppear`.
    let entityProfiles: [String: EntityProfile]
    let profileImageFileNames: Set<String>
    let akaMap: [String: String]
    var onPullToRefresh: () async -> Void = {}

    // Filtered down to actor: profiles once per entityProfiles change
    // (see deriveActorProfiles()), rather than on every one of the many
    // dictionary lookups below.
    @State private var actorProfiles: [String: EntityProfile] = [:]
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
    @State private var isShowingHelp = false
    @State private var searchText = ""
    // The search field binds to `searchText` directly for instant typing
    // feedback; `filteredActors` reacts to this debounced copy instead, so a
    // fast typist doesn't re-filter the whole actor list on every keystroke.
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?

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
    @State private var isImportingCSV = false
    
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

        if !debouncedSearchText.isEmpty {
            result = result.filter { $0.localizedCaseInsensitiveContains(debouncedSearchText) }
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
            // Match case-insensitively: the actor's stored gender values are
            // lowercased below, so the selected filter values must be too —
            // otherwise "Male" (from the filter) never equals "male" and the
            // filter returns nothing. Mirrors the hair-color/country filters.
            let selectedGenders = Set(filterCriteria.selectedGenders.map { $0.lowercased() })
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let values = profile?.gender?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                return !selectedGenders.isDisjoint(with: values)
            }
        }
        
        if filterCriteria.matchEmptyHairColor {
            result = result.filter { actor in
                (actorProfiles["actor:\(actor)"]?.hairColor ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        } else if !filterCriteria.hairColor.isEmpty {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let values = profile?.hairColor?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                return values.contains(filterCriteria.hairColor.lowercased())
            }
        }

        if filterCriteria.matchEmptyCountry {
            result = result.filter { actor in
                (actorProfiles["actor:\(actor)"]?.countryOfOrigin ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        } else if !filterCriteria.country.isEmpty {
            result = result.filter { actor in
                let profile = actorProfiles["actor:\(actor)"]
                let values = profile?.countryOfOrigin?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                return values.contains(filterCriteria.country.lowercased())
            }
        }

        if filterCriteria.matchEmptyBirthYear {
            // "No date of birth" — actors with no birth year set (including
            // those with no profile at all).
            result = result.filter { actor in
                actorProfiles["actor:\(actor)"]?.birthYear == nil
            }
        }

        if let minRating = filterCriteria.minRating {
            result = result.filter { actor in
                (actorProfiles["actor:\(actor)"]?.rating ?? 0) >= minRating
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
            case .rating:
                let ratingA = actorProfiles["actor:\(a)"]?.rating ?? 0
                let ratingB = actorProfiles["actor:\(b)"]?.rating ?? 0
                if ratingA != ratingB { return factor == 1 ? ratingA < ratingB : ratingA > ratingB }
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
                
                if filteredActors.isEmpty {
                    if allUniqueActors.isEmpty {
                        ContentUnavailableView(
                            "No Actors Yet",
                            systemImage: "person.2",
                            description: Text("Actors tagged on videos will appear here.")
                        )
                        .padding(.top, 80)
                    } else {
                        ContentUnavailableView(
                            "No Matching Actors",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("No actors match the current search, letter, or filters.")
                        )
                        .padding(.top, 80)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 20) {
                        ForEach(filteredActors, id: \.self) { actor in
                            let isSelected = sidebarSelection.contains(.actor(actor))
                            interactiveGridItem(for: actor, isSelected: isSelected)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .refreshable { await onPullToRefresh() }
        #endif
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
        .onAppear {
            debouncedSearchText = searchText
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
            }
        }
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
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { isShowingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.actorGallery.id)
        }
        .fileExporter(
            isPresented: $isShowingExportPicker,
            document: csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "Actors.csv"
        ) { result in
            switch result {
            case .success:
                break
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
                AppErrorReporter.report("CSV import failed: \(error.localizedDescription)")
            }
        }
        .overlay {
            if isImportingCSV {
                ProgressView("Importing CSV…")
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(10)
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
            deriveActorProfiles()
        }
        .onChange(of: entityProfiles) { _, _ in
            deriveActorProfiles()
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
    
    private func deriveActorProfiles() {
        actorProfiles = entityProfiles.filter { $0.key.hasPrefix("actor:") }
    }
    
    // MARK: - CSV Logic
    
    private func exportCSV() {
        // Format lives in LibraryCore (ActorCSV) so it can be unit-tested; this view
        // only supplies the data. The country transform is injected because
        // CountryFlagHelper is app-target-only: CSV can't reliably carry a flag
        // emoji, so the export writes the country name and the import re-adds it.
        let csvString = ActorCSV.document(
            actors: allUniqueActors,
            profileFor: { actorProfiles["actor:\($0)"] },
            stripCountry: CountryFlagHelper.strippedOfFlag
        )
        csvDocument = CSVDocument(text: csvString)
        isShowingExportPicker = true
    }
    
    private func importCSV(from url: URL) {
        guard let libraryURL = libraryURL else { return }
        // Federated session: v1 imports into the MAIN library only (the
        // export side already reflects the merged view).
        if LibrarySession.shared.isFederated {
            AppErrorReporter.report("CSV import applies to the main library only while other libraries are attached.")
        }

        // File read, CSV parse, and the row-by-row DB writes all run off the
        // main thread — a large CSV used to freeze the UI for its duration.
        isImportingCSV = true
        Task.detached(priority: .userInitiated) {
            defer {
                Task { @MainActor in isImportingCSV = false }
            }

            guard url.startAccessingSecurityScopedResource() else {
                AppErrorReporter.report("CSV import failed: the file couldn't be accessed.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                guard let content = String(data: data, encoding: .utf8) else {
                    AppErrorReporter.report("CSV import failed: the file isn't UTF-8 text.")
                    return
                }

                let store = try LibraryStore(at: libraryURL)
                let records = ActorCSV.parse(content)

                // The importer reads by INDEX and never consults column names, so a
                // reordered or renamed header would import silently WRONG — a bio
                // landing in homePage. Refuse rather than corrupt. A nine-column file
                // from before AKAs/Tags existed is a valid prefix and still passes.
                if let problem = ActorCSV.validateHeader(records.first ?? []) {
                    AppErrorReporter.report("CSV import failed: \(problem.message)")
                    return
                }

                let rows = records.dropFirst()

                // Report a file that parsed to nothing rather than reporting success.
                // Silence here is what hid the CRLF defect (#12) for so long: a
                // Windows-authored file collapsed into a single row, dropFirst()
                // discarded it, and the import "succeeded" having changed nothing.
                guard !rows.isEmpty else {
                    AppErrorReporter.report(
                        "CSV import failed: no actor rows were found. The file may be empty, "
                        + "contain only a header, or not be a ViLM actor export."
                    )
                    return
                }

                // Merged rows are collected first and written as ONE
                // transaction at the end — a mid-file failure imports nothing
                // rather than an invisible partial batch (DEFECT_INVENTORY M4).
                // Keyed by id so a later row for the same actor merges on top
                // of the earlier row's result, as sequential saves used to.
                var merged: [String: EntityProfile] = [:]

                for columns in rows {
                    if columns.count >= ActorCSV.minimumColumnCount {
                        let name = columns[0]
                        if name.isEmpty { continue }

                        let entityId = ActorCSV.entityId(forName: name)
                        // Merge into whatever's already there rather than replacing
                        // the profile wholesale. A CSV row is usually a partial
                        // edit — a handful of fields filled in for many actors at
                        // once — so a blank cell must leave the existing value
                        // alone, and tags/gallery photos/AKAs (which this CSV
                        // format doesn't even represent) must always survive.
                        // A THROWING fetch must abort the import (outer catch →
                        // toast) — `try?` here conflated "fetch failed" with "no
                        // profile", and the full-row save below then wiped the
                        // actor's tags/photos/AKAs (DEFECT_INVENTORY C3, the
                        // third instance of this bug class).
                        let existing = try merged[entityId] ?? store.fetchEntityProfile(for: entityId)

                        // Field-by-field merge lives in LibraryCore (ActorCSV.merge) and is
                        // unit-tested there: blank cells leave existing values alone, AKAs and
                        // tags are UNIONED with what's already stored, and gallery URLs — which
                        // this format doesn't represent — are carried over untouched.
                        guard let profile = ActorCSV.merge(
                            columns: columns,
                            existing: existing,
                            decorateCountry: CountryFlagHelper.withFlag
                        ) else { continue }
                        merged[entityId] = profile
                    }
                }

                try store.saveEntityProfiles(Array(merged.values))

                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
                }
            } catch {
                print("Import failed: \(error)")
                AppErrorReporter.report("CSV import failed: \(error.localizedDescription)")
            }
        }
    }
    
    // Pure text parsing, safe from any thread (called from the detached
    // import task).
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(actor), \(assetsCount) video\(assetsCount == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

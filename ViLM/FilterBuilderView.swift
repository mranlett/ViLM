// FilterBuilderView.swift
// The All Assets advanced-filter sheet: review status, minimum rating, and
// AND/OR actor/tag/studio pickers plus actor-metadata filters. Edits an
// AssetFilterCriteria binding owned by AssetsGridView.

import SwiftUI
import LibraryCore

struct FilterBuilderView: View {
    let assets: [Asset]
    @Binding var criteria: AssetFilterCriteria
    /// ⚠️ Named `actorProfiles`, but BOTH callers pass the whole profile set —
    /// studios and tags included. So these lists have always been built from
    /// every profile, not just actors.
    ///
    /// `.all` is used below to preserve that exactly. Narrowing to `.actors`
    /// is probably the correct behaviour and is visibly tempting here, but it
    /// would change what the filter offers, and a behaviour change smuggled in
    /// under an identity migration is the hardest kind to notice afterwards.
    /// Worth its own change.
    let actorProfiles: EntityProfileIndex
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("defaultAssetFiltersStr") private var defaultFilterCriteriaStr: String = ""
    private var defaultFilterCriteria: AssetFilterCriteria {
        get {
            guard let data = defaultFilterCriteriaStr.data(using: .utf8),
                  let result = try? JSONDecoder().decode(AssetFilterCriteria.self, from: data) else {
                return AssetFilterCriteria()
            }
            return result
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                defaultFilterCriteriaStr = str
            }
        }
    }
    
    @State private var searchText = ""
    
    @State private var isActorsExpanded = false
    @State private var isTagsExpanded = false
    @State private var isStudiosExpanded = false
    
    @State private var isActorTagsExpanded = false
    @State private var isActorHairColorsExpanded = false
    @State private var isActorGendersExpanded = false
    @State private var isActorCountriesExpanded = false
    
    @State private var actorAlphaFilter: Character? = nil
    @State private var tagAlphaFilter: Character? = nil
    @State private var studioAlphaFilter: Character? = nil
    
    @State private var actorTagAlphaFilter: Character? = nil
    @State private var actorHairColorAlphaFilter: Character? = nil
    @State private var actorGenderAlphaFilter: Character? = nil
    @State private var actorCountryAlphaFilter: Character? = nil
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        return Array(Set(actorTags)).sorted()
    }
    
    var allUniqueTags: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actionTags = allTags.filter { $0.hasPrefix("tag:") }.map { String($0.dropFirst(4)) }
        // Folded for the same reason the gallery is: two spellings of one tag
        // are one tag, and offering both as separate filter options means a
        // filter silently misses half the videos it should match.
        let canonical = TagVocabulary.canonicalSpellings(actionTags)
        return Array(Set(actionTags.map { canonical[$0] ?? $0 })).sorted()
    }
    
    var allUniqueStudios: [String] {
        let allTags = assets.flatMap { $0.tags }
        let studioTags = allTags.filter { $0.hasPrefix("studio:") }.map { String($0.dropFirst(7)) }
        return Array(Set(studioTags)).sorted()
    }
    
    var allUniqueActorTags: [String] {
        let tagsSet = Set(actorProfiles.all.flatMap { $0.tags })
        return Array(tagsSet).sorted()
    }
    
    var allUniqueActorHairColors: [String] {
        let colorsSet = Set(actorProfiles.all.compactMap { $0.hairColor }.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return Array(colorsSet).sorted()
    }
    
    var allUniqueActorGenders: [String] {
        let gendersSet = Set(actorProfiles.all.compactMap { $0.gender }.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return Array(gendersSet).sorted()
    }
    
    var allUniqueActorCountries: [String] {
        let countriesSet = Set(actorProfiles.all.compactMap { $0.countryOfOrigin }.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return Array(countriesSet).sorted()
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Review Status") {
                    Picker("Status", selection: $criteria.reviewStatus) {
                        ForEach(AssetFilterCriteria.ReviewStatusFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    Picker("Lookup Result", selection: $criteria.enrichment) {
                        ForEach(EnrichmentFilter.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    // ⭐ A separate dimension, so the two COMPOSE. "Needs
                    // attention" says a video is waiting; this says what kind
                    // of question is waiting, and together they isolate the
                    // quick pile from the investigations.
                    Picker("Found By", selection: $criteria.effectiveLookupRoute) {
                        ForEach(LookupRouteFilter.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } header: {
                    Text("External Lookup")
                } footer: {
                    // A separate axis from review status above: one is whether
                    // YOU have watched it, the other whether a source could
                    // identify it. A video can be fully reviewed and never
                    // looked up, or matched and never watched.
                    Text("Find videos an external lookup could not resolve. "
                         + "“Not findable (you decided)” holds the ones you have ruled out.")
                }

                Section("Minimum Rating") {
                    Stepper(value: Binding(
                        get: { criteria.minRating ?? 0 },
                        set: { criteria.minRating = $0 == 0 ? nil : $0 }
                    ), in: 0...5) {
                        HStack {
                            Text("Rating:")
                            if let rating = criteria.minRating {
                                HStack(spacing: 2) {
                                    ForEach(0..<rating, id: \.self) { _ in
                                        Image(systemName: "star.fill").foregroundColor(.yellow)
                                    }
                                }
                            } else {
                                Text("Any")
                            }
                        }
                    }
                }

                Section(
                    header: Text("Minimum Actor Rating"),
                    footer: Text("Shows videos featuring at least one actor you've rated this highly.")
                ) {
                    Stepper(value: Binding(
                        get: { criteria.minActorRating ?? 0 },
                        set: { criteria.minActorRating = $0 == 0 ? nil : $0 }
                    ), in: 0...5) {
                        HStack {
                            Text("Actor:")
                            if let rating = criteria.minActorRating {
                                HStack(spacing: 2) {
                                    ForEach(0..<rating, id: \.self) { _ in
                                        Image(systemName: "star.fill").foregroundColor(.yellow)
                                    }
                                }
                            } else {
                                Text("Any")
                            }
                        }
                    }
                }
                Section(
                    header: Text("Age at Release"),
                    footer: Text("Shows videos where a credited actor was this old when the video came out — not how old they are now.\n\nAn age worked out from a birth year alone is only right to within a year, so a video is included only when every possible age fits. Videos with no release date, or actors with no birth date, can't be checked and are left out.")
                ) {
                    ageBound(label: "From", value: $criteria.minAgeAtRelease)
                    ageBound(label: "To", value: $criteria.maxAgeAtRelease)
                }

                DisclosureGroup("Actors", isExpanded: $isActorsExpanded) {
                    AlphaPickerView(filter: $actorAlphaFilter)
                        .padding(.vertical, 4)
                    filterSection(
                        items: allUniqueActors,
                        filter: actorAlphaFilter,
                        logicBinding: $criteria.actorsLogic,
                        selectionBinding: $criteria.selectedActors
                    )
                }
                
                DisclosureGroup("Studios", isExpanded: $isStudiosExpanded) {
                    AlphaPickerView(filter: $studioAlphaFilter)
                        .padding(.vertical, 4)
                    filterSection(
                        items: allUniqueStudios,
                        filter: studioAlphaFilter,
                        logicBinding: $criteria.studiosLogic,
                        selectionBinding: $criteria.selectedStudios
                    )
                }
                
                DisclosureGroup("Tags", isExpanded: $isTagsExpanded) {
                    AlphaPickerView(filter: $tagAlphaFilter)
                        .padding(.vertical, 4)
                    filterSection(
                        items: allUniqueTags,
                        filter: tagAlphaFilter,
                        logicBinding: $criteria.tagsLogic,
                        selectionBinding: $criteria.selectedTags
                    )
                }
                
                Section("Actor Metadata") {
                    DisclosureGroup("Actor Tags", isExpanded: $isActorTagsExpanded) {
                        AlphaPickerView(filter: $actorTagAlphaFilter)
                            .padding(.vertical, 4)
                        filterSection(
                            items: allUniqueActorTags,
                            filter: actorTagAlphaFilter,
                            logicBinding: $criteria.actorTagsLogic,
                            selectionBinding: $criteria.selectedActorTags
                        )
                    }
                    
                    DisclosureGroup("Actor Hair Colors", isExpanded: $isActorHairColorsExpanded) {
                        AlphaPickerView(filter: $actorHairColorAlphaFilter)
                            .padding(.vertical, 4)
                        filterSection(
                            items: allUniqueActorHairColors,
                            filter: actorHairColorAlphaFilter,
                            logicBinding: $criteria.actorHairColorsLogic,
                            selectionBinding: $criteria.selectedActorHairColors
                        )
                    }
                    
                    DisclosureGroup("Actor Genders", isExpanded: $isActorGendersExpanded) {
                        AlphaPickerView(filter: $actorGenderAlphaFilter)
                            .padding(.vertical, 4)
                        filterSection(
                            items: allUniqueActorGenders,
                            filter: actorGenderAlphaFilter,
                            logicBinding: $criteria.actorGendersLogic,
                            selectionBinding: $criteria.selectedActorGenders
                        )
                    }
                    
                    DisclosureGroup("Actor Countries", isExpanded: $isActorCountriesExpanded) {
                        AlphaPickerView(filter: $actorCountryAlphaFilter)
                            .padding(.vertical, 4)
                        filterSection(
                            items: allUniqueActorCountries,
                            filter: actorCountryAlphaFilter,
                            logicBinding: $criteria.actorCountriesLogic,
                            selectionBinding: $criteria.selectedActorCountries
                        )
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search filters")
            .navigationTitle("Filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Menu("Actions") {
                        Button("Load Default") {
                            criteria = defaultFilterCriteria
                        }
                        Button("Save as Default") {
                            defaultFilterCriteria = criteria
                        }
                        Divider()
                        Button("Clear Filters", role: .destructive) {
                            criteria = AssetFilterCriteria()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 600)
        #endif
    }
    
    private func filteredItems(_ items: [String], by filter: Character?) -> [String] {
        guard let filter = filter else { return items }
        if filter == "#" {
            return items.filter { $0.first?.isLetter == false }
        }
        return items.filter { $0.uppercased().hasPrefix(String(filter)) }
    }
    
    /// One end of the age-at-release range.
    ///
    /// ⚠️ Zero means "unset", not "age nought", which is why the stepper's
    /// floor reads **Any** rather than 0 — an age filter of zero would be a
    /// bound that excludes nothing while looking like a real setting.
    private func ageBound(label: String, value: Binding<Int?>) -> some View {
        Stepper(value: Binding(
            get: { value.wrappedValue ?? 0 },
            set: { value.wrappedValue = $0 == 0 ? nil : $0 }
        ), in: 0...99) {
            HStack {
                Text(label)
                Spacer()
                Text(value.wrappedValue.map(String.init) ?? "Any")
                    .foregroundStyle(value.wrappedValue == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
        }
    }

    private func filterSection(items: [String], filter: Character?, logicBinding: Binding<AssetFilterCriteria.Logic>, selectionBinding: Binding<Set<String>>) -> some View {
        let alphaFiltered = filteredItems(items, by: filter)
        let finalFiltered = alphaFiltered.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
        
        return Group {
            if !finalFiltered.isEmpty || !selectionBinding.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Match", selection: logicBinding) {
                        ForEach(AssetFilterCriteria.Logic.allCases, id: \.self) { logic in
                            Text(logic.rawValue).tag(logic)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 8)
                    
                    ForEach(finalFiltered, id: \.self) { item in
                        let isSelected = selectionBinding.wrappedValue.contains(item)
                        
                        Button {
                            if isSelected {
                                selectionBinding.wrappedValue.remove(item)
                            } else {
                                selectionBinding.wrappedValue.insert(item)
                            }
                        } label: {
                            HStack {
                                Text(item).foregroundColor(.primary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }
}

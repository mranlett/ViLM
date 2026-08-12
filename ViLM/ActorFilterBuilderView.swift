// ActorFilterBuilderView.swift
// The Actor Gallery's advanced-filter sheet: gender, hair color, country,
// actor tags, video-count and age ranges, with AND/OR logic where it applies.
// Edits an ActorFilterCriteria binding owned by ActorGridView.

import SwiftUI
import LibraryCore

struct ActorFilterBuilderView: View {
    let allUniqueGenders: [String]
    let allUniqueHairColors: [String]
    let allUniqueCountries: [String]
    let allUniqueTags: [String]
    
    @Binding var criteria: ActorFilterCriteria
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("defaultActorFiltersStr") private var defaultFilterCriteriaStr: String = ""
    private var defaultFilterCriteria: ActorFilterCriteria {
        get {
            guard let data = defaultFilterCriteriaStr.data(using: .utf8),
                  let result = try? JSONDecoder().decode(ActorFilterCriteria.self, from: data) else {
                return ActorFilterCriteria()
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
    
    @State private var isGendersExpanded = false
    @State private var isHairColorsExpanded = false
    @State private var isCountriesExpanded = false
    @State private var isTagsExpanded = false
    @State private var isRepairExpanded = false

    /// How many maintenance filters are on, shown on the collapsed accordion.
    private var repairFilterCount: Int {
        var n = 0
        if criteria.showMissingPhotosOnly { n += 1 }
        if criteria.showMissingGenderOnly { n += 1 }
        if criteria.enrichment != .any { n += 1 }
        return n
    }
    
    @State private var tagAlphaFilter: Character? = nil
    
    var body: some View {
        NavigationStack {
            List {
                // ⭐ Data repair, collapsed. These are maintenance tools —
                // wanted often, but never at the same time as browsing — so
                // they keep their place at the top and give up their space.
                Section {
                    DisclosureGroup(isExpanded: $isRepairExpanded) {
                        Toggle("Missing Photos Only", isOn: $criteria.showMissingPhotosOnly)
                        Toggle("Missing Gender Only", isOn: $criteria.showMissingGenderOnly)
                        Picker("Lookup Result", selection: $criteria.enrichment) {
                            ForEach(ActorFilterCriteria.EnrichmentFilter.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        HStack {
                            Text("Find problems")
                            Spacer()
                            // The count is the reason to open it — a collapsed
                            // accordion that says nothing gets ignored.
                            if repairFilterCount > 0 {
                                Text("\(repairFilterCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Maintenance filters. “Needs attention” covers everything waiting on you.")
                }

                Section("Minimum Rating") {
                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= (criteria.minRating ?? 0) ? "star.fill" : "star")
                                .foregroundColor(.yellow)
                                .onTapGesture {
                                    // Tap the current minimum again to clear it.
                                    criteria.minRating = (criteria.minRating == star) ? nil : star
                                }
                                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s") minimum")
                        }
                        Spacer()
                        Text(criteria.minRating.map { "\($0)+ stars" } ?? "Any")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                
                // ⭐ Third, not last. A search is almost always a search FOR
                // a tag — gender has four values, hair eleven, country a
                // sortable list — so search earns its place here and nowhere
                // else. A provider vocabulary runs ten thousand long, which is
                // what makes the alphabet picker load-bearing rather than
                // decorative.
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

                DisclosureGroup("Gender", isExpanded: $isGendersExpanded) {
                    multiSelectionSection(
                        items: allUniqueGenders,
                        selectionBinding: $criteria.selectedGenders,
                        emptyBinding: $criteria.showMissingGenderOnly
                    )
                }

                DisclosureGroup("Hair Color", isExpanded: $isHairColorsExpanded) {
                    singleSelectionSection(
                        items: allUniqueHairColors,
                        selectionBinding: $criteria.hairColor,
                        emptyBinding: $criteria.matchEmptyHairColor
                    )
                }

                DisclosureGroup("Country of Origin", isExpanded: $isCountriesExpanded) {
                    singleSelectionSection(
                        items: allUniqueCountries,
                        selectionBinding: $criteria.country,
                        emptyBinding: $criteria.matchEmptyCountry,
                        label: { CountryFlagHelper.withFlag($0.capitalized) }
                    )
                }
                
                Section("Video Count") {
                    boundPicker("Minimum", value: $criteria.minVideos, range: 0...1000)
                    boundPicker("Maximum", value: $criteria.maxVideos, range: 0...1000)
                }
                
                Section {
                    // ⭐ ONE control with a mode, not three range sliders.
                    // Three would make the age filter the largest thing in a
                    // panel this change exists to declutter.
                    Picker("Measure", selection: $criteria.ageMode) {
                        ForEach(ActorFilterCriteria.AgeMode.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("No Date of Birth", isOn: $criteria.matchEmptyBirthYear)

                    Group {
                        boundPicker("Minimum", value: $criteria.minAge, range: 18...100)
                        boundPicker("Maximum", value: $criteria.maxAge, range: 18...100)
                    }
                    // An actor with no DOB has no age, so a range can't apply.
                    .disabled(criteria.matchEmptyBirthYear)
                    .opacity(criteria.matchEmptyBirthYear ? 0.4 : 1)
                } header: {
                    Text("Age")
                } footer: {
                    // Says which question the range is asking, because the two
                    // modes look identical once a range is set.
                    Text(criteria.ageMode.question)
                }
                
            }
            .searchable(text: $searchText, prompt: "Search filters")
            .navigationTitle("Actor Filters")
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
                            criteria = ActorFilterCriteria()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 600)
        #endif
    }
    

    /// One end of a numeric range, as a compact row.
    ///
    /// 🚨 NOT a wheel. A wheel picker reserves its full intrinsic height inside
    /// a `List` row — two side by side turned each card into a mostly empty
    /// box with the values crushed against the bottom, which is what the
    /// operator reported on iOS.
    ///
    /// ⭐ `.navigationLink` on iOS gives a one-line row that pushes the choices,
    /// which also handles a thousand entries without becoming a scroll trap.
    /// macOS keeps `.menu`, where a popup is the native idiom and the height
    /// problem does not exist.
    ///
    /// ⚠️ `-1` is the sentinel for "no bound". The model stores `Int?`, and a
    /// `Picker` cannot bind to an optional without one.
    @ViewBuilder
    private func boundPicker(_ label: String, value: Binding<Int?>,
                             range: ClosedRange<Int>) -> some View {
        Picker(label, selection: Binding(
            get: { value.wrappedValue ?? -1 },
            set: { value.wrappedValue = $0 == -1 ? nil : $0 })
        ) {
            Text("Any").tag(-1 as Int)
            ForEach(range, id: \.self) { Text("\($0)").tag($0) }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #else
        .pickerStyle(.menu)
        #endif
    }

    /// - Parameter label: how each value is DISPLAYED. Presentation only.
    ///
    /// 🚨 The selection, the alpha filter and the search all keep using the
    /// stored value. Migration v40 took the flag out of `country_of_origin`
    /// precisely because storing presentation split 57 countries into 94
    /// values — so the flag goes on here, at the last possible moment, and
    /// decorating the label must never change what is matched.
    private func singleSelectionSection(items: [String], selectionBinding: Binding<String>,
                                        emptyBinding: Binding<Bool>,
                                        label: @escaping (String) -> String = { $0.capitalized }) -> some View {
        let filtered = items.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }

        return Group {
            if !filtered.isEmpty || !selectionBinding.wrappedValue.isEmpty || emptyBinding.wrappedValue {
                VStack(alignment: .leading, spacing: 0) {
                    // "Any" option — no constraint on this field.
                    Button {
                        selectionBinding.wrappedValue = ""
                        emptyBinding.wrappedValue = false
                    } label: {
                        HStack {
                            Text("Any").foregroundColor(.primary)
                            Spacer()
                            if selectionBinding.wrappedValue.isEmpty && !emptyBinding.wrappedValue {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider()

                    // "Empty / Not Set" — actors missing this detail. Mutually
                    // exclusive with a specific value.
                    Button {
                        if emptyBinding.wrappedValue {
                            emptyBinding.wrappedValue = false
                        } else {
                            emptyBinding.wrappedValue = true
                            selectionBinding.wrappedValue = ""
                        }
                    } label: {
                        HStack {
                            Text("Empty / Not Set").foregroundColor(.primary)
                            Spacer()
                            if emptyBinding.wrappedValue {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider()

                    ForEach(filtered, id: \.self) { item in
                        let isSelected = selectionBinding.wrappedValue == item && !emptyBinding.wrappedValue

                        Button {
                            if isSelected {
                                selectionBinding.wrappedValue = ""
                            } else {
                                selectionBinding.wrappedValue = item
                                emptyBinding.wrappedValue = false
                            }
                        } label: {
                            HStack {
                                Text(label(item)).foregroundColor(.primary)
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
    
    private func filteredItems(_ items: [String], by filter: Character?) -> [String] {
        guard let filter = filter else { return items }
        if filter == "#" {
            return items.filter { $0.first?.isLetter == false }
        }
        return items.filter { $0.uppercased().hasPrefix(String(filter)) }
    }
    
    private func filterSection(items: [String], filter: Character?, logicBinding: Binding<ActorFilterCriteria.Logic>, selectionBinding: Binding<Set<String>>) -> some View {
        let alphaFiltered = filteredItems(items, by: filter)
        let finalFiltered = alphaFiltered.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
        
        return Group {
            if !finalFiltered.isEmpty || !selectionBinding.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Match", selection: logicBinding) {
                        ForEach(ActorFilterCriteria.Logic.allCases, id: \.self) { logic in
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
    
    private func multiSelectionSection(items: [String], selectionBinding: Binding<Set<String>>, emptyBinding: Binding<Bool>) -> some View {
        let filtered = items.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }

        return Group {
            if !filtered.isEmpty || !selectionBinding.wrappedValue.isEmpty || emptyBinding.wrappedValue {
                VStack(alignment: .leading, spacing: 0) {
                    // "Empty / Not Set" — actors missing this detail. Selecting a
                    // specific value clears it (and vice versa).
                    Button {
                        if emptyBinding.wrappedValue {
                            emptyBinding.wrappedValue = false
                        } else {
                            emptyBinding.wrappedValue = true
                            selectionBinding.wrappedValue = []
                        }
                    } label: {
                        HStack {
                            Text("Empty / Not Set").foregroundColor(.primary)
                            Spacer()
                            if emptyBinding.wrappedValue {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider()

                    ForEach(filtered, id: \.self) { item in
                        let isSelected = selectionBinding.wrappedValue.contains(item)

                        Button {
                            if isSelected {
                                selectionBinding.wrappedValue.remove(item)
                            } else {
                                selectionBinding.wrappedValue.insert(item)
                                emptyBinding.wrappedValue = false
                            }
                        } label: {
                            HStack {
                                Text(item.capitalized).foregroundColor(.primary)
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

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
    
    @State private var tagAlphaFilter: Character? = nil
    
    var body: some View {
        NavigationStack {
            List {
                Section("Status Filters") {
                    Toggle("Missing Photos Only", isOn: $criteria.showMissingPhotosOnly)
                    Toggle("Missing Gender Only", isOn: $criteria.showMissingGenderOnly)
                }

                Section {
                    Picker("Lookup Result", selection: $criteria.enrichment) {
                        ForEach(ActorFilterCriteria.EnrichmentFilter.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } header: {
                    Text("External Lookup")
                } footer: {
                    // A separate axis from the completeness filters above: an
                    // actor can be fully filled in with an unresolved lookup, or
                    // sparse and never checked. "Not yet checked" is not a
                    // failure, which is why it is its own option.
                    Text("Find actors an external lookup could not resolve. "
                         + "“Needs attention” covers everything waiting on you.")
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
                        emptyBinding: $criteria.matchEmptyCountry
                    )
                }
                
                Section("Video Count") {
                    HStack {
                        Picker("Min", selection: Binding(get: { criteria.minVideos ?? -1 }, set: { criteria.minVideos = $0 == -1 ? nil : $0 })) {
                            Text("Any").tag(-1 as Int)
                            ForEach(0...1000, id: \.self) { count in Text("\(count)").tag(count) }
                        }
                        #if os(iOS)
                        .pickerStyle(.wheel)
                        #else
                        .pickerStyle(.menu)
                        #endif
                        
                        Picker("Max", selection: Binding(get: { criteria.maxVideos ?? -1 }, set: { criteria.maxVideos = $0 == -1 ? nil : $0 })) {
                            Text("Any").tag(-1 as Int)
                            ForEach(0...1000, id: \.self) { count in Text("\(count)").tag(count) }
                        }
                        #if os(iOS)
                        .pickerStyle(.wheel)
                        #else
                        .pickerStyle(.menu)
                        #endif
                    }
                }
                
                Section("Age Range") {
                    Toggle("No Date of Birth", isOn: $criteria.matchEmptyBirthYear)
                    HStack {
                        Picker("Min", selection: Binding(get: { criteria.minAge ?? -1 }, set: { criteria.minAge = $0 == -1 ? nil : $0 })) {
                            Text("Any").tag(-1 as Int)
                            ForEach(18...100, id: \.self) { age in Text("\(age)").tag(age) }
                        }
                        #if os(iOS)
                        .pickerStyle(.wheel)
                        #else
                        .pickerStyle(.menu)
                        #endif

                        Picker("Max", selection: Binding(get: { criteria.maxAge ?? -1 }, set: { criteria.maxAge = $0 == -1 ? nil : $0 })) {
                            Text("Any").tag(-1 as Int)
                            ForEach(18...100, id: \.self) { age in Text("\(age)").tag(age) }
                        }
                        #if os(iOS)
                        .pickerStyle(.wheel)
                        #else
                        .pickerStyle(.menu)
                        #endif
                    }
                    // An actor with no DOB has no age, so a range can't apply.
                    .disabled(criteria.matchEmptyBirthYear)
                    .opacity(criteria.matchEmptyBirthYear ? 0.4 : 1)
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
    
    private func singleSelectionSection(items: [String], selectionBinding: Binding<String>, emptyBinding: Binding<Bool>) -> some View {
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

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
                
                DisclosureGroup("Gender", isExpanded: $isGendersExpanded) {
                    multiSelectionSection(
                        items: allUniqueGenders,
                        selectionBinding: $criteria.selectedGenders
                    )
                }
                
                DisclosureGroup("Hair Color", isExpanded: $isHairColorsExpanded) {
                    singleSelectionSection(
                        items: allUniqueHairColors,
                        selectionBinding: $criteria.hairColor
                    )
                }
                
                DisclosureGroup("Country of Origin", isExpanded: $isCountriesExpanded) {
                    singleSelectionSection(
                        items: allUniqueCountries,
                        selectionBinding: $criteria.country
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
        .frame(minWidth: 400, minHeight: 600)
    }
    
    private func singleSelectionSection(items: [String], selectionBinding: Binding<String>) -> some View {
        let filtered = items.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
        
        return Group {
            if !filtered.isEmpty || !selectionBinding.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // "Any" option
                    Button {
                        selectionBinding.wrappedValue = ""
                    } label: {
                        HStack {
                            Text("Any").foregroundColor(.primary)
                            Spacer()
                            if selectionBinding.wrappedValue.isEmpty {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider()
                    
                    ForEach(filtered, id: \.self) { item in
                        let isSelected = selectionBinding.wrappedValue == item
                        
                        Button {
                            if isSelected {
                                selectionBinding.wrappedValue = ""
                            } else {
                                selectionBinding.wrappedValue = item
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
    
    private func multiSelectionSection(items: [String], selectionBinding: Binding<Set<String>>) -> some View {
        let filtered = items.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
        
        return Group {
            if !filtered.isEmpty || !selectionBinding.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { item in
                        let isSelected = selectionBinding.wrappedValue.contains(item)
                        
                        Button {
                            if isSelected {
                                selectionBinding.wrappedValue.remove(item)
                            } else {
                                selectionBinding.wrappedValue.insert(item)
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

import SwiftUI
import LibraryCore

struct ActorFilterBuilderView: View {
    let allUniqueGenders: [String]
    let allUniqueHairColors: [String]
    let allUniqueCountries: [String]
    let allUniqueTags: [String]
    
    @Binding var criteria: ActorFilterCriteria
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    
    @State private var isGendersExpanded = false
    @State private var isHairColorsExpanded = false
    @State private var isCountriesExpanded = false
    @State private var isTagsExpanded = false
    
    @State private var tagAlphaFilter: Character? = nil
    
    var body: some View {
        NavigationStack {
            List {
                Section("Photo Status") {
                    Toggle("Missing Photos Only", isOn: $criteria.showMissingPhotosOnly)
                }
                
                DisclosureGroup("Gender", isExpanded: $isGendersExpanded) {
                    singleSelectionSection(
                        items: allUniqueGenders,
                        selectionBinding: $criteria.gender
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
                    Button("Clear") {
                        criteria = ActorFilterCriteria()
                    }
                    .disabled(criteria.isEmpty)
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
}

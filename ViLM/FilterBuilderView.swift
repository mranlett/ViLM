import SwiftUI
import LibraryCore

struct FilterBuilderView: View {
    let assets: [Asset]
    @Binding var criteria: AssetFilterCriteria
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    
    @State private var isActorsExpanded = false
    @State private var isTagsExpanded = false
    @State private var isStudiosExpanded = false
    
    @State private var actorAlphaFilter: Character? = nil
    @State private var tagAlphaFilter: Character? = nil
    @State private var studioAlphaFilter: Character? = nil
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        return Array(Set(actorTags)).sorted()
    }
    
    var allUniqueTags: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actionTags = allTags.filter { $0.hasPrefix("tag:") }.map { String($0.dropFirst(4)) }
        return Array(Set(actionTags)).sorted()
    }
    
    var allUniqueStudios: [String] {
        let allTags = assets.flatMap { $0.tags }
        let studioTags = allTags.filter { $0.hasPrefix("studio:") }.map { String($0.dropFirst(7)) }
        return Array(Set(studioTags)).sorted()
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
                    Button("Clear") {
                        criteria = AssetFilterCriteria()
                    }
                    .disabled(criteria.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 600)
    }
    
    private func filteredItems(_ items: [String], by filter: Character?) -> [String] {
        guard let filter = filter else { return items }
        if filter == "#" {
            return items.filter { $0.first?.isLetter == false }
        }
        return items.filter { $0.uppercased().hasPrefix(String(filter)) }
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

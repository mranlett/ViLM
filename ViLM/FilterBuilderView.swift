import SwiftUI
import LibraryCore

struct FilterBuilderView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    
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
                filterSection(title: "Actors", items: allUniqueActors, itemType: { .actor($0) })
                filterSection(title: "Studios", items: allUniqueStudios, itemType: { .studio($0) })
                filterSection(title: "Tags", items: allUniqueTags, itemType: { .tag($0) })
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
                        sidebarSelection = [.allAssets]
                    }
                    .disabled(sidebarSelection.isEmpty || sidebarSelection == [.allAssets])
                }
            }
        }
        .frame(minWidth: 350, minHeight: 500)
    }
    
    private func filterSection(title: String, items: [String], itemType: @escaping (String) -> SidebarItem) -> some View {
        let filtered = items.filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
        
        return Group {
            if !filtered.isEmpty {
                Section(title) {
                    ForEach(filtered, id: \.self) { item in
                        let sidebarItem = itemType(item)
                        let isSelected = sidebarSelection.contains(sidebarItem)
                        
                        Button {
                            if isSelected {
                                sidebarSelection.remove(sidebarItem)
                                if sidebarSelection.isEmpty {
                                    sidebarSelection = [.allAssets]
                                }
                            } else {
                                sidebarSelection.remove(.allAssets)
                                sidebarSelection.insert(sidebarItem)
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

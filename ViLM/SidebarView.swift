import SwiftUI
import LibraryCore

struct SidebarView: View {
    @Binding var selection: Set<SidebarItem>
    let assets: [Asset]
    let onOpenLibrary: () -> Void
    let onValidate: () -> Void
    let onApplyFilters: () -> Void
    
    @State private var isActorsExpanded = true
    @State private var isTagsExpanded = true
    @State private var isStudiosExpanded = true
    
    @State private var actorAlphaFilter: Character? = nil
    @State private var tagAlphaFilter: Character? = nil
    @State private var studioAlphaFilter: Character? = nil
    
    // MARK: - Computed Properties
    
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
    
    // Stats for progress tracking
    private var reviewProgress: Double {
        guard !assets.isEmpty else { return 0 }
        let reviewed = assets.filter { $0.status == .reviewed }.count
        return Double(reviewed) / Double(assets.count)
    }

    private var unreviewedCount: Int {
        assets.filter { $0.status == .unreviewed }.count
    }
    
    // MARK: - Body
    
    var body: some View {
        List {
            Section("Library") {
                Button(action: onOpenLibrary) {
                    Label("Open Library", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                
                Button(action: onValidate) {
                    Label("Validate Library", systemImage: "checkmark.shield")
                }
                .buttonStyle(.plain)
                
                sidebarRow(title: "All Assets", icon: "play.rectangle.on.rectangle", isSelected: selection == [.allAssets], count: unreviewedCount > 0 ? unreviewedCount : nil) {
                    selection = [.allAssets]
                }
            }
            
            DisclosureGroup(isExpanded: $isActorsExpanded) {
                alphaPicker(for: $actorAlphaFilter)
                ForEach(filteredItems(allUniqueActors, by: actorAlphaFilter), id: \.self) { actor in
                    sidebarRow(title: actor, icon: "person", isSelected: selection.contains(.actor(actor))) {
                        toggleSelection(item: .actor(actor))
                    }
                }
            } label: { Text("Actors").font(.headline) }
            
            DisclosureGroup(isExpanded: $isTagsExpanded) {
                alphaPicker(for: $tagAlphaFilter)
                ForEach(filteredItems(allUniqueTags, by: tagAlphaFilter), id: \.self) { tag in
                    sidebarRow(title: tag, icon: "tag", isSelected: selection.contains(.tag(tag))) {
                        toggleSelection(item: .tag(tag))
                    }
                }
            } label: { Text("Tags").font(.headline) }
            
            DisclosureGroup(isExpanded: $isStudiosExpanded) {
                alphaPicker(for: $studioAlphaFilter)
                ForEach(filteredItems(allUniqueStudios, by: studioAlphaFilter), id: \.self) { studio in
                    sidebarRow(title: studio, icon: "building.2", isSelected: selection.contains(.studio(studio))) {
                        toggleSelection(item: .studio(studio))
                    }
                }
            } label: { Text("Studios").font(.headline) }
        }
        .safeAreaInset(edge: .bottom) {
            progressFooter
        }
        .navigationTitle("ViLM")
    }
    
    // MARK: - Helpers
    
    private func alphaPicker(for filter: Binding<Character?>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { $0 }, id: \.self) { letter in
                    Button(action: {
                        if filter.wrappedValue == letter {
                            filter.wrappedValue = nil
                        } else {
                            filter.wrappedValue = letter
                        }
                    }) {
                        Text(String(letter))
                            .font(.caption2)
                            .frame(width: 24, height: 24)
                            .background(filter.wrappedValue == letter ? Color.accentColor : Color.secondary.opacity(0.2))
                            .foregroundColor(filter.wrappedValue == letter ? .white : .primary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func filteredItems(_ items: [String], by letter: Character?) -> [String] {
        guard let letter = letter else { return items }
        return items.filter { $0.uppercased().hasPrefix(String(letter)) }
    }
    
    private func toggleSelection(item: SidebarItem) {
        if selection.contains(item) {
            selection.remove(item)
            if selection.isEmpty {
                selection = [.allAssets]
            }
        } else {
            selection.remove(.allAssets)
            selection.insert(item)
        }
    }
    
    private func sidebarRow(title: String, icon: String, isSelected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let count = count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
    
    // MARK: - Progress Footer
    private var progressFooter: some View {
        VStack(spacing: 8) {
#if os(iOS)
            Button(action: onApplyFilters) {
                Text("Apply Filters & View Assets")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
#endif
            
            Divider()
            HStack {
                Text("Review Progress")
                Spacer()
                Text("\(Int(reviewProgress * 100))%")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            ProgressView(value: reviewProgress)
                .tint(reviewProgress == 1.0 ? .green : .blue)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

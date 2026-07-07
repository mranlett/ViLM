import SwiftUI
import LibraryCore

struct SeriesCleanupView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let assets: [Asset]

    struct VariantGroup: Identifiable {
        let id = UUID()
        var variants: [Variant]
        var canonical: String
    }
    struct Variant: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
    }

    @State private var groups: [VariantGroup] = []
    @State private var isMerging = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Standardize Series")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    if !groups.isEmpty {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Merge All") { Task { await mergeAll() } }
                                .disabled(isMerging)
                        }
                    }
                }
                .overlay {
                    if isMerging {
                        ProgressView("Merging…")
                            .padding()
                            .background(.regularMaterial)
                            .cornerRadius(10)
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(errorMessage ?? "")
                }
                .onAppear(perform: computeGroups)
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No Variations Found",
                systemImage: "checkmark.seal",
                description: Text("No series names look like near-duplicates of each other.")
            )
        } else {
            List {
                Section {
                    Text("These series names differ only by casing or spacing. Pick or edit the name to keep, then merge.")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                ForEach($groups) { $group in
                    Section {
                        ForEach(group.variants) { variant in
                            HStack {
                                Button(action: { group.canonical = variant.name }) {
                                    Image(systemName: group.canonical == variant.name ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(group.canonical == variant.name ? .accentColor : .secondary)
                                }
                                .buttonStyle(.plain)

                                Text(variant.name)
                                    .font(.callout)
                                    .lineLimit(2)
                                Spacer()
                                Text("\(variant.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            TextField("Canonical name", text: $group.canonical)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button("Merge") {
                                Task { await merge(group) }
                            }
                            .disabled(isMerging || group.canonical.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        Text("\(group.variants.count) variants")
                    }
                }
            }
        }
    }

    // MARK: - Grouping

    /// Names that reduce to the same normalized key (trimmed, whitespace
    /// collapsed, lowercased) are treated as variants of one another.
    private func normalizedKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func computeGroups() {
        var counts: [String: Int] = [:]
        for asset in assets {
            if let name = asset.videoName, !name.isEmpty {
                counts[name, default: 0] += 1
            }
        }

        var byKey: [String: [String]] = [:]
        for name in counts.keys {
            byKey[normalizedKey(name), default: []].append(name)
        }

        var result: [VariantGroup] = []
        for (_, names) in byKey where names.count > 1 {
            let variants = names
                .map { Variant(name: $0, count: counts[$0] ?? 0) }
                .sorted { $0.count > $1.count }
            // Default the canonical to the most-used spelling.
            result.append(VariantGroup(variants: variants, canonical: variants.first?.name ?? names[0]))
        }
        groups = result.sorted { $0.variants.count > $1.variants.count }
    }

    // MARK: - Merging

    private func merge(_ group: VariantGroup) async {
        let target = group.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        await MainActor.run { isMerging = true }
        do {
            let store = try LibraryStore(at: libraryURL)
            try store.renameSeries(from: Set(group.variants.map(\.name)), to: target)
            await MainActor.run {
                groups.removeAll { $0.id == group.id }
                isMerging = false
                NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
            }
        } catch {
            await MainActor.run {
                isMerging = false
                errorMessage = "Failed to merge: \(error.localizedDescription)"
            }
        }
    }

    private func mergeAll() async {
        await MainActor.run { isMerging = true }
        do {
            let store = try LibraryStore(at: libraryURL)
            for group in groups {
                let target = group.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { continue }
                try store.renameSeries(from: Set(group.variants.map(\.name)), to: target)
            }
            await MainActor.run {
                groups.removeAll()
                isMerging = false
                NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
            }
        } catch {
            await MainActor.run {
                isMerging = false
                errorMessage = "Failed to merge: \(error.localizedDescription)"
            }
        }
    }
}

import SwiftUI
import LibraryCore

struct EpisodeBackfillView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let assets: [Asset]

    struct Row: Identifiable {
        let id: Asset.ID
        let fileName: String
        let seriesName: String?
        let originalText: String
        var season: String
        var episode: String
        var title: String
        var isConfident: Bool
        var selected: Bool
    }

    @State private var rows: [Row] = []
    @State private var isApplying = false
    @State private var errorMessage: String?

    private var selectedCount: Int { rows.filter(\.selected).count }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Migrate Episode Info")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    if !rows.isEmpty {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply (\(selectedCount))") { Task { await apply() } }
                                .disabled(selectedCount == 0 || isApplying)
                        }
                    }
                }
                .overlay {
                    if isApplying {
                        ProgressView("Applying…")
                            .padding().background(.regularMaterial).cornerRadius(10)
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage ?? "") }
                .onAppear(perform: computeRows)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "Nothing to Migrate",
                systemImage: "checkmark.seal",
                description: Text("No videos have legacy episode text that still needs structured season/episode numbers.")
            )
        } else {
            List {
                Section {
                    Text("Parsed from your existing Episode Info. Confident matches are pre-selected; review the flagged ones, then apply. Nothing changes until you tap Apply.")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                ForEach($rows) { $row in
                    rowView($row)
                }
            }
        }
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { row.wrappedValue.selected.toggle() }) {
                    Image(systemName: row.wrappedValue.selected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(row.wrappedValue.selected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.wrappedValue.seriesName ?? row.wrappedValue.fileName)
                        .font(.callout)
                        .lineLimit(1)
                    Text("was: \(row.wrappedValue.originalText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !row.wrappedValue.isConfident {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                        .help("Please review")
                }
            }

            HStack(spacing: 8) {
                labeledField("Season", text: row.season, width: 70, numeric: true)
                labeledField("Episode", text: row.episode, width: 80, numeric: true)
                labeledField("Title", text: row.title, width: nil, numeric: false)
            }
        }
        .padding(.vertical, 4)
    }

    private func labeledField(_ label: String, text: Binding<String>, width: CGFloat?, numeric: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .keyboardType(numeric ? .numberPad : .default)
#endif
                .frame(width: width)
        }
    }

    // MARK: - Build rows

    private func computeRows() {
        var result: [Row] = []
        for asset in assets {
            guard let text = asset.episode?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            // Skip anything already structured — this is a one-time migration.
            if asset.seasonNumber != nil || asset.episodeNumber != nil { continue }
            let parsed = EpisodeParser.parse(text)
            result.append(Row(
                id: asset.id,
                fileName: asset.fileName,
                seriesName: asset.videoName,
                originalText: text,
                season: parsed.season.map(String.init) ?? "",
                episode: parsed.episode.map(String.init) ?? "",
                title: parsed.title ?? "",
                isConfident: parsed.isConfident,
                selected: parsed.isConfident
            ))
        }
        // Flagged rows first so they get attention.
        rows = result.sorted { !$0.isConfident && $1.isConfident }
    }

    // MARK: - Apply

    private func apply() async {
        await MainActor.run { isApplying = true }
        let toApply = rows.filter(\.selected)
        do {
            let store = try LibraryStore(at: libraryURL)
            for row in toApply {
                guard var asset = assets.first(where: { $0.id == row.id }) else { continue }
                asset.seasonNumber = Int(row.season.trimmingCharacters(in: .whitespaces))
                asset.episodeNumber = Int(row.episode.trimmingCharacters(in: .whitespaces))
                let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
                asset.episode = title.isEmpty ? nil : title
                try store.updateAsset(asset)
            }
            await MainActor.run {
                let appliedIDs = Set(toApply.map(\.id))
                rows.removeAll { appliedIDs.contains($0.id) }
                isApplying = false
                NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
            }
        } catch {
            await MainActor.run {
                isApplying = false
                errorMessage = "Failed to apply: \(error.localizedDescription)"
            }
        }
    }
}

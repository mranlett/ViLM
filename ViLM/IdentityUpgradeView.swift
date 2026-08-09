// IdentityUpgradeView.swift
// The gate in front of the one irreversible operation in this project.
//
// ⭐ Read-only today. It runs every check and reports, and does not offer to
// re-key anything yet — the tool that does lands behind this screen, and having
// the gate first means the operator can see whether a library is ready long
// before anything can act on the answer.
//
// 🚨 Why a screen at all, rather than a migration. `LibraryStore` migrates on
// OPEN, so a gate expressed as a migration would either fail the app's startup
// or be skipped entirely. v28's D6 settled the split: the additive columns are
// a migration (v34), and everything that mints, re-points or moves a file is
// operator-invoked and runs against ONE library that the operator chose.

import SwiftUI
import LibraryCore

struct IdentityUpgradeView: View {
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var check: MigrationPreflight?
    @State private var isWorking = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Identity Upgrade")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Re-check") { Task { await run() } }
                            .disabled(isWorking)
                    }
                }
                .task { await run() }
        }
        .macSheet(minWidth: 620, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Checking the library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorMessage))
        } else if let check {
            List {
                verdictSection(check)
                if !check.duplicates.isEmpty { duplicatesSection(check) }
                if !check.unkeyableProfiles.isEmpty { unkeyableSection(check) }
                spaceSection(check)
                tombstoneSection(check)
                baselineSection(check)
            }
        }
    }

    // MARK: - Verdict

    @ViewBuilder
    private func verdictSection(_ check: MigrationPreflight) -> some View {
        Section {
            if check.canProceed {
                Label("This library is ready", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                // ⚠️ EVERY blocker, not the first. Fixing them one run at a
                // time is an operator making four passes at the same gate.
                ForEach(check.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Verdict")
        } footer: {
            Text(check.canProceed
                 ? "Nothing here changes anything. The upgrade itself is a separate, deliberate step — and the only part of this project that cannot be undone, so take a backup immediately before running it."
                 : "The upgrade will not start while any of the above is true. Each one would leave the library worse than it found it.")
        }
    }

    // MARK: - Blockers, each a list rather than a count

    @ViewBuilder
    private func duplicatesSection(_ check: MigrationPreflight) -> some View {
        Section {
            // A tally you cannot act on is a dead end — the rule this app
            // already follows everywhere else.
            ForEach(check.duplicates) { duplicate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(duplicate.displayName).font(.callout)
                    Text("\(duplicate.ids.count) records claim this name")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Names claimed twice — \(check.duplicates.count)")
        } footer: {
            Text("Each of these would become two separate records with two separate identities, and nothing afterwards could tell which one the name means. Merge them first.")
        }
    }

    @ViewBuilder
    private func unkeyableSection(_ check: MigrationPreflight) -> some View {
        Section {
            ForEach(check.unkeyableProfiles.prefix(20), id: \.self) { id in
                Text(id).font(.caption.monospaced())
            }
            if check.unkeyableProfiles.count > 20 {
                Text("…and \(check.unkeyableProfiles.count - 20) more")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } header: {
            Text("Records that cannot be identified — \(check.unkeyableProfiles.count)")
        } footer: {
            Text("These carry a key this build cannot read as a type and a name, so there is nothing to derive an identity from. They are left alone rather than guessed at.")
        }
    }

    // MARK: - Space

    @ViewBuilder
    private func spaceSection(_ check: MigrationPreflight) -> some View {
        Section {
            LabeledContent("Photos to copy", value: gb(check.photoBytes))
            LabeledContent("Space needed", value: gb(check.requiredBytes))
            LabeledContent("Free on this volume") {
                // ⚠️ "Couldn't read" rather than "0.00 GB". This volume is
                // ExFAT, which does not answer the capacity question macOS
                // asks first — and showing a zero told the operator their
                // 239 GB drive was full.
                Text(check.freeBytes.map(gb) ?? "couldn't read")
                    .foregroundStyle(check.hasEnoughSpace ? Color.primary : Color.orange)
            }
        } header: {
            Text("Disk")
        } footer: {
            // ⚠️ Required, not advisory. The photo move copies before it
            // deletes, so both names exist until the very last step — which is
            // the whole reason a crash loses nothing.
            // 🚨 Says ALLOCATED, because the figure looks wrong otherwise: the
            // photos are 1.6 GB of content occupying 3.2 GB of disk on a
            // 256 KB-block volume, and an operator comparing this against
            // Finder's "size" would think it had double-counted.
            Text("Every photo is copied to its new name before anything is committed, and the old ones are removed last. So both copies exist while the upgrade runs — that is what makes a crash at any point safe, and it is why the space is required rather than merely recommended.\n\nSizes are the space these files actually occupy on disk, which on this drive is well above the sum of their contents: it stores everything in 256 KB blocks, so thousands of small images each round up.")
        }
    }

    // MARK: - 🚨 Tombstones

    @ViewBuilder
    private func tombstoneSection(_ check: MigrationPreflight) -> some View {
        Section {
            LabeledContent("Deletion records", value: "\(check.tombstoneCount)")
        } header: {
            Text("Deletions")
        } footer: {
            // 🚨 Said on the screen, not only in the code. The obvious reading
            // of the spec was to re-key these along with everything else, and
            // on this library that would have blanked 1,102 of them and
            // resurrected every deleted entity on the next sync.
            Text(MigrationPreflight.tombstoneNote)
        }
    }

    // MARK: - Baseline

    @ViewBuilder
    private func baselineSection(_ check: MigrationPreflight) -> some View {
        Section {
            ForEach(check.edgeCounts.sorted(by: { $0.value > $1.value }), id: \.key) { table, count in
                LabeledContent(label(for: table), value: "\(count)")
            }
        } header: {
            Text("Connections that must survive")
        } footer: {
            Text("Counted per table rather than in total: an upgrade that moved the right NUMBER of connections onto the wrong records would pass a single figure. The upgrade re-counts these itself as it runs and stops if any table differs.")
        }
    }

    private func label(for table: String) -> String {
        switch table {
        case "video_performer":         return "Cast credits"
        case "video_studio":            return "Studios"
        case "video_tag":               return "Tags on videos"
        case "performer_tag":           return "Traits on performers"
        case "studio_parent":           return "Studio hierarchy"
        case "entity_match":            return "External identities"
        case "pending_tag_association": return "Tag links waiting"
        default:                        return table
        }
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    private func run() async {
        isWorking = true
        do {
            let url = libraryURL
            let result = try await Task.detached(priority: .userInitiated) {
                try LibraryStore(at: url).migrationPreflight()
            }.value
            check = result
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

/// Presents the gate.
///
/// ⚠️ A `ViewModifier` rather than one more `.sheet` in `ContentView`'s chain.
/// Adding a thirtieth modifier there defeated the Swift type checker outright —
/// "unable to type-check this expression in reasonable time" — which is a
/// recurring cost in this file. A modifier's body is checked on its own, so the
/// chain stops growing.
///
/// 🚨 Takes the SELECTED library, never the federated union. Identity is per
/// database: a uid minted in one library means nothing in another, which is
/// exactly why v28's D4 keeps federation resolving by name.
struct IdentityUpgradeSheet: ViewModifier {
    @Binding var isPresented: Bool
    let libraryURL: URL?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let libraryURL {
                IdentityUpgradeView(libraryURL: libraryURL)
            }
        }
    }
}

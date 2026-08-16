// ActorSyncView.swift
// The "Sync Actors" page for the multi-library session: lists every actor
// whose record differs across the open libraries, lets the user select one,
// many, or all, resolve true conflicts (pick a side, or Keep Both for the
// comma-list fields), and applies the convergence to EVERY open library —
// transactionally per library, with photos copied by content hash. The
// engine lives in LibraryCore/ActorSync.swift; this view is selection +
// conflict resolution + progress.

import SwiftUI
import ImageIO
import LibraryCore

struct ActorSyncView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [ActorSync.LibrarySnapshot] = []
    @State private var plans: [ActorSyncPlan] = []
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var resolutions: [String: [ActorSyncField: ActorSyncResolution]] = [:]
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var summary: String?
    /// One decoded avatar per (actor, source library) — keyed
    /// "actorId|libraryPath" — so DIFFERENT photos (or different people
    /// sharing a name) are visible before merging. Decoded once at load from
    /// the snapshot photo bytes already in memory.
    @State private var sourceThumbnails: [String: PlatformImage] = [:]

    private nonisolated static func thumbnailKey(_ actorId: String, _ url: URL) -> String {
        "\(actorId)|\(url.path)"
    }

    private var filteredPlans: [ActorSyncPlan] {
        guard !searchText.isEmpty else { return plans }
        return plans.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedConflictCount: Int {
        plans.filter { selected.contains($0.actorId) }
            .reduce(0) { total, plan in
                total + plan.conflicts.filter { resolutions[plan.actorId]?[$0.field] == nil }.count
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    centered {
                        ProgressView("Comparing actor databases…")
                        Text("Reading every open library's actors and photo galleries.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else if isApplying {
                    centered { ProgressView("Syncing…") }
                } else if let summary {
                    centered {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44)).foregroundColor(.green)
                        Text("Sync Complete").font(.title3.bold())
                        Text(summary)
                            .font(.callout).foregroundColor(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 28)
                        if !plans.isEmpty {
                            Button("Review Remaining Differences") { self.summary = nil }
                                .buttonStyle(.bordered)
                        }
                    }
                } else if plans.isEmpty {
                    ContentUnavailableView {
                        Label("All Actors In Sync", systemImage: "person.2.badge.gearshape")
                    } description: {
                        Text("Every open library holds the same actor records and photos.")
                    }
                } else {
                    planList
                }
            }
            .navigationTitle("Sync Actors")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !isLoading, summary == nil, !plans.isEmpty {
                    ToolbarItem(placement: .primaryAction) { selectionMenu }
                }
            }
        }
        .macSheet(minWidth: 520, minHeight: 540)
        .task { await load() }
    }

    // MARK: - List

    private var planList: some View {
        VStack(spacing: 0) {
            List {
                Section(footer: footerText) {
                    ForEach(filteredPlans) { plan in
                        planRow(plan)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search actors")

            Divider()
            HStack {
                if selectedConflictCount > 0 {
                    Label("\(selectedConflictCount) unresolved conflict\(selectedConflictCount == 1 ? "" : "s") will be left unchanged",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange)
                }
                Spacer()
                Button {
                    Task { await apply() }
                } label: {
                    Text("Sync \(selected.count) Selected").font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding()
        }
    }

    private var footerText: Text {
        Text("Sync copies missing actors, fills blank fields, and combines photo galleries across every open library. Nothing is ever deleted.")
    }

    private var selectionMenu: some View {
        Menu {
            Button("Select All (\(plans.count))") { selected = Set(plans.map(\.actorId)) }
            Button("Select Conflict-Free (\(plans.filter { $0.conflicts.isEmpty }.count))") {
                selected = Set(plans.filter { $0.conflicts.isEmpty }.map(\.actorId))
            }
            Button("Deselect All") { selected = [] }
            Divider()
            ForEach(snapshots, id: \.url) { snapshot in
                Button("Resolve all conflicts using “\(LibrarySession.shared.shortLabel(for: snapshot.url))”") {
                    resolveAllConflicts(preferring: snapshot.url)
                }
            }
        } label: {
            Image(systemName: "checklist")
        }
        .accessibilityLabel("Selection and conflict options")
    }

    // MARK: - Rows

    @ViewBuilder
    private func planRow(_ plan: ActorSyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if selected.contains(plan.actorId) {
                        selected.remove(plan.actorId)
                    } else {
                        selected.insert(plan.actorId)
                    }
                } label: {
                    Image(systemName: selected.contains(plan.actorId) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(selected.contains(plan.actorId) ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected.contains(plan.actorId)
                    ? "Deselect \(plan.displayName)" : "Select \(plan.displayName)")

                sourceAvatars(for: plan)

                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.displayName).font(.callout.weight(.semibold))
                    badgeRow(plan)
                }

                Spacer()

                Button {
                    if expanded.contains(plan.actorId) {
                        expanded.remove(plan.actorId)
                    } else {
                        expanded.insert(plan.actorId)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded.contains(plan.actorId) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(plan.displayName)")
            }
            .contentShape(Rectangle())

            if expanded.contains(plan.actorId) {
                planDetails(plan)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func badgeRow(_ plan: ActorSyncPlan) -> some View {
        let photoTotal = plan.photoAdds.values.reduce(0, +)
        let fillTotal = plan.blankFills.values.reduce(0, +)
        let listTotal = plan.listAdds.values.reduce(0, +)
        FlowLayout(spacing: 5) {
            ForEach(plan.missingFrom, id: \.self) { url in
                badge("not in \(LibrarySession.shared.shortLabel(for: url))", color: .red)
            }
            if fillTotal > 0 { badge("fills \(fillTotal) field\(fillTotal == 1 ? "" : "s")", color: .blue) }
            if photoTotal > 0 { badge("+\(photoTotal) photo\(photoTotal == 1 ? "" : "s")", color: .teal) }
            if listTotal > 0 { badge("+\(listTotal) tag\(listTotal == 1 ? "" : "s")/AKAs", color: .purple) }
            if !plan.conflicts.isEmpty {
                let resolved = plan.conflicts.filter { resolutions[plan.actorId]?[$0.field] != nil }.count
                badge(resolved == plan.conflicts.count
                        ? "✓ \(plan.conflicts.count) resolved"
                        : "⚠ \(plan.conflicts.count) conflict\(plan.conflicts.count == 1 ? "" : "s")",
                      color: resolved == plan.conflicts.count ? .green : .orange)
            }
        }
    }

    /// One avatar per library that has this actor, in precedence order and
    /// labeled — different photos (or different people) show at a glance.
    private func sourceAvatars(for plan: ActorSyncPlan) -> some View {
        HStack(spacing: 6) {
            ForEach(snapshots, id: \.url) { snapshot in
                if snapshot.export.profiles.contains(where: { $0.id == plan.actorId }) {
                    VStack(spacing: 2) {
                        Group {
                            if let image = sourceThumbnails[Self.thumbnailKey(plan.actorId, snapshot.url)] {
                                Image(platformImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.dashed")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))

                        Text(LibrarySession.shared.shortLabel(for: snapshot.url))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 46)
                    }
                    .help(LibrarySession.shared.fullLabel(for: snapshot.url))
                    .accessibilityLabel("\(plan.displayName)'s photo in \(LibrarySession.shared.fullLabel(for: snapshot.url))")
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundColor(color)
    }

    @ViewBuilder
    private func planDetails(_ plan: ActorSyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.conflicts, id: \.field) { conflict in
                conflictPicker(actorId: plan.actorId, conflict: conflict)
            }
            if plan.conflicts.isEmpty {
                Text("No conflicts — syncing combines what each library knows.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func conflictPicker(actorId: String, conflict: ActorSyncConflict) -> some View {
        let current = resolutions[actorId]?[conflict.field]
        VStack(alignment: .leading, spacing: 6) {
            Text(conflict.field.displayName)
                .font(.caption.bold())
                .foregroundColor(.orange)

            ForEach(conflict.values, id: \.value) { source in
                resolutionOption(
                    isOn: current == .use(source.value),
                    title: source.value,
                    subtitle: source.libraries
                        .map { LibrarySession.shared.shortLabel(for: $0) }
                        .joined(separator: ", ")
                ) {
                    setResolution(actorId: actorId, field: conflict.field,
                                  to: current == .use(source.value) ? nil : .use(source.value))
                }
            }

            if conflict.supportsKeepBoth {
                resolutionOption(
                    isOn: current == .keepBoth,
                    title: "Keep Both — “\(conflict.keepBothValue)”",
                    subtitle: "each value stays individually filterable"
                ) {
                    setResolution(actorId: actorId, field: conflict.field,
                                  to: current == .keepBoth ? nil : .keepBoth)
                }
            }

            if current == nil {
                Text("Unresolved — this field stays as-is in each library.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
    }

    private func resolutionOption(isOn: Bool, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isOn ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                    Text(subtitle).font(.caption2).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func setResolution(actorId: String, field: ActorSyncField, to resolution: ActorSyncResolution?) {
        if let resolution {
            resolutions[actorId, default: [:]][field] = resolution
        } else {
            resolutions[actorId]?[field] = nil
        }
    }

    private func resolveAllConflicts(preferring url: URL) {
        for plan in plans {
            for conflict in plan.conflicts {
                if let source = conflict.values.first(where: { $0.libraries.contains(url) }) {
                    resolutions[plan.actorId, default: [:]][conflict.field] = .use(source.value)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        let urls = LibrarySession.shared.allURLs
        do {
            let (snaps, planned, thumbs) = try await ScopedOperation.run(holding: urls) {
                try await Task.detached(priority: .utility) { () -> ([ActorSync.LibrarySnapshot], [ActorSyncPlan], [String: PlatformImage]) in
                    let snaps = try urls.map { try ActorSync.snapshot(of: $0) }
                    let planned = ActorSync.plan(for: snaps)
                    // One avatar per (differing actor, source library),
                    // decoded from the photo bytes the snapshots already
                    // carry — primary first, else the first gallery photo.
                    var thumbs: [String: PlatformImage] = [:]
                    let plannedIds = Set(planned.map(\.actorId))
                    for snap in snaps {
                        var pickByActor: [String: ExportedPhoto] = [:]
                        for photo in snap.export.photos where plannedIds.contains(photo.actorId) {
                            if photo.isPrimary || pickByActor[photo.actorId] == nil {
                                pickByActor[photo.actorId] = photo
                            }
                        }
                        let profilesDir = snap.url.appendingPathComponent(".catalog/profiles")
                        for (actorId, photo) in pickByActor {
                            // Decoded straight from the file rather than from
                            // `photo.data`: planning snapshots carry hashes
                            // without bytes, so the array is empty here. Going
                            // via the URL also means only a 160px thumbnail is
                            // ever resident, never the full JPEG.
                            let fileName = ProfileImageNaming.fileName(
                                for: actorId, token: photo.sourceToken, isGallery: !photo.isPrimary)
                            let fileURL = profilesDir.appendingPathComponent(fileName)
                            if let image = Self.decodeThumbnail(at: fileURL) {
                                thumbs[Self.thumbnailKey(actorId, snap.url)] = image
                            }
                        }
                    }
                    return (snaps, planned, thumbs)
                }.value
            }
            Self.logPlan(planned, snapshots: snaps)
            snapshots = snaps
            plans = planned
            sourceThumbnails = thumbs
            selected = Set(planned.filter { $0.conflicts.isEmpty }.map(\.actorId))
            isLoading = false
        } catch {
            isLoading = false
            AppErrorReporter.report("Couldn't compare the actor databases: \(error.localizedDescription)")
            dismiss()
        }
    }

    /// Prints why each listed actor is listed.
    ///
    /// A sync that will not converge reports no error — the same names simply
    /// come back after every apply. This is the only signal that distinguishes
    /// a photo gap from a field gap without reading the merge code.
    nonisolated static func logPlan(_ plans: [ActorSyncPlan],
                                    snapshots: [ActorSync.LibrarySnapshot],
                                    phase: String = "PLAN") {
        print("╔══ SYNC \(phase): \(plans.count) actor(s) differ ══")
        for plan in plans.prefix(40) {
            print("║ \(plan.displayName): \(plan.diagnosis())")
        }
        if plans.count > 40 { print("║ … \(plans.count - 40) more") }
        // Full side-by-side for the first few — enough to spot the pattern
        // without flooding the console on a first-ever sync.
        for plan in plans.prefix(5) {
            print(ActorSync.diagnosticDump(actorId: plan.actorId, snapshots: snapshots))
        }
        print("╚══════════════════════════════════════")
    }

    private nonisolated static func decodeThumbnail(at url: URL) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    private func apply() async {
        isApplying = true
        let actorIds = selected
        let chosenResolutions = resolutions
        let snaps = snapshots
        let urls = snaps.map(\.url)
        let unresolved = selectedConflictCount

        do {
            try await ScopedOperation.run(holding: urls) {
                try await Task.detached(priority: .utility) {
                    // Applied in batches, re-reading photo bytes for only the
                    // actors in each batch.
                    //
                    // `snaps` carries hashes but no photo data, so the bytes
                    // have to be fetched here. Fetching them for every selected
                    // actor at once is what exhausted memory and killed the app
                    // mid-sync: one real library holds 2.3 GB of profile
                    // photos. A batch keeps peak usage flat no matter how many
                    // actors are selected.
                    let ordered = Array(actorIds)
                    for start in stride(from: 0, to: ordered.count, by: 50) {
                        let ids = Set(ordered[start..<min(start + 50, ordered.count)])
                        let dataSnaps = try urls.map {
                            try ActorSync.photoBearingSnapshot(of: $0, actorIds: ids)
                        }
                        let export = ActorSync.convergedExport(
                            actorIds: ids, resolutions: chosenResolutions, snapshots: dataSnaps)
                        for url in urls {
                            try ActorSync.apply(export, to: url)
                        }
                    }
                }.value
            }

            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)

            var lines = ["Synced \(actorIds.count) actor\(actorIds.count == 1 ? "" : "s") across \(urls.count) libraries."]
            if unresolved > 0 {
                lines.append("\(unresolved) conflicted field\(unresolved == 1 ? "" : "s") left unchanged — resolve and sync again anytime.")
            }
            isApplying = false
            summary = lines.joined(separator: " ")
            // Re-plan so "Review Remaining Differences" shows live state. The
            // PLAN block that follows this line is the one that matters when
            // actors will not clear: anything still listed here was just
            // synced and came back.
            print("══ SYNC APPLIED \(actorIds.count) actor(s) across \(urls.count) libraries — re-planning ══")
            await load()
            isLoading = false
        } catch {
            isApplying = false
            AppErrorReporter.report("Sync failed: \(error.localizedDescription)")
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

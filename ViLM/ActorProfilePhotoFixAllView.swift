// ActorProfilePhotoFixAllView.swift
// Settings tool: reconcile every actor's profile photo against the files that
// are actually in `.catalog/profiles`.
//
// TRACKED and PUBLIC. Names no source.
//
// 🚨 NEVER GOES ONLINE, and that is the operator's explicit choice rather than
// an oversight: "We do not go online to display the profile images once
// downloaded from an initial online sourcing." A performer with no photo on
// disk is COUNTED and reported, never fetched.
//
// ⭐ Which makes the report the point as much as the repairs are. "Get More
// Photos" adds URLs to galleries and downloads nothing — bytes only reach the
// disk when a card is displayed — so "no local photo" is the number that says
// whether a local-only pass can help this library at all. A run that repairs
// nothing and says so is a result, not a failure.

import SwiftUI
import LibraryCore

struct ActorProfilePhotoFixAllView: View {
    let libraryURL: URL
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isRunning = false
    @State private var progress = 0
    @State private var total = 0
    @State private var summary: ActorProfilePhotoFixAll.Summary?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    /// ⚠️ Applied in batches rather than one performer at a time: each batch is
    /// one hop off the main actor, and a hop per performer would spend more
    /// time switching actors than copying files.
    ///
    /// 🚨 Every hop runs at `.utility`, never `.userInitiated` — F2's rule, and
    /// this screen is its textbook case: it sweeps the whole library and says
    /// "Checking 412 of 1,375" while it does. The status text is the tell that
    /// the user is no longer in a tap-to-response interaction, and interactive
    /// priority over a sweep this size is how a phone gets hot.
    /// `QoSConventionTests` enforces this and caught it here.
    private let batchSize = 25

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Fix Profile Photos")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { task?.cancel(); dismiss() }
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(errorMessage ?? "") }
        }
        .macSheet(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Text("Gives back the profile picture of any performer whose photo file is "
                     + "missing, using another photo already downloaded for them.")
                    .font(.callout)
                Text("Never downloads anything. A performer with no photo on this device is "
                     + "reported below rather than fetched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if isRunning {
                Section {
                    // ⭐ Determinate: the number of performers is known before
                    // the first one is examined, so there is no reason to show
                    // a spinner and no excuse for one.
                    ProgressView(value: Double(progress), total: Double(max(total, 1))) {
                        Text("Checking \(progress) of \(total)…")
                    }
                    Button("Stop", role: .destructive) { task?.cancel() }
                }
            } else if let summary {
                Section {
                    row("Already had a photo", summary.alreadyFine)
                    row("Photo restored", summary.repaired)
                    row("No photo on this device", summary.noLocalSource)
                    if summary.failed > 0 { row("Could not be written", summary.failed) }
                } header: {
                    Text("Result")
                } footer: {
                    Text(verdict(summary)).font(.caption)
                }
            }

            Section {
                Button(isRunning ? "Working…" : "Check All Performers") {
                    task = Task { await run() }
                }
                .disabled(isRunning)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func row(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// 🚨 Says what the numbers MEAN, because the most likely outcome here is
    /// "restored 0", and that reads as a broken tool unless it is explained.
    /// The distinction that matters is nothing-was-broken versus
    /// nothing-could-be-fixed-from-here.
    private func verdict(_ summary: ActorProfilePhotoFixAll.Summary) -> String {
        if summary.noLocalSource == 0 && summary.repaired == 0 {
            return "Every performer already had their photo. Nothing needed fixing."
        }
        if summary.noLocalSource > 0 {
            return "\(summary.noLocalSource) performer\(summary.noLocalSource == 1 ? " has" : "s have") "
                + "no photo stored on this device, so there is nothing local to restore theirs from. "
                + "Their pictures were listed but never downloaded — opening their profile "
                + "downloads one."
        }
        return "Restored from photos already on this device."
    }

    // MARK: - Running

    /// ⚠️ Three hops, for the reason `ActorPhotoTopUpView` records: reading and
    /// writing are disk work and belong off the main actor, but `LibrarySession`
    /// is `@MainActor`, so each profile's owning library is resolved in between.
    @MainActor
    private func run() async {
        isRunning = true
        summary = nil
        progress = 0
        defer { isRunning = false }

        let libraryURL = self.libraryURL
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")

        // 1 — read the catalogue and the directory, once each.
        let prepared = await Task.detached(priority: .utility) {
            () -> (actors: [EntityProfile], files: Set<String>)? in
            guard let store = try? LibraryStore(at: libraryURL),
                  let profiles = try? store.fetchAllEntityProfiles() else { return nil }
            return (profiles.filter { $0.type == "actor" },
                    ActorProfilePhotoFixAll.existingFileNames(in: profilesDir))
        }.value
        guard !Task.isCancelled else { return }
        guard let prepared else {
            errorMessage = "This library's catalogue could not be opened."
            return
        }

        total = prepared.actors.count

        // 2 — decide. Pure and in memory, so it costs nothing to do here.
        var result = ActorProfilePhotoFixAll.Summary()
        var work: [(profile: EntityProfile, promotion: ActorProfilePhotoFixAll.Promotion)] = []
        for actor in prepared.actors {
            switch ActorProfilePhotoFixAll.plan(for: actor, existingFiles: prepared.files) {
            case .alreadyFine:      result.alreadyFine += 1
            case .noLocalSource:    result.noLocalSource += 1
            case let .promote(p):   work.append((actor, p))
            }
        }
        // Everything not needing a promotion is already accounted for.
        progress = result.alreadyFine + result.noLocalSource

        // 3 — the owning library of each profile, while we are on the main actor.
        var owners: [String: URL] = [:]
        for item in work { owners[item.profile.id] = LibrarySession.shared.url(forProfile: item.profile.id) }

        // 4 — apply, a batch at a time.
        for start in stride(from: 0, to: work.count, by: batchSize) {
            guard !Task.isCancelled else { break }
            let batch = Array(work[start..<min(start + batchSize, work.count)])
            let applied = await Task.detached(priority: .utility) { () -> (Int, Int) in
                var repaired = 0
                var failed = 0
                for item in batch {
                    // ⚠️ Counted, never silently skipped — an unreachable
                    // library and an unwritable row are different problems,
                    // and silence about either is what made the previous
                    // attempt at this impossible to diagnose.
                    guard let owner = owners[item.profile.id] else { failed += 1; continue }
                    do {
                        let fixed = try ActorProfilePhotoFixAll.apply(
                            item.promotion, to: item.profile, profilesDir: profilesDir)
                        try LibraryStore(at: owner).saveEntityProfile(fixed)
                        repaired += 1
                    } catch {
                        failed += 1
                    }
                }
                return (repaired, failed)
            }.value
            result.repaired += applied.0
            result.failed += applied.1
            progress += batch.count
        }

        summary = result
        if result.repaired > 0 { onCompleted() }
    }
}

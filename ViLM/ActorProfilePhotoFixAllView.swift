// ActorProfilePhotoFixAllView.swift
// Settings tool: reconcile every actor's profile photo against the files that
// are actually in `.catalog/profiles`.
//
// TRACKED and PUBLIC. Names no source.
//
// 🚨 THE INVARIANT: a performer's photos are LOCAL OR ABSENT. There is no
// third state in which a URL is recorded for a download that might happen
// later. That state is what let 475 performers lose their files silently — the
// entries went on looking authoritative, so nothing ever reported a loss.
//
// ⭐ So this does three things in order, and the order is the point:
//   1. promote a photo already on disk (free, and fixes the easy cases first);
//   2. download what is recorded but missing, primary first, so a run stopped
//      half way has restored faces rather than filled galleries behind them;
//   3. drop entries whose photo is definitively gone, which is what actually
//      collapses the third state rather than merely papering over it.
//
// ⚠️ It downloads, and an earlier version of this file said it never would.
// That was the operator's instruction at the time and it was tested: a
// local-only run over the real library reported 848 already fine, 0 restored
// and 475 with nothing on disk to restore from. Nothing local existed, so
// nothing local could help. The rule it was honouring — "we do not go online
// to DISPLAY" — is about rendering a card, and is untouched: this is sourcing,
// done once, on demand, so that display never has to.

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
    /// 🚨 The tally AS IT HAPPENS. The first version only reported at the end,
    /// so the only way to find out what a long run was doing was to stop it —
    /// which is the one action that guarantees it stops doing it.
    @State private var live = ActorProfilePhotoFixAll.Summary()
    /// Which of the four phases is running, in the operator's words.
    @State private var phase = ""
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
                     + "missing — from a photo already on this device where there is one, "
                     + "and by downloading it where there is not.")
                    .font(.callout)
                Text("Photos are stored on this device or not at all. An entry whose photo no "
                     + "longer exists at its source is removed; one that merely could not be "
                     + "reached today is kept and reported. The first run can take a while.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if isRunning {
                Section {
                    // ⭐ Determinate, and re-based per phase: one bar spanning
                    // four phases of different lengths tells the operator less
                    // than a bar per phase plus the phase's name.
                    ProgressView(value: Double(progress), total: Double(max(total, 1))) {
                        Text(phase.isEmpty ? "Working…" : phase)
                    }
                    Text(total > 0 ? "\(progress) of \(total) performers" : "…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button("Stop", role: .destructive) { task?.cancel() }
                } header: {
                    Text("Progress")
                }
            }

            // 🚨 Shown WHILE running as well as after. These numbers are the
            // answer to "what is it doing", and they were previously locked
            // behind finishing or cancelling.
            if isRunning || summary != nil {
                let summary = summary ?? live
                Section {
                    if !isRunning { row("Already had a photo", summary.alreadyFine) }
                    row("Photo restored", summary.repaired)
                    row("Photos downloaded", summary.photosDownloaded)
                    if summary.entriesDropped > 0 {
                        row("Dead entries removed", summary.entriesDropped)
                    }
                    if summary.entriesUnavailable > 0 {
                        row("Could not be reached today", summary.entriesUnavailable)
                    }
                    if !isRunning { row("Still without a photo", summary.noLocalSource) }
                    if summary.failed > 0 { row("Could not be written", summary.failed) }
                } header: {
                    Text(isRunning ? "So far" : "Result")
                } footer: {
                    if !isRunning { Text(verdict(summary)).font(.caption) }
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
        if summary.entriesUnavailable > 0 {
            return "\(summary.entriesUnavailable) photo\(summary.entriesUnavailable == 1 ? "" : "s") "
                + "could not be reached today and were kept, not deleted — running this again "
                + "when the connection is better will pick them up."
        }
        if summary.noLocalSource > 0 {
            return "\(summary.noLocalSource) performer\(summary.noLocalSource == 1 ? " has" : "s have") "
                + "no photo at all: nothing on this device, and nothing left at the addresses "
                + "recorded for them."
        }
        if summary.repaired == 0 && summary.photosDownloaded == 0 {
            return "Every performer already had their photo. Nothing needed fixing."
        }
        return "Every performer's photos are now stored on this device."
    }

    // MARK: - Running

    /// ⚠️ Three hops, for the reason `ActorPhotoTopUpView` records: reading and
    /// writing are disk work and belong off the main actor, but `LibrarySession`
    /// is `@MainActor`, so each profile's owning library is resolved in between.
    ///
    /// 🚨 FOUR PHASES, ORDERED BY WHAT AN OPERATOR LOSES BY STOPPING. The first
    /// version ordered them by what was convenient to compute, and it showed:
    /// a run left going for a long while downloaded 214 photos and gave back
    /// three faces, because it was filling the galleries of performers who
    /// already had a picture while 472 still had none. Restoring a face is the
    /// whole point; the rest of someone's gallery can wait for a later pass.
    @MainActor
    private func run() async {
        isRunning = true
        summary = nil
        live = ActorProfilePhotoFixAll.Summary()
        progress = 0
        total = 0
        defer { isRunning = false; phase = "" }

        let libraryURL = self.libraryURL
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")

        phase = "Reading the library"
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

        // Owning libraries, while we are on the main actor.
        var owners: [String: URL] = [:]
        for actor in prepared.actors { owners[actor.id] = LibrarySession.shared.url(forProfile: actor.id) }

        var files = prepared.files
        var result = ActorProfilePhotoFixAll.Summary()

        func primaryExists(_ actor: EntityProfile) -> Bool {
            files.contains(ProfileImageNaming.primaryFileName(for: actor.id))
        }

        /// Writes a profile through its owning library. Returns false on a
        /// failure the summary should count.
        func save(_ profile: EntityProfile) async -> Bool {
            guard let owner = owners[profile.id] else { return false }
            return await Task.detached(priority: .utility) {
                ((try? LibraryStore(at: owner).saveEntityProfile(profile)) != nil)
            }.value
        }

        // ── Phase 1: promote what is already on disk. Free, no network.
        phase = "Checking photos already on this device"
        total = prepared.actors.count
        progress = 0
        for actor in prepared.actors {
            guard !Task.isCancelled else { return finish(result) }
            progress += 1
            switch ActorProfilePhotoFixAll.plan(for: actor, existingFiles: files) {
            case .alreadyFine:
                result.alreadyFine += 1
            case .noLocalSource:
                break // decided in phase 2, which may well fix them
            case let .promote(promotion):
                let applied = await Task.detached(priority: .utility) { () -> EntityProfile? in
                    try? ActorProfilePhotoFixAll.apply(promotion, to: actor, profilesDir: profilesDir)
                }.value
                if let applied, await save(applied) {
                    result.repaired += 1
                    files.insert(ProfileImageNaming.primaryFileName(for: actor.id))
                } else {
                    result.failed += 1
                }
            }
            live = result
        }

        // ── Phase 2: 🚨 FACES FIRST. Only performers with no picture at all,
        //    and only until ONE photo lands for each. The rest of their gallery
        //    is phase 3's job — stopping here should mean everyone has a face.
        let faceless = prepared.actors.filter { !primaryExists($0) }
        phase = "Restoring missing profile photos"
        total = faceless.count
        progress = 0
        for actor in faceless {
            guard !Task.isCancelled else { return finish(result) }
            progress += 1
            // ⭐ One photo is enough here — `reconcile` stops at the first that
            // lands, and `missingPhotos` offers the primary first, so the one
            // it takes is the right one.
            let outcome = await ActorProfilePhotoFixAll.reconcile(
                actor, existingFiles: files, profilesDir: profilesDir,
                stopAfterFirstDownload: true, isCancelled: { Task.isCancelled })
            result.photosDownloaded += outcome.downloaded
            result.entriesUnavailable += outcome.unavailable
            files.formUnion(outcome.filesAdded)
            if let pruned = outcome.updatedProfile {
                if await save(pruned) { result.entriesDropped += outcome.dropped } else { result.failed += 1 }
            }
            live = result

            // A gallery photo landed but the primary slot is still empty.
            if !primaryExists(actor),
               case let .promote(promotion) = ActorProfilePhotoFixAll.plan(
                    for: actor, existingFiles: files) {
                let applied = await Task.detached(priority: .utility) { () -> EntityProfile? in
                    try? ActorProfilePhotoFixAll.apply(promotion, to: actor, profilesDir: profilesDir)
                }.value
                if let applied, await save(applied) {
                    result.repaired += 1
                    files.insert(ProfileImageNaming.primaryFileName(for: actor.id))
                }
            }
            live = result
        }

        // ── Phase 3: everything else recorded but missing. ⚠️ Last on purpose:
        //    this is the long one, and nobody is faceless while it runs.
        let remaining = prepared.actors.filter {
            !ActorProfilePhotoFixAll.missingPhotos(for: $0, existingFiles: files).isEmpty
        }
        phase = "Storing the rest of each gallery"
        total = remaining.count
        progress = 0
        for actor in remaining {
            guard !Task.isCancelled else { return finish(result) }
            progress += 1
            let outcome = await ActorProfilePhotoFixAll.reconcile(
                actor, existingFiles: files, profilesDir: profilesDir,
                isCancelled: { Task.isCancelled })
            result.photosDownloaded += outcome.downloaded
            result.entriesUnavailable += outcome.unavailable
            files.formUnion(outcome.filesAdded)
            if let pruned = outcome.updatedProfile {
                if await save(pruned) { result.entriesDropped += outcome.dropped } else { result.failed += 1 }
            }
            live = result
        }

        finish(result)

        /// ⚠️ `noLocalSource` is counted against the FINAL state, never the one
        /// the run started from — most of it is what this run just fixed.
        func finish(_ partial: ActorProfilePhotoFixAll.Summary) {
            var final = partial
            final.noLocalSource = prepared.actors.filter { !primaryExists($0) }.count
            // Recomputed too, for the same reason: a performer repaired in
            // phase 2 was not "already fine" when phase 1 counted them.
            final.alreadyFine = prepared.actors.count - final.noLocalSource - final.repaired
            summary = final
            live = final
            if final.repaired > 0 || final.photosDownloaded > 0 { onCompleted() }
        }
    }
}

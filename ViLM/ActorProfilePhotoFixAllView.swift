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
                    row("Photos downloaded", summary.photosDownloaded)
                    if summary.entriesDropped > 0 {
                        row("Dead entries removed", summary.entriesDropped)
                    }
                    if summary.entriesUnavailable > 0 {
                        row("Could not be reached today", summary.entriesUnavailable)
                    }
                    row("Still without a photo", summary.noLocalSource)
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
        // ⚠️ Provisional: `noLocalSource` is recomputed in step 7 against the
        // files that exist once downloading has run. Counting it here would
        // report as hopeless every performer this run is about to fix.
        progress = result.alreadyFine + result.noLocalSource
        result.noLocalSource = 0

        // 3 — the owning library of each profile, while we are on the main actor.
        //     ⚠️ Resolved for EVERY actor, not just the ones needing a
        //     promotion: the download phase writes profiles too.
        var owners: [String: URL] = [:]
        for actor in prepared.actors { owners[actor.id] = LibrarySession.shared.url(forProfile: actor.id) }

        // 4 — promote what is already here. Free, and it settles the easy
        //     cases before a single byte crosses the network.
        var files = prepared.files
        for start in stride(from: 0, to: work.count, by: batchSize) {
            guard !Task.isCancelled else { summary = result; return }
            let batch = Array(work[start..<min(start + batchSize, work.count)])
            let applied = await Task.detached(priority: .utility) { () -> (Int, Int, [String]) in
                var repaired = 0
                var failed = 0
                var landed: [String] = []
                for item in batch {
                    guard let owner = owners[item.profile.id] else { failed += 1; continue }
                    do {
                        let fixed = try ActorProfilePhotoFixAll.apply(
                            item.promotion, to: item.profile, profilesDir: profilesDir)
                        try LibraryStore(at: owner).saveEntityProfile(fixed)
                        repaired += 1
                        landed.append(ProfileImageNaming.primaryFileName(for: item.profile.id))
                    } catch {
                        failed += 1
                    }
                }
                return (repaired, failed, landed)
            }.value
            result.repaired += applied.0
            result.failed += applied.1
            files.formUnion(applied.2)
            progress += batch.count
        }

        // 5 — download what is recorded and missing, and drop what is gone.
        //
        //     🚨 This is the phase that collapses the third state. A recorded
        //     URL with no file is a claim the library cannot support; after
        //     this it is either a file or it is not recorded.
        //
        //     ⚠️ Sequential, one photo at a time, for the reason the top-up
        //     gives: several hundred concurrent requests is how a rate limit
        //     gets discovered the hard way.
        var stillBroken = 0
        for actor in prepared.actors {
            guard !Task.isCancelled else { break }
            let missing = ActorProfilePhotoFixAll.missingPhotos(for: actor, existingFiles: files)
            guard !missing.isEmpty else { continue }

            var gone: Set<String> = []
            for photo in missing {
                guard !Task.isCancelled else { break }
                let destination = profilesDir.appendingPathComponent(photo.fileName)
                switch await ActorPhotoFetch.download(photo.token, to: destination) {
                case .downloaded:
                    result.photosDownloaded += 1
                    files.insert(photo.fileName)
                case .gone:
                    gone.insert(photo.token)
                case .unavailable:
                    result.entriesUnavailable += 1
                }
            }

            // The profile stops claiming photos that exist nowhere.
            if let owner = owners[actor.id],
               let pruned = ActorProfilePhotoFixAll.dropping(gone, from: actor) {
                do {
                    try LibraryStore(at: owner).saveEntityProfile(pruned)
                    result.entriesDropped += gone.count
                } catch {
                    result.failed += 1
                }
            }
        }

        // 6 — anything that now has photos but still no primary. ⭐ Reuses the
        //     same `plan`, against the files that exist NOW: a performer whose
        //     `photoUrl` was empty gained gallery files above and needs one of
        //     them promoted, which only this pass can know.
        for actor in prepared.actors {
            guard !Task.isCancelled else { break }
            guard case let .promote(promotion) = ActorProfilePhotoFixAll.plan(
                    for: actor, existingFiles: files) else { continue }
            guard let owner = owners[actor.id] else { result.failed += 1; continue }
            do {
                let fixed = try ActorProfilePhotoFixAll.apply(
                    promotion, to: actor, profilesDir: profilesDir)
                try LibraryStore(at: owner).saveEntityProfile(fixed)
                result.repaired += 1
                files.insert(ProfileImageNaming.primaryFileName(for: actor.id))
            } catch {
                result.failed += 1
            }
        }

        // 7 — who is STILL without a photo, counted against the final state
        //     rather than the one this run started from. ⚠️ `noLocalSource`
        //     was provisional until now: most of it was about to be downloaded.
        for actor in prepared.actors
        where !files.contains(ProfileImageNaming.primaryFileName(for: actor.id)) {
            stillBroken += 1
        }
        result.noLocalSource = stillBroken

        summary = result
        if result.repaired > 0 || result.photosDownloaded > 0 { onCompleted() }
    }
}

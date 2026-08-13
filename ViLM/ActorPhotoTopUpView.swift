// ActorPhotoTopUpView.swift
// Settings tool: fill in galleries for performers with barely any pictures (#44).
//
// TRACKED and PUBLIC. Names no source.
//
// 🚨 Adds to the gallery and never touches `photoUrl`. The rule and the reason
// live in `ActorPhotoTopUp`; this screen must not quietly acquire an exception
// to it.
//
// ⚠️ Sequential and cancellable. Three hundred requests fired at once is how a
// rate limit gets discovered the hard way, and what has already been applied
// stays applied when the operator stops.

import SwiftUI
import LibraryCore

struct ActorPhotoTopUpView: View {
    let libraryURL: URL
    /// For the pool's video-count clause. ⚠️ Real counts, not zeroes: a filter
    /// on "at least N videos" against zeroed counts admits nobody, and the
    /// operator sees an empty list with no idea why.
    let assets: [Asset]
    /// For the pool's photo clauses, which mean "on disk" rather than "recorded
    /// in the profile".
    let profileImageFileNames: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ActorPhotoTopUp.Candidate] = []
    @State private var selected: Set<String> = []
    @State private var threshold = ActorPhotoTopUp.defaultThreshold

    /// Who is eligible at all — the same criteria, the same builder and the
    /// same matcher the actor grid and Head to Head use.
    ///
    /// ⭐ Persisted, because this is a standing preference rather than a
    /// per-run choice: an operator who never wants to spend requests on part of
    /// the library should not have to re-say so every time.
    ///
    /// ⚠️ Empty by default. A tool that quietly skipped performers would look
    /// like it had finished the library when it had not.
    @AppStorage("photoTopUpPoolStr") private var poolStr: String = ""
    @State private var isShowingPool = false
    @State private var vocabulary = ActorFilterVocabulary()
    /// ⚠️ Off by default, but never hidden without being counted — a list that
    /// quietly omits people reads as a library with fewer thin profiles.
    @State private var showsExhausted = false
    @State private var exhaustedCount = 0
    /// For saying what the filter COSTS, in performers rather than in clauses.
    @State private var pooledCount = 0
    @State private var totalActors = 0
    @State private var isRunning = false
    @State private var progress = 0
    @State private var toppedUp = 0
    @State private var nothingNew = 0
    @State private var failed = 0
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    private var provider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installedActorProviders().first
    }
    private var fetchable: [ActorPhotoTopUp.Candidate] { candidates.filter(\.canFetch) }

    private var pool: ActorFilterCriteria {
        guard let data = poolStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ActorFilterCriteria.self, from: data)
        else { return ActorFilterCriteria() }
        return decoded
    }

    private func setPool(_ criteria: ActorFilterCriteria) {
        poolStr = (try? JSONEncoder().encode(criteria))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        load()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Get More Photos")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { task?.cancel(); dismiss() }
                    }
                }
                .task(id: threshold) { load() }
                .sheet(isPresented: $isShowingPool) {
                    // ⚠️ Applied on dismissal, like the game's pool picker —
                    // re-filtering on every keystroke would reshuffle the list
                    // under the operator while they are still deciding.
                    PhotoPoolPicker(initial: pool, vocabulary: vocabulary,
                                    onApply: setPool)
                }
        }
        .macSheet(minWidth: 520, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Stepper("Fewer than \(threshold) photo\(threshold == 1 ? "" : "s")",
                        value: $threshold, in: 1...10)
                    .disabled(isRunning)
                // ⚠️ Says how many can actually be fetched, not just how many
                // are thin. The difference is the whole reason unmatched
                // performers are listed rather than hidden.
                Text("\(candidates.count) performer\(candidates.count == 1 ? "" : "s") below that, "
                     + "\(fetchable.count) matched to a source and fetchable.")
                    .font(.caption).foregroundStyle(.secondary)
                if exhaustedCount > 0 || showsExhausted {
                    // ⭐ Said out loud rather than silently filtered. These are
                    // not a problem — the source simply has no more pictures of
                    // them — but a count that dropped with no explanation is
                    // indistinguishable from a bug.
                    Toggle(isOn: $showsExhausted) {
                        Text(showsExhausted
                             ? "Showing performers the source had nothing more for"
                             : "\(exhaustedCount) hidden — the source had nothing more for them")
                            .font(.caption)
                    }
                    .disabled(isRunning)
                    .onChange(of: showsExhausted) { _, _ in load() }
                }
            } footer: {
                Text("Adds to each performer's gallery. Your chosen profile picture is never changed.")
            }

            Section {
                Button {
                    isShowingPool = true
                } label: {
                    HStack {
                        Label("Who to include", systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        // ⚠️ Always says what the filter IS, never just that one
                        // exists. A persisted filter the operator has forgotten
                        // is how this tool would appear to have finished the
                        // library while skipping most of it.
                        // ⭐ Says it in performers, not in clauses. "Gender is
                        // female, 2+ videos" is the filter restated; "412 of
                        // 1,250" is what it actually does.
                        Text(pool.isEmpty
                             ? "Everyone"
                             : "\(pooledCount) of \(totalActors)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .disabled(isRunning)

                if !pool.isEmpty {
                    Button("Include everyone again") { setPool(ActorFilterCriteria()) }
                        .font(.caption)
                        .disabled(isRunning)
                }
            } footer: {
                Text(pool.isEmpty
                     ? "Every performer with a thin gallery is listed. Narrow this to avoid spending requests on people you're not interested in."
                     : "Only performers matching this filter are listed, so nobody outside it costs a request.")
            }

            if let message {
                Section { Text(message).font(.callout) }
            }

            if isRunning {
                Section {
                    HStack {
                        ProgressView()
                        Text("\(progress) of \(selected.count) · \(toppedUp) topped up")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .destructive) { task?.cancel(); isRunning = false }
                }
            } else if !selected.isEmpty {
                Section {
                    Button("Get photos for \(selected.count) performer\(selected.count == 1 ? "" : "s")") {
                        run()
                    }
                    .disabled(provider == nil)
                    if provider == nil {
                        Text("No metadata source is installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(candidates) { candidate in
                    row(candidate)
                }
            } header: {
                HStack {
                    Text("Thinnest first")
                    Spacer()
                    Button(selected.isEmpty ? "Select all fetchable" : "Clear") {
                        selected = selected.isEmpty ? Set(fetchable.map(\.id)) : []
                    }
                    .font(.caption)
                    .disabled(isRunning || fetchable.isEmpty)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func row(_ candidate: ActorPhotoTopUp.Candidate) -> some View {
        Button {
            guard candidate.canFetch, !isRunning else { return }
            if selected.contains(candidate.id) { selected.remove(candidate.id) }
            else { selected.insert(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(candidate.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(candidate.canFetch ? Color.accentColor : Color.secondary.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.profile.name).lineLimit(1)
                    if !candidate.canFetch {
                        // ⚠️ Says WHY rather than just being disabled.
                        Text("Not matched to a source yet — match them first.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(candidate.photoCount == 1 ? "1 photo" : "\(candidate.photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!candidate.canFetch || isRunning)
    }

    // MARK: - Work

    private func load() {
        guard let store = try? LibraryStore(at: libraryURL),
              let profiles = try? store.fetchAllEntityProfiles() else { return }
        let actors = profiles.filter { $0.type == "actor" }
        vocabulary = ActorFilterVocabulary(actors)

        let eligible = pooled(actors)
        totalActors = actors.count
        pooledCount = eligible.count
        candidates = ActorPhotoTopUp.worklist(eligible, threshold: threshold,
                                              includingExhausted: showsExhausted)
        exhaustedCount = ActorPhotoTopUp.worklist(eligible, threshold: threshold,
                                                  includingExhausted: true).count
            - ActorPhotoTopUp.worklist(eligible, threshold: threshold).count
        selected = selected.filter { id in candidates.contains { $0.id == id } }
    }

    /// ⭐ The SAME matcher the actor grid uses, given a real context. A filter
    /// means the same thing here as it does when browsing — which is the only
    /// reason it is safe to persist one and forget about it.
    private func pooled(_ actors: [EntityProfile]) -> [EntityProfile] {
        let pool = self.pool
        guard !pool.isEmpty else { return actors }
        let index = EntityProfileIndex(actors)
        let counts = ActorVideoCounts.build(assets: assets, profiles: index)
        return actors.filter { profile in
            let safeId = ProfileImageNaming.safeId(for: profile.id)
            let hasLocalPhoto = profileImageFileNames.contains("\(safeId).jpg")
                || profileImageFileNames.contains { $0.hasPrefix("\(safeId)_") }
            return pool.matches(actor: profile.name,
                                context: .init(profile: profile,
                                               videoCount: counts[profile.name] ?? 0,
                                               hasLocalPhoto: hasLocalPhoto))
        }
    }

    private func run() {
        guard let provider else { return }
        let targets = candidates.filter { selected.contains($0.id) && $0.canFetch }
        isRunning = true
        progress = 0; toppedUp = 0; nothingNew = 0; failed = 0
        message = nil

        task = Task {
            for candidate in targets {
                if Task.isCancelled { break }
                await topUp(candidate, provider: provider)
                await MainActor.run { progress += 1 }
            }
            await MainActor.run {
                isRunning = false
                // ⭐ Reports all three outcomes. "42 done" hides that thirty of
                // them already had everything the source offers, which is the
                // number that says whether to bother running it again.
                message = "\(toppedUp) topped up · \(nothingNew) already complete"
                    + (failed > 0 ? " · \(failed) failed" : "")
                selected = []
                load()
            }
        }
    }

    private func topUp(_ candidate: ActorPhotoTopUp.Candidate,
                       provider: any ActorMetadataProvider) async {
        guard let sourceId = candidate.profile.enrichmentSourceId else { return }
        do {
            let proposal = try await provider.fetch(actorId: sourceId)
            let fetched = proposal.galleryURLs.value ?? []

            // 🚨 Re-read before writing. A long run against a library the
            // operator is also editing must not save a profile captured
            // minutes ago and discard what they did in between.
            let store = try LibrarySession.shared.store(forProfile: candidate.profile.id)
            let current = try store.fetchEntityProfile(for: candidate.profile.id)
                ?? candidate.profile

            // What the source said about this performer still existing (#48).
            //
            // ⚠️ Recorded HERE, before the "nothing new" guard below returns.
            // A top-up run that finds no extra photos still learned whether the
            // record is alive, and that is the answer the audit needs — losing
            // it on the commonest path would make the flag depend on whether
            // the gallery happened to grow.
            try? store.recordSourceState(proposal.recordState, nodeId: candidate.profile.id,
                                         source: provider.displayName, sourceId: sourceId,
                                         isVideo: false)

            guard let updated = ActorPhotoTopUp.applying(fetched, to: current) else {
                // 🚨 Recorded, so the list can be worked to the end. The source
                // has nothing we do not hold — and for a performer it only has
                // one picture of, that stays true no matter how many times we
                // ask. Without this they sat on the list permanently and cost a
                // request on every run.
                try? store.saveEntityProfile(ActorPhotoTopUp.markingExhausted(current))
                await MainActor.run { nothingNew += 1 }
                return
            }
            try store.saveEntityProfile(updated)
            await MainActor.run { toppedUp += 1 }
        } catch {
            await MainActor.run { failed += 1 }
        }
    }
}

/// The four value lists the filter builder offers, derived from the profiles in
/// hand.
///
/// ⭐ Derived here rather than threaded in from the grid. This screen is opened
/// from Settings, which does not hold them — and passing four more arguments
/// through `ContentView` to reach one sheet is how a filter that exists in two
/// places starts offering different values in each.
///
/// ⚠️ Same derivation as the actor grid's, comma-splitting included: a
/// performer recorded as "Blonde, Brunette" must offer both, or the filter
/// silently cannot express what the data says.
struct ActorFilterVocabulary {
    var genders: [String] = []
    var hairColors: [String] = []
    var countries: [String] = []
    var tags: [String] = []

    init() {}

    init(_ actors: [EntityProfile]) {
        func split(_ values: [String]) -> [String] {
            Array(Set(values
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })).sorted()
        }
        genders = split(actors.compactMap(\.gender))
        hairColors = split(actors.compactMap(\.hairColor))
        countries = split(actors.compactMap(\.countryOfOrigin))
        tags = Array(Set(actors.flatMap(\.tags)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })).sorted()
    }
}

/// The same builder the grid and the game present, applied on dismissal.
private struct PhotoPoolPicker: View {
    let initial: ActorFilterCriteria
    let vocabulary: ActorFilterVocabulary
    let onApply: (ActorFilterCriteria) -> Void

    @State private var criteria: ActorFilterCriteria

    init(initial: ActorFilterCriteria, vocabulary: ActorFilterVocabulary,
         onApply: @escaping (ActorFilterCriteria) -> Void) {
        self.initial = initial
        self.vocabulary = vocabulary
        self.onApply = onApply
        _criteria = State(initialValue: initial)
    }

    var body: some View {
        ActorFilterBuilderView(allUniqueGenders: vocabulary.genders,
                               allUniqueHairColors: vocabulary.hairColors,
                               allUniqueCountries: vocabulary.countries,
                               allUniqueTags: vocabulary.tags,
                               criteria: $criteria)
            .onDisappear { onApply(criteria) }
    }
}

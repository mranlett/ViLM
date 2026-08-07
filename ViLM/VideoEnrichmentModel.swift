// VideoEnrichmentModel.swift
// Matching ONE video against a metadata source and reviewing what comes back.
//
// The order of operations is the point. Fingerprinting is tried first because
// it identifies a file by what it looks like rather than what it is called —
// measured against a live source it resolved about 70% of a real library
// outright, with no judgement required from anyone. Everything after it exists
// for the remainder, and every step of it costs the operator attention, so
// each is only reached when the cheaper one found nothing.
//
//   fingerprint   exact; a single hit needs no disambiguation at all
//   cast          two names together; one name is not a search
//   title text    only where the filename carries something to search on
//
// Combine is imported explicitly: ObservableObject and @Published come from it,
// and inference through SwiftUI is not reliable enough to depend on.

import Foundation
import Combine
import AVFoundation
import LibraryCore

@MainActor
final class VideoEnrichmentModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Reading the video off disk. Called out separately from searching
        /// because it is the slow part and says nothing about the network.
        case fingerprinting
        case searching
        case choosing([PluginCandidate])
        case fetching
        case reviewing
        case noMatches
        /// Already resolved on a previous visit. Shown rather than silently
        /// re-searched, so the recorded state is visible instead of having to
        /// be inferred from whether the same candidates come back.
        case alreadyResolved(EnrichmentState, source: String?, at: Date?)
        /// The operator is driving the search themselves.
        case browsing
        /// Matched, but the library already holds everything it offered.
        case nothingToApply
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var changes: [VideoFieldChange] = []
    @Published private(set) var tagOptions: [VideoTagOption] = []
    /// Scalar field ids the operator has ticked.
    @Published var accepted: Set<String> = []
    /// Tag names the operator has ticked, by name rather than index so the list
    /// can reorder without changing what is selected.
    @Published var acceptedTags: Set<String> = []
    /// How the match was found, shown so the operator can weigh it: an exact
    /// fingerprint deserves more trust than a name search.
    @Published private(set) var matchRoute: String?
    /// ⭐ The route as a STORED fact rather than a sentence. `matchRoute` is
    /// localised prose for the screen; this is what goes on the match edge, and
    /// it is the thing the app used to compute, render with a green seal, and
    /// then discard on dismissal.
    private var matchMethod: MatchMethod?
    /// The candidate that was chosen, kept so the review screen can show its
    /// picture. Metadata alone frequently is not enough to be sure, and the
    /// image is what actually settles it.
    @Published private(set) var chosenCandidate: PluginCandidate?

    // MARK: Operator-driven search
    //
    // Seeded from what the library already records, because that is the
    // starting point a person would type anyway — then left entirely editable.
    @Published var searchPerformers: [String] = []
    @Published var searchStudio: String = ""
    /// Narrows to scenes carrying ALL of these — how a person cuts a long list
    /// down once cast and studio have taken it as far as they can.
    @Published var searchTags: [String] = []
    @Published var searchTitle: String = ""
    /// Completions for the filter being typed, keyed by which one.
    @Published private(set) var suggestions: [BrowseFilterKind: [String]] = [:]

    /// Filters the source could not interpret and therefore ignored. Shown,
    /// because a dropped filter returns everything and looks like a filter that
    /// simply does not work.
    @Published private(set) var unresolvedFilters: [String] = []
    @Published private(set) var browseResults: [PluginCandidate] = []
    @Published private(set) var browseTotal: Int = 0
    @Published private(set) var browsePage: Int = 1

    /// How many results a full page holds.
    ///
    /// The provider does not declare it, so it is inferred as the largest page
    /// seen — a final short page must not shrink it. Needed because "showing 25
    /// of 235" is the same sentence on page 1 and page 5, which tells the
    /// operator nothing about where they are.
    @Published private(set) var browsePageSize: Int = 0

    /// The 1-based range of results currently on screen, or nil before a
    /// search has returned anything.
    var browseRange: ClosedRange<Int>? {
        guard !browseResults.isEmpty else { return nil }
        let size = max(browsePageSize, browseResults.count)
        let first = (browsePage - 1) * size + 1
        return first...(first + browseResults.count - 1)
    }

    /// Whether another page exists.
    ///
    /// Derived from the range's end rather than from `page × results.count`,
    /// which under-counts on a short page and can leave "Next" enabled at the
    /// end of a list or disabled before it.
    var hasNextBrowsePage: Bool {
        guard let range = browseRange else { return false }
        return range.upperBound < browseTotal
    }
    @Published private(set) var isBrowsing = false
    @Published private(set) var browseError: String?
    /// The file's own running time, so a row can say how far off it is. The
    /// strongest thing a person has to judge by when the names all look alike.
    @Published private(set) var localDuration: Int?

    private let asset: Asset
    private let libraryURL: URL
    private let knownTags: Set<String>
    /// 🚨 Folded identities the vocabulary says describe a PERFORMER. Without
    /// these the review pre-ticked "Redhead" onto the video itself, because
    /// being classified is exactly what made it look familiar.
    private lazy var performerTraits: Set<String> = {
        guard let records = try? LibraryStore(at: libraryURL).fetchTagVocabulary() else { return [] }
        return Set(records
            .filter { $0.resolvedKind()?.canAttach(to: .video) == false }
            .map(\.identityKey))
    }()
    private var proposal: VideoMetadataProposal?
    /// The imprint and the network, when verification could not choose between
    /// them. Non-nil means the review is waiting on a person.
    @Published private(set) var studioChoice: (imprint: StudioResolution.Candidate,
                                               parent: StudioResolution.Candidate)?
    /// Kept so the parent edge can be recorded whichever name was chosen.
    private var studioParentPair: (child: String, parent: String)?
    /// Kept so the picker can be returned to after opening a candidate.
    private var lastCandidates: [PluginCandidate] = []
    /// One in-flight completion per filter, so a new keystroke replaces the
    /// previous request rather than racing it.
    private var suggestionTasks: [BrowseFilterKind: Task<Void, Never>] = [:]

    init(asset: Asset, libraryURL: URL, knownTags: Set<String>) {
        self.asset = asset
        self.libraryURL = libraryURL
        self.knownTags = knownTags
    }

    private var provider: (any VideoMetadataProvider)? {
        PluginEnvironment.registry.installedVideoProviders().first
    }

    var hasAnythingToApply: Bool { !accepted.isEmpty || !acceptedTags.isEmpty }

    /// Whether there was ever more than one candidate to go back to. A picker
    /// of one was skipped, so offering to return to it would show a list with
    /// a single row and no alternative.
    var canReturnToPicker: Bool { lastCandidates.count > 1 }

    // MARK: - Finding it

    func start(force: Bool = false) async {
        guard let provider else {
            phase = .failed("No video metadata source is installed.")
            return
        }

        // A settled record is reported, not re-searched. Searching again is
        // still one tap away — but doing it automatically hid whether the last
        // match had been recorded at all, because the same candidates came
        // back either way.
        if !force, let state = asset.enrichmentState,
           state == .matched || state == .unmatchable {
            phase = .alreadyResolved(state, source: asset.enrichmentSource,
                                     at: asset.enrichmentCheckedAt)
            return
        }

        // 1 — fingerprint.
        phase = .fingerprinting
        let fileURL = libraryURL.appendingPathComponent(asset.relativePath)
        localDuration = await Self.duration(of: fileURL)
        var fingerprintFailure: String?
        do {
            let hash = try await VideoPerceptualHash.compute(contentsOf: fileURL)
            let hits = try await provider.match(perceptualHash: hash, distance: 0)
            if !hits.isEmpty {
                matchRoute = "Matched by visual fingerprint"
                matchMethod = .fingerprint
                await present(hits)
                return
            }
        } catch {
            // A file that cannot be read is worth saying so about, but it must
            // not stop the name-based attempts — a video with a broken first
            // frame can still be found by its cast.
            fingerprintFailure = friendly(error)
        }

        // 2 — the people in it. Two names or none; one name returns hundreds.
        phase = .searching
        // Carries what previous actor matching established — the recorded
        // source id where there is one, the birth date otherwise. Two people
        // really are called "Robin Vale", and searching by name alone picks one
        // at random and then reports "no match" when it guessed wrong.
        let performers = PerformerIdentity.from(names: asset.actors, profiles: actorProfiles())
        if performers.count >= 2 {
            if let hits = try? await provider.search(performers: performers,
                                                     studio: asset.studios.first),
               !hits.isEmpty {
                matchRoute = "Matched on cast — check this is the right scene"
                matchMethod = .cast
                await present(hits)
                return
            }
        }

        // 3 — whatever the record calls it.
        let title = [asset.videoName, asset.episode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if title.count >= 3 {
            if let hits = try? await provider.search(title: title, year: nil), !hits.isEmpty {
                matchRoute = "Matched on title — check this is the right scene"
                matchMethod = .title
                await present(hits)
                return
            }
        }

        phase = fingerprintFailure.map { .failed($0) } ?? .noMatches
    }

    private static func duration(of url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await CMTimeGetSeconds(asset.load(.duration)),
              seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds.rounded())
    }

    // MARK: - Searching by hand

    /// Opens the manual search, seeded from what the library holds.
    ///
    /// Automatic matching refuses a single performer because one name returns
    /// hundreds of candidates. That reasoning does not apply here: a person
    /// narrowing by eye, with a studio and a running time in front of them,
    /// gets to a usable shortlist from exactly that. Measured on a real case,
    /// one performer plus a studio took 233 scenes down to 4.
    func beginBrowsing() {
        searchPerformers = asset.actors
        searchStudio = asset.studios.first ?? ""
        // Deliberately NOT seeded from the video's tags: they narrow hard, and
        // starting with several applied would show an empty list on a search
        // the operator never asked for.
        searchTags = []
        searchTitle = ""
        unresolvedFilters = []
        browseResults = []
        browseTotal = 0
        browsePage = 1
        browsePageSize = 0
        browseError = nil
        phase = .browsing
    }

    func addSearchPerformer(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !searchPerformers.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        searchPerformers.append(trimmed)
    }

    func removeSearchPerformer(_ name: String) {
        searchPerformers.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Fetches completions for what is being typed, after a short pause.
    ///
    /// Debounced rather than fired per keystroke: the source asks for about a
    /// request a second, and a five-letter word typed quickly would spend the
    /// whole budget on answers nobody reads. The previous request is cancelled,
    /// so only the current text is ever asked about.
    func updateSuggestions(for kind: BrowseFilterKind, text: String) {
        suggestionTasks[kind]?.cancel()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            suggestions[kind] = []
            return
        }
        suggestionTasks[kind] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, let provider = self.provider else { return }
            let names = (try? await provider.suggestions(for: kind, matching: term)) ?? []
            guard !Task.isCancelled else { return }
            self.suggestions[kind] = names
        }
    }

    func clearSuggestions(for kind: BrowseFilterKind) {
        suggestionTasks[kind]?.cancel()
        suggestions[kind] = []
    }

    func addSearchTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !searchTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        searchTags.append(trimmed)
    }

    func removeSearchTag(_ name: String) {
        searchTags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Any filter at all is enough to search.
    ///
    /// The automatic path refuses a lone performer because a hundred
    /// candidates is useless to a machine. That reasoning does not transfer:
    /// a studio on its own is a perfectly good starting point when the cast is
    /// unknown — which is precisely when the automatic passes failed — and
    /// adding one tag to it cuts hundreds of scenes down to a handful.
    ///
    /// Zero filters is still refused: that is not a search, it is the whole
    /// database.
    var canBrowse: Bool {
        !searchPerformers.isEmpty
            || !searchTags.isEmpty
            || !searchStudio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// This video's own tags, offered as one-tap additions to the search.
    var suggestedSearchTags: [String] {
        asset.actions.filter { tag in
            !searchTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    func runBrowse(page: Int = 1) async {
        guard let provider else { return }
        isBrowsing = true
        browseError = nil
        do {
            let result = try await provider.browse(
                BrowseQuery(performerNames: searchPerformers,
                            studio: searchStudio.trimmingCharacters(in: .whitespacesAndNewlines),
                            tags: searchTags,
                            title: searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)),
                page: page)
            // Where the same scene is listed twice — once by whoever made it,
            // once by whoever licensed it later — the original comes first.
            // Only duplicates move; the source's ranking is otherwise kept.
            browseResults = CandidatePreference.preferOriginalProduction(result.candidates)
            browseTotal = result.total
            unresolvedFilters = result.unresolvedFilters
            browsePage = page
            // Largest page wins: a short final page is not the page size.
            browsePageSize = max(browsePageSize, result.candidates.count)
        } catch {
            // Surfaced rather than swallowed: an unresolvable performer name is
            // the most likely failure and the operator can fix it immediately.
            browseError = friendly(error)
            browseResults = []
            browseTotal = 0
            unresolvedFilters = []
        }
        isBrowsing = false
    }

    /// The asset being matched, so the search screen can show its own frames.
    var subject: Asset { asset }
    var subjectLibraryURL: URL { libraryURL }

    /// How far a candidate's running time is from the file, or nil when either
    /// is unknown.
    func durationDelta(for candidate: PluginCandidate) -> Int? {
        guard let local = localDuration, let theirs = candidate.durationSeconds else { return nil }
        return theirs - local
    }

    private func present(_ candidates: [PluginCandidate]) async {
        lastCandidates = candidates
        // A single hit needs no picker. This is the common case on the
        // fingerprint route, and making someone confirm a list of one is
        // ceremony rather than safety.
        if candidates.count == 1 {
            await choose(candidates[0])
        } else {
            phase = .choosing(candidates)
        }
    }

    /// Builds the review from a proposal whose studio is already decided.
    private func present(_ resolved: VideoMetadataProposal) {
        proposal = resolved
        changes = VideoEnrichmentReview.changes(for: asset, proposal: resolved,
                                                knownTags: knownTags)
        tagOptions = VideoEnrichmentReview.tagOptions(for: asset, proposal: resolved,
                                                      knownTags: knownTags,
                                                      performerTraits: performerTraits)
        // Fills are pre-ticked; a conflict never is. Tags follow their own
        // rule — only ones already in the vocabulary.
        accepted = Set(changes.filter { $0.kind == .fill }.map(\.field))
        acceptedTags = VideoEnrichmentReview.defaultSelection(tagOptions)

        phase = (changes.isEmpty && tagOptions.isEmpty) ? .nothingToApply : .reviewing
    }

    /// Settles an open imprint-versus-network choice and rebuilds the review
    /// around it.
    func chooseStudio(_ candidate: StudioResolution.Candidate) {
        guard let proposal else { return }
        studioChoice = nil
        present(VideoEnrichmentReview.resolvingStudio(proposal, to: candidate))
        // A studio the operator picked deliberately is one they have vouched
        // for, so the next video offering the same pair is decided without
        // asking again — which is how the disambiguation stops repeating.
        accepted.insert(VideoEnrichmentReview.Field.studio)
    }

    /// Whether a studio NAME has already been confirmed by a person or a source.
    private func isStudioVerified(_ name: String) -> Bool {
        guard let store = try? LibraryStore(at: libraryURL) else { return false }
        let profile = try? store.fetchEntityProfile(for: "studio:\(name)")
        return profile?.enrichmentState == .matched
    }

    func returnToPicker() {
        guard lastCandidates.count > 1 else { return }
        phase = .choosing(lastCandidates)
    }

    // MARK: - Reviewing

    func choose(_ candidate: PluginCandidate) async {
        guard let provider else { return }
        phase = .fetching
        chosenCandidate = candidate
        do {
            let fetched = try await provider.fetch(videoId: candidate.id)

            // The source names an imprint and the network above it. Which one
            // this video carries is settled BEFORE the review is built, so
            // every row, the merge and the confirmation all read one answer.
            let outcome = VideoEnrichmentReview.studioResolution(
                proposal: fetched, isVerified: isStudioVerified)
            // Held either way: the hierarchy is a fact about the studios, not
            // about which name won, so it is recorded even when the imprint is
            // chosen and the network never appears on the video.
            if let child = fetched.studio.value, let parent = fetched.studioParent.value,
               !StudioResolution.isSameStudio(child, parent) {
                studioParentPair = (child, parent)
            }

            switch outcome {
            case let .use(choice):
                studioChoice = nil
                present(VideoEnrichmentReview.resolvingStudio(fetched, to: choice))
            case let .ask(imprint, parent):
                // ⚠️ No default. Pre-selecting one would let a return-key
                // reflex commit the library to a studio nobody compared.
                studioChoice = (imprint, parent)
                present(fetched)
                // ⚠️ The studio row is withdrawn while the question is open.
                // Leaving it would show the imprint as the proposed value
                // directly beneath a section asking which studio to use — the
                // screen answering its own question, with the answer being
                // whichever name the source happened to put first.
                changes.removeAll { $0.field == VideoEnrichmentReview.Field.studio }
                accepted.remove(VideoEnrichmentReview.Field.studio)
            case .none:
                studioChoice = nil
                present(fetched)
            }
        } catch {
            phase = .failed(friendly(error))
        }
    }

    func toggle(_ field: String) {
        if accepted.contains(field) { accepted.remove(field) } else { accepted.insert(field) }
    }

    func toggleTag(_ name: String) {
        if acceptedTags.contains(name) { acceptedTags.remove(name) } else { acceptedTags.insert(name) }
    }

    func selectAllTags() { acceptedTags = Set(tagOptions.map(\.name)) }
    func selectNoTags() { acceptedTags = [] }

    /// Records that a lookup happened, whatever the operator then accepts.
    ///
    /// Called on dismissal as well as on apply: a video that was searched and
    /// found nothing has been checked, and leaving it blank would offer it
    /// again forever. `.unmatchable` is never set here — that stays a human
    /// judgement, the same rule the actor side follows.
    /// The id travels with the outcome so that dismissing the sheet after
    /// choosing a candidate still records WHICH record matched. Without it the
    /// state says "matched" and nothing says what to — which is the same
    /// re-guessing on the next run that v24 exists to end.
    /// What DISMISSING the sheet should record — never what applying it should.
    ///
    /// ⚠️ `.reviewing` and `.nothingToApply` deliberately record NOTHING.
    /// Reaching them means a candidate is on screen being looked at, not that
    /// it was accepted; confirming is the primary action ("Apply" / "Confirm
    /// Match"), which goes through `apply()`. Recording `.matched` here meant
    /// that opening a video, failing to find the right record and giving up
    /// marked it as matched — and because `.matched` is a settled state, the
    /// video was then skipped by every future run.
    ///
    /// That behaviour predates the persistence fix and was invisible while
    /// `enrichmentState` was being discarded at save. Making the state durable
    /// is what turned it into a real defect.
    ///
    /// The other two are genuine conclusions and are still recorded: a search
    /// that returned nothing, and several candidates none of which was chosen.
    /// Both leave the video needing attention, so neither strands it.
    func outcomeToRecord() -> (state: EnrichmentState, source: String?, sourceId: String?)? {
        switch phase {
        case .noMatches: return (.noMatch, providerName, nil)
        case .choosing: return (.ambiguous, providerName, nil)
        default: return nil
        }
    }

    private var providerName: String? { provider?.displayName }

    /// Profiles for this video's cast, from whichever library owns each.
    private func actorProfiles() -> [String: EntityProfile] {
        var out: [String: EntityProfile] = [:]
        for name in asset.actors {
            let entityId = "actor:\(name)"
            if let profile = try? LibrarySession.shared.store(forProfile: entityId)
                .fetchEntityProfile(for: entityId) {
                out[entityId] = profile
            }
        }
        return out
    }

    /// The asset as it would be saved, or nil when nothing was accepted.
    ///
    /// Returns a value rather than persisting: the caller owns the write, the
    /// same way the actor editor does.
    func apply() -> Asset? {
        // A candidate confirmed by hand is a match whether or not anything was
        // left to write. Returning nil here recorded no state, so the video
        // came back in "needs your attention" on the next run — having already
        // been dealt with.
        guard let proposal else { return nil }
        // The chosen candidate's id IS the match. Keeping it turns every later
        // lookup from a re-search by name into a fetch — see schema v24.
        guard hasAnythingToApply else {
            return VideoEnrichmentReview.recordingOutcome(asset, state: .matched,
                                                          source: providerName,
                                                          sourceId: chosenCandidate?.id)
        }
        // `offeredTags` scopes removal to what was actually shown, so an
        // unticked tag is removed and an untouched one is never affected.
        // A studio the source supplied is a studio the source knows exists, so
        // accepting it verifies the studio itself — not just this video's tag.
        // Nothing else confirms a studio, so without this one write a studio
        // stays "unconfirmed" forever however many videos credit it.
        if let studio = VideoEnrichmentReview.confirmedStudio(proposal: proposal,
                                                              accepting: accepted,
                                                              asset: asset),
           let url = LibrarySession.shared.url(for: asset.id) {
            let store = try? LibraryStore(at: url)
            try? store?.confirmStudio(
                studio, source: providerName,
                sourceId: StudioResolution.isSameStudio(studio, proposal.studio.value ?? "")
                    ? proposal.studioSourceId.value
                    : (StudioResolution.isSameStudio(studio, proposal.studioParent.value ?? "")
                        ? proposal.studioParentSourceId.value : nil))

            // ⚠️ The hierarchy is recorded whichever name landed on the video.
            // It is a fact about the two studios, not about this video's
            // choice — and it is the only thing that lets browsing a network
            // find scenes filed under its imprints.
            if let pair = studioParentPair {
                try? store?.confirmStudio(pair.parent, source: providerName,
                                          sourceId: proposal.studioParentSourceId.value)
                // Cycles are refused by the store; a source that disagrees with
                // itself about which way a hierarchy runs must not be able to
                // wedge the graph.
                try? store?.setStudioParent("studio:\(pair.parent)",
                                            forStudio: "studio:\(pair.child)")
            }
        }

        let merged = VideoEnrichmentReview.merged(asset: asset, proposal: proposal,
                                                  accepting: accepted, acceptedTags: acceptedTags,
                                                  offeredTags: tagOptions.map(\.name))

        // ⚠️ The credits go in here rather than beside the returned asset,
        // because they are edge data: the caller persists the ASSET, and
        // nothing it does would carry a `credited_as` with it.
        let credits = VideoEnrichmentReview.credits(from: proposal, accepting: accepted)
        if !credits.isEmpty, let url = LibrarySession.shared.url(for: asset.id) {
            try? LibraryStore(at: url).recordCredits(credits, forVideo: asset.id)
        }

        // The match edge (v31), beside the columns `recordingOutcome` sets.
        //
        // ⭐ `.operator` when a person chose from a list, whatever route found
        // the candidates. Someone looked at the picture and decided, and that
        // is different evidence from the search that produced the shortlist —
        // recording the route here would understate it.
        if let sourceId = chosenCandidate?.id, let source = providerName,
           let url = LibrarySession.shared.url(for: asset.id) {
            let method: MatchMethod = canReturnToPicker ? .operator : (matchMethod ?? .operator)
            let store = try? LibraryStore(at: url)
            try? store?.confirmVideoMatch(
                asset.id, source: source, sourceId: sourceId, method: method)

            // ⭐ The cast comes identified. The source's scene record links to
            // confirmed performer records, so a strong video match identifies
            // every performer in it — rather than leaving each to be re-matched
            // by name, repeating a disambiguation already done.
            if let all = proposal.actors.value {
                try? store?.propagateIdentities(all, source: source, videoMethod: method)
            }
        }

        return VideoEnrichmentReview.recordingOutcome(merged, state: .matched,
                                                      source: providerName,
                                                      sourceId: chosenCandidate?.id)
    }

    private func friendly(_ error: Error) -> String {
        if let pluginError = error as? PluginError { return pluginError.localizedDescription }
        if let hashError = error as? VideoPerceptualHash.HashError {
            switch hashError {
            case .unreadable: return "This video could not be read."
            case .tooShort: return "This video is too short to fingerprint."
            case .incompleteFrames(let got, let want):
                return "Only \(got) of \(want) frames could be read from this video."
            }
        }
        return error.localizedDescription
    }
}

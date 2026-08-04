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
    @Published private(set) var isBrowsing = false
    @Published private(set) var browseError: String?
    /// The file's own running time, so a row can say how far off it is. The
    /// strongest thing a person has to judge by when the names all look alike.
    @Published private(set) var localDuration: Int?

    private let asset: Asset
    private let libraryURL: URL
    private let knownTags: Set<String>
    private var proposal: VideoMetadataProposal?
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

    func start() async {
        guard let provider else {
            phase = .failed("No video metadata source is installed.")
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
        let performers = asset.actors
        if performers.count >= 2 {
            if let hits = try? await provider.search(performerNames: performers,
                                                     studio: asset.studios.first),
               !hits.isEmpty {
                matchRoute = "Matched on cast — check this is the right scene"
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
            browseResults = result.candidates
            browseTotal = result.total
            unresolvedFilters = result.unresolvedFilters
            browsePage = page
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

    func returnToPicker() {
        guard lastCandidates.count > 1 else { return }
        phase = .choosing(lastCandidates)
    }

    // MARK: - Reviewing

    func choose(_ candidate: PluginCandidate) async {
        guard let provider else { return }
        phase = .fetching
        do {
            let fetched = try await provider.fetch(videoId: candidate.id)
            proposal = fetched

            changes = VideoEnrichmentReview.changes(for: asset, proposal: fetched,
                                                    knownTags: knownTags)
            tagOptions = VideoEnrichmentReview.tagOptions(for: asset, proposal: fetched,
                                                          knownTags: knownTags)
            // Fills are pre-ticked; a conflict never is. Tags follow their own
            // rule — only ones already in the vocabulary.
            accepted = Set(changes.filter { $0.kind == .fill }.map(\.field))
            acceptedTags = VideoEnrichmentReview.defaultSelection(tagOptions)

            phase = (changes.isEmpty && tagOptions.isEmpty) ? .nothingToApply : .reviewing
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
    func outcomeToRecord() -> (EnrichmentState, String?)? {
        switch phase {
        case .reviewing, .nothingToApply: return (.matched, providerName)
        case .noMatches: return (.noMatch, providerName)
        case .choosing: return (.ambiguous, providerName)
        default: return nil
        }
    }

    private var providerName: String? { provider?.displayName }

    /// The asset as it would be saved, or nil when nothing was accepted.
    ///
    /// Returns a value rather than persisting: the caller owns the write, the
    /// same way the actor editor does.
    func apply() -> Asset? {
        guard let proposal, hasAnythingToApply else { return nil }
        let merged = VideoEnrichmentReview.merged(asset: asset, proposal: proposal,
                                                  accepting: accepted, acceptedTags: acceptedTags)
        return VideoEnrichmentReview.recordingOutcome(merged, state: .matched,
                                                      source: providerName)
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

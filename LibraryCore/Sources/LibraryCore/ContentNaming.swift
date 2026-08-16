// ContentNaming.swift
// Where a video belongs on disk, and what it is called there (#17).
//
// ⭐ PURE. It takes what the caller has already resolved — the studio's
// disposition, the cast, the content kind — and returns a path or a reason it
// cannot produce one. Nothing here reads the database or touches the
// filesystem, which is what makes the grammar testable against every shape the
// library actually contains rather than against whatever a fixture happens to
// hold.
//
// 🚨 Open standards where they exist, a ViLM grammar only where none does. The
// on-disk layout is a MACHINE-FACING CONTRACT, not a browsing surface —
// discovery and filtering are the app's job.
//
//   Film      Film Title (2019)/Film Title (2019).mkv          Kodi / Plex
//   Episodic  Series/Season 01/Series - S01E02 - Title.mkv      Kodi / Plex
//   Personal  <personal>/Event or Description (2019).mkv        Kodi movie shape
//   Scene     Studio/Studio - Performers - YYYY-MM-DD.ext       ViLM-defined
//
// ⚠️ A scene will never match an online scraper, and does not need to: Kodi's
// local-information-only mode reads the sidecar and ignores the filename. The
// filename carries the operator's data; the sidecar carries Kodi's.

import Foundation

/// Where a video's studio puts it, already resolved against the lexicon (N1).
public enum StudioPlacement: Equatable, Sendable {
    /// Matched to an external source id — it gets its own folder.
    case filed(String)
    /// Ruled out (`unmatchable`) — the shared unfiled folder.
    case unfiled
    /// Not yet processed. The file stays where it is.
    case unprocessed
}

/// A credited performer, with the one attribute the ordering reads.
public struct PerformerRef: Equatable, Sendable {
    public let name: String
    public let gender: String?

    public init(name: String, gender: String?) {
        self.name = name
        self.gender = gender
    }

    /// ⭐ Female and non-binary first, male last. The operator's rule.
    /// Anything unrecognised sorts with female rather than being dropped — the
    /// ordering has to be total or the name is not deterministic.
    var rank: Int { (gender?.lowercased() == "male") ? 1 : 0 }
}

/// Everything the grammar needs that is not on the asset.
public struct NamingContext: Sendable {
    public let studio: StudioPlacement
    /// Every credited performer. The cap is applied here, not by the caller.
    public let performers: [PerformerRef]
    public let personalFolder: String
    public let unfiledFolder: String

    public init(studio: StudioPlacement, performers: [PerformerRef],
                personalFolder: String = "Personal", unfiledFolder: String = "Unfiled") {
        self.studio = studio
        self.performers = performers
        self.personalFolder = personalFolder
        self.unfiledFolder = unfiledFolder
    }
}

/// Why a video cannot be filed. Reported, never guessed around.
public enum NamingSkip: Equatable, Sendable {
    /// No content kind. F7 — the file stays in the root and stays usable.
    case undeclared
    /// 🚨 F7b. Declared Episodic, but the grammar treats the series name and
    /// `SxxEyy` as structural and one of them is absent.
    case episodicNeeds(String)
    /// Nothing usable to name it after — not even a filename stem.
    case noUsableName
    /// A single performer's name alone exceeds the ceiling, so truncating would
    /// produce a different person's name rather than a shorter one.
    case performerNameTooLong(String)

    public var reason: String {
        switch self {
        case .undeclared:
            return "Not declared yet — say what it is and it can be filed."
        case let .episodicNeeds(field):
            return "Filed as episodic but has no \(field), so it has no place in a season."
        case .noUsableName:
            return "Nothing to name it after — no title, no series, and no usable filename."
        case let .performerNameTooLong(name):
            return "One performer's name alone is longer than a filename may be (\(name))."
        }
    }
}

public enum NamingOutcome: Equatable, Sendable {
    /// A path relative to the library root, including the extension.
    case path(String)
    case skipped(NamingSkip)
}

public enum ContentNaming {

    /// The season an episodic video is filed under when it states none.
    ///
    /// ⚠️ A FILING convention, not a fact about the work — see `episodic(_:_:_:)`
    /// for why it is never written back to the asset. Named rather than
    /// inlined so `assumesSeason(for:)` and the tests refer to one value.
    public static let assumedSeason = 1

    /// Whether filing this asset would assume a season it has not stated.
    ///
    /// ⭐ Exposed so the dry run can count it. The plan has to be able to say
    /// "204 of these will be filed under Season 01, which they do not claim" —
    /// a silent assumption applied to two hundred files is precisely the quiet
    /// wrongness this project keeps having to repair.
    public static func assumesSeason(for asset: Asset) -> Bool {
        asset.contentKind == .episodic && asset.seasonNumber == nil
    }

    /// The performer cap in a scene filename. Three, per the operator's rule.
    ///
    /// ⚠️ A NAMING constraint only. A path has a length limit; the sidecar does
    /// not, and every performer reaches it — the cap must not leak there.
    public static let scenePerformerCap = 3

    public static func path(for asset: Asset, in context: NamingContext) -> NamingOutcome {
        guard let kind = asset.contentKind else { return .skipped(.undeclared) }
        let ext = (asset.fileName as NSString).pathExtension
        switch kind {
        case .personal: return personal(asset, context, ext)
        case .film:     return film(asset, context, ext)
        case .episodic: return episodic(asset, context, ext)
        case .scene:    return scene(asset, context, ext)
        }
    }

    // MARK: - The grammars

    /// `Film Title (2019)/Film Title (2019).mkv`
    private static func film(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        guard let title = usableTitle(asset) else { return .skipped(.noUsableName) }
        // ⚠️ The year is the trailing segment, so its absence truncates the name
        // rather than leaving a placeholder. `Title` alone is legal.
        let stem = join([title, year(asset).map { "(\($0))" }], with: " ")
        guard let component = PathComponentName.sanitised(stem) else {
            return .skipped(.noUsableName)
        }
        return .path("\(component)/\(component)\(dot(ext))")
    }

    /// `<personal>/Event or Description (2019).mkv`
    ///
    /// 🚨 Never under a studio, whatever the record says. A personal video may
    /// carry a studio — mis-tagged, inherited from a filename, or matched in
    /// error — and none of that may file it beside commercial content. Kind is
    /// evaluated before placement, which is why this branch never reads
    /// `context.studio` at all.
    private static func personal(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        guard let title = usableTitle(asset) else { return .skipped(.noUsableName) }
        let stem = join([title, year(asset).map { "(\($0))" }], with: " ")
        guard let folder = PathComponentName.sanitised(c.personalFolder),
              let component = PathComponentName.sanitised(stem) else {
            return .skipped(.noUsableName)
        }
        return .path("\(folder)/\(component)\(dot(ext))")
    }

    /// `Series Name/Season 01/Series Name - S01E02 - Episode Title.mkv`
    ///
    /// 🚨 F7b. The series name and `SxxEyy` are structural — the truncation
    /// rules list them as never dropped — so a video missing either cannot be
    /// filed here and is reported instead.
    ///
    /// ## ⭐ The season default — DECIDED 2026-08-15, reversing an earlier call
    ///
    /// F7b originally rejected a default with: *"the episode number has no such
    /// convention, and half a guess still produces a wrong path."* That
    /// reasoning **bundles two fields the data separates.** Measured on the
    /// phone library, of 288 videos declared episodic:
    ///
    /// - **204 are missing ONLY a season number** — series and episode present
    /// - 71 are missing an episode number
    /// - 19 are missing a series name
    /// - **1** could be filed at all
    ///
    /// The episode objection is sound and still stands — those 71 are reported,
    /// not guessed. It simply does not reach the 204, where the only assumed
    /// field is the one with a genuine convention. The default takes episodic
    /// filings from 1 to 205. The earlier decision was taken against an
    /// estimate of "about 100 declared episodic"; this one is taken against the
    /// count.
    ///
    /// 🚨 **The default fills the PATH, never the record.** `asset.seasonNumber`
    /// is left `nil`, because the library has not been told what season this is
    /// and writing 1 into it would turn a filing convention into a claim about
    /// the work — inference wearing a declaration's clothes, which is the exact
    /// thing `ContentKind` refuses to do. A season can be stated later and
    /// nothing has to be un-guessed.
    ///
    /// ⚠️ And it is COUNTED. `RelocationPlan` reports how many moves assumed a
    /// season, so 204 files landing in `Season 01` is something the operator
    /// reads in the dry run rather than discovers afterwards.
    private static func episodic(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        guard let series = asset.videoName?.trimmed, !series.isEmpty else {
            return .skipped(.episodicNeeds("series name"))
        }
        guard let episode = asset.episodeNumber else {
            return .skipped(.episodicNeeds("episode number"))
        }
        let season = asset.seasonNumber ?? Self.assumedSeason

        let marker = String(format: "S%02dE%02d", season, episode)
        // The episode title is the one droppable segment here.
        let stem = join([series, marker, asset.episode?.trimmed], with: " - ")

        guard let seriesFolder = PathComponentName.sanitised(series),
              let seasonFolder = PathComponentName.sanitised(String(format: "Season %02d", season)),
              var component = PathComponentName.sanitised(stem) else {
            return .skipped(.noUsableName)
        }
        // Over the ceiling: drop the episode title, never the series or marker.
        if component.utf8.count >= PathComponentName.maximumBytes,
           let bare = PathComponentName.sanitised(join([series, marker], with: " - ")) {
            component = bare
        }
        return .path("\(seriesFolder)/\(seasonFolder)/\(component)\(dot(ext))")
    }

    /// `Studio/Studio - Performers - YYYY-MM-DD.ext`
    private static func scene(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        let studioName: String? = {
            if case let .filed(name) = c.studio { return name }
            return nil
        }()

        let cast = orderedPerformers(c.performers)
        if let tooLong = cast.first(where: {
            $0.utf8.count > PathComponentName.maximumBytes
        }) {
            return .skipped(.performerNameTooLong(tooLong))
        }
        let castPart = cast.isEmpty ? nil : cast.joined(separator: ", ")
        let date = asset.releaseDate?.trimmed
        let title = recordedTitle(asset).map(foldingSeparator)

        // ⚠️ A missing field takes its separator with it. The naive join
        // produces " -  - " and a name that no longer parses back.
        var stem = join([studioName, castPart, title, date], with: " - ")
        if stem.isEmpty {
            // Nothing identifying at all — fall back to whatever the record can
            // still offer rather than producing a nameless file.
            guard let fallback = usableTitle(asset) else { return .skipped(.noUsableName) }
            stem = fallback
        }
        stem = truncateScene(stem, studio: studioName, cast: cast,
                             title: title, date: date)

        guard let component = PathComponentName.sanitised(stem) else {
            return .skipped(.noUsableName)
        }
        let folder = sceneFolder(c)
        return .path(folder.map { "\($0)/\(component)\(dot(ext))" } ?? "\(component)\(dot(ext))")
    }

    /// Which directory a scene sits in (N1).
    private static func sceneFolder(_ c: NamingContext) -> String? {
        switch c.studio {
        case let .filed(name):  return PathComponentName.sanitised(name)
        case .unfiled:          return PathComponentName.sanitised(c.unfiledFolder)
        // ⭐ Unprocessed stays in the root. A file's location states its
        // processing status, and root means "nothing has looked at this yet".
        case .unprocessed:      return nil
        }
    }

    // MARK: - The ordering and the cap

    /// ⭐ Female and non-binary first, male last; alphabetical within a rank;
    /// capped at three.
    ///
    /// Alphabetical is arbitrary and that is the point — it is the only
    /// ordering both deterministic and stable. `billing` exists on the edge
    /// table and is populated on none of 3,771 rows, so ordering by it would
    /// have sorted every scene by a column that is always null.
    static func orderedPerformers(_ performers: [PerformerRef]) -> [String] {
        performers
            .sorted {
                $0.rank != $1.rank
                    ? $0.rank < $1.rank
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .prefix(scenePerformerCap)
            .map(\.name)
    }

    /// The title a scene is named by: the episode title, else the series.
    ///
    /// 🚨 Deliberately NOT `usableTitle`, which falls back to the existing
    /// filename stem. That fallback is right when a record has nothing else to
    /// offer (decision 6), and wrong here — a scene that already has a studio,
    /// a cast and a date would otherwise have its OLD junk filename baked into
    /// its new one permanently, which is precisely what renaming exists to undo.
    static func recordedTitle(_ asset: Asset) -> String? {
        if let t = asset.episode?.trimmed, !t.isEmpty { return t }
        if let s = asset.videoName?.trimmed, !s.isEmpty { return s }
        return nil
    }

    /// ⚠️ D3's separator collapse, handled rather than accepted. The field
    /// separator is `" - "` and titles routinely contain that exact sequence —
    /// the spec named this as the reason filenames could not be a store, and
    /// putting titles into names would make the collision ordinary. Folding it
    /// to an en dash inside the segment keeps the field COUNT fixed, so a
    /// generated name still parses back into the same fields (F1).
    ///
    /// ⭐ An en dash rather than deleting it: it reads identically to a person
    /// and is legal on ExFAT and on Windows, which D14 fixed the delimiters for.
    static func foldingSeparator(_ text: String) -> String {
        text.replacingOccurrences(of: " - ", with: " – ")
    }

    /// Scene truncation, least-identifying first.
    ///
    /// 1. the **studio** — already the folder name, so the only redundant segment
    /// 2. the **title**, shortened at a word boundary rather than dropped
    /// 3. **performers** from the end, whole names only
    /// 4. the **date** is never dropped
    ///
    /// ⚠️ The title is shortened rather than removed, and that ordering is the
    /// point: it is both the longest segment and the one that disambiguates two
    /// scenes sharing a studio, a cast and a date. Dropping it whole would
    /// reintroduce the exact collision it was added to resolve.
    private static func truncateScene(_ stem: String, studio: String?,
                                      cast: [String], title: String?,
                                      date: String?) -> String {
        guard stem.utf8.count > PathComponentName.maximumBytes else { return stem }
        let castPart = { (names: [String]) -> String? in
            names.isEmpty ? nil : names.joined(separator: ", ")
        }

        // 1 · without the studio
        var candidate = join([castPart(cast), title, date], with: " - ")
        if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }

        // 2 · shorten the title at a word boundary, keeping everything else
        var words = (title ?? "").split(separator: " ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            candidate = join([castPart(cast), words.joined(separator: " "), date],
                             with: " - ")
            if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }
        }
        // What is left of the title once it cannot be shortened further: one
        // word, or nothing if there was never a title.
        let shortestTitle = words.isEmpty ? nil : words.joined(separator: " ")

        // 3 · performers from the end, whole names only — CARRYING the title.
        //
        // 🚨 This step used to join cast and date alone, silently dropping the
        // title it had just spent step 2 preserving. A scene with three long
        // names and a long title therefore came out with the pre-title name,
        // reintroducing the very collision the title was added to resolve — and
        // no test reached it, because step 2 returns early for any ordinary
        // cast. Found by the auditor, and it is the same shape as adding a case
        // to an enum and not revisiting every branch that reads it.
        var remaining = cast
        while !remaining.isEmpty {
            remaining.removeLast()
            candidate = join([castPart(remaining), shortestTitle, date], with: " - ")
            if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }
        }

        // Nothing but the title and the date left. The date is never dropped;
        // the title goes only if even that will not fit.
        candidate = join([shortestTitle, date], with: " - ")
        if candidate.utf8.count <= PathComponentName.maximumBytes, !candidate.isEmpty {
            return candidate
        }
        // ⚠️ A title that cannot be shortened below the ceiling — one very long
        // word — made step 3 drop the entire cast for no benefit, and the name
        // came out as a bare date. The title is preferred over the cast, but
        // not at the cost of BOTH: if it cannot fit at all, drop it and keep
        // the performers, who at least identify the scene.
        candidate = join([castPart(cast), date], with: " - ")
        if candidate.utf8.count <= PathComponentName.maximumBytes, !candidate.isEmpty {
            return candidate
        }
        // ⚠️ Nothing structured left. A scene with no studio, cast, title or
        // date is named from its filename stem (decision 6), and rebuilding
        // from the empty parts produces "" — which fits the ceiling trivially
        // and then sanitises to nothing, reporting a perfectly nameable file as
        // having no usable name. Truncate what we were given instead.
        return date ?? PathComponentName.truncated(stem)
    }

    // MARK: - Helpers

    /// The best name the record can offer: the episode title, else the series,
    /// else the existing filename stem.
    ///
    /// ⚠️ The stem is used verbatim and is NOT written back to `asset.episode`.
    /// A filename is not a verified title, and copying it into the record would
    /// launder a filename into data — precisely the mistake #51 was.
    static func usableTitle(_ asset: Asset) -> String? {
        if let t = asset.episode?.trimmed, !t.isEmpty { return t }
        if let s = asset.videoName?.trimmed, !s.isEmpty { return s }
        // ⚠️ A filename that is only whitespace before its extension leaves
        // nothing to name the file after, and `noUsableName` is the honest
        // answer rather than a path built from a blank.
        let stem = (asset.fileName as NSString).deletingPathExtension.trimmed
        return stem.isEmpty ? nil : stem
    }

    private static func year(_ asset: Asset) -> String? {
        guard let raw = asset.releaseDate?.trimmed, raw.count >= 4 else { return nil }
        let candidate = String(raw.prefix(4))
        return Int(candidate) != nil ? candidate : nil
    }

    private static func join(_ parts: [String?], with separator: String) -> String {
        parts.compactMap { $0?.trimmed }.filter { !$0.isEmpty }.joined(separator: separator)
    }

    private static func dot(_ ext: String) -> String { ext.isEmpty ? "" : ".\(ext)" }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

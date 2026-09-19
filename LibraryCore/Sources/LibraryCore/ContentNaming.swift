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
//   Film      Title - Studio - Cast (2019)/Title - Studio - Cast (2019).mkv Kodi/Plex + D11b
//   Episodic  Series/Season 01/Series - S01E02 - Cast - Title.mkv Kodi/Plex + D11b
//   Personal  <personal>/Event or Description - Cast (2019).mkv   Kodi movie shape + D11b
//   Scene     Studio/Studio - Performers - Title - YYYY-MM-DD.ext ViLM-defined
//
// ⚠️ A scene will never match an online scraper, and does not need to: Kodi's
// local-information-only mode reads the sidecar and ignores the filename. The
// filename carries the operator's data; the sidecar carries Kodi's.
//
// 🔄 D11b (2026-09-15, superseding D11a): the filename is the disaster-recovery
// layer — the one copy of canonical metadata that survives if the database is
// lost — so performer credits persist in every grammar above, not just Scene.
// "Cast" is OPTIONAL in each grammar (dropped by truncation, or simply absent);
// it is never a required field. See `recoverFilmOrPersonalName` and
// `recoverEpisodicName` for the read side of this contract — a field this
// grammar writes is only durable if that field can also be parsed back out.

import Foundation

/// Where a video's studio puts it, already resolved against the lexicon (N1).
public enum StudioPlacement: Equatable, Sendable {
    /// Matched to an external source id — it gets its own folder.
    case filed(String)
    /// Ruled out (`unmatchable`) — the shared unfiled folder.
    case unfiled
    /// Not yet processed. The file stays where it is.
    case unprocessed

    /// The matched lexicon name, and nothing else.
    ///
    /// ⭐ The one answer to "what studio may be recorded as authoritative"
    /// (N1). `.unfiled` and `.unprocessed` are absences rather than names: a
    /// video whose `studio:` tag has never been matched has no studio this
    /// library will vouch for, and the filename says so by omitting the
    /// segment. Anything that writes a studio down OUTSIDE the filename — the
    /// `.nfo` sidecar — has to omit it for the same reason, or the two
    /// disagree about which studio a video belongs to (#95).
    ///
    /// ⚠️ An empty matched name reads as no name, exactly as the grammar
    /// already treats one when building the Scene and Film segments.
    public var matchedName: String? {
        guard case let .filed(name) = self, !name.isEmpty else { return nil }
        return name
    }
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
    /// A film or personal asset's only title is a legacy filename that contains performers.
    case legacyTitleContainsPerformers

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
        case .legacyTitleContainsPerformers:
            return "The only title available is a filename containing performers — needs a real title to avoid baking performers into the new filename."
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

    /// `Title - Studio - Cast (2019)/Title - Studio - Cast (2019).mkv`
    private static func film(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        guard let rawTitle = usableTitle(asset) else { return .skipped(.noUsableName) }
        if isLegacyTitleWithPerformers(title: rawTitle, asset: asset, context: c) {
            return .skipped(.legacyTitleContainsPerformers)
        }
        // D11b: fold the title's own " - " before adding the studio's and the
        // cast's, or the fields are indistinguishable to
        // `recoverFilmOrPersonalName` — the same reason `scene()` folds
        // `recordedTitle` (D3's separator collapse).
        let title = foldingSeparator(rawTitle)

        let cast = orderedPerformers(c.performers)
        if let tooLong = cast.first(where: { $0.utf8.count > PathComponentName.maximumBytes }) {
            return .skipped(.performerNameTooLong(tooLong))
        }

        // D11b (2026-09-15, field-set decision): film gains a studio segment
        // — resolved the same way `scene()` resolves it, from the matched
        // lexicon disposition (N1), never from the raw legacy `studio:` tag
        // string. An unmatched or unprocessed studio has no name to write,
        // so the segment is simply absent — it is never invented.
        let studioName: String? = {
            if case let .filed(name) = c.studio { return name.isEmpty ? nil : foldingSeparator(name) }
            return nil
        }()

        let stem = truncateFilmOrPersonal(title: title, studio: studioName, cast: cast, year: year(asset))
        guard let component = PathComponentName.sanitised(stem) else {
            return .skipped(.noUsableName)
        }
        return .path("\(component)/\(component)\(dot(ext))")
    }

    /// `<personal>/Event or Description - Cast (2019).mkv`
    ///
    /// 🚨 Never under a studio, whatever the record says, and never CARRIES a
    /// studio segment either — a personal video may carry one, mis-tagged,
    /// inherited from a filename, or matched in error, and none of that may
    /// file it beside commercial content or claim it as identity in the
    /// name. Kind is evaluated before placement, which is why this branch
    /// never reads `context.studio` at all — unlike `film()`, which does.
    private static func personal(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        guard let rawTitle = usableTitle(asset) else { return .skipped(.noUsableName) }
        if isLegacyTitleWithPerformers(title: rawTitle, asset: asset, context: c) {
            return .skipped(.legacyTitleContainsPerformers)
        }
        // D11b: see the matching comment in `film(_:_:_:)`.
        let title = foldingSeparator(rawTitle)

        let cast = orderedPerformers(c.performers)
        if let tooLong = cast.first(where: { $0.utf8.count > PathComponentName.maximumBytes }) {
            return .skipped(.performerNameTooLong(tooLong))
        }

        let stem = truncateFilmOrPersonal(title: title, studio: nil, cast: cast, year: year(asset))
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
        let foldedSeries = foldingSeparator(series)
        let episodeTitle = (asset.episode?.trimmed).map(foldingSeparator)

        let cast = orderedPerformers(c.performers)
        if let tooLong = cast.first(where: { $0.utf8.count > PathComponentName.maximumBytes }) {
            return .skipped(.performerNameTooLong(tooLong))
        }
        let castPart = { (names: [String]) -> String? in
            names.isEmpty ? nil : names.joined(separator: ", ")
        }
        // ⭐ D11b: at least one credited performer survives if any were
        // credited at all — cast is no longer fully droppable in one step.
        let minCast = cast.isEmpty ? 0 : 1

        // D11b adds cast as a fifth, droppable segment. Series and the S/E
        // marker are structural (never dropped — see the guard clauses
        // above); cast and title are not. Drop order is title first, then
        // cast from the end down to the guaranteed minimum: the title is
        // prose and the weaker identifier of the two once series + S/E
        // already pin the episode, so it goes first. This order is also
        // what makes `recoverEpisodicName` unambiguous when only one of the
        // two survives — see its doc comment.
        var stem = join([foldedSeries, marker, castPart(cast), episodeTitle], with: " - ")

        guard let seriesFolder = PathComponentName.sanitised(series),
              let seasonFolder = PathComponentName.sanitised(String(format: "Season %02d", season)) else {
            return .skipped(.noUsableName)
        }

        var component = PathComponentName.sanitised(stem)

        if component == nil || component!.utf8.count >= PathComponentName.maximumBytes {
            // Drop episode title
            stem = join([foldedSeries, marker, castPart(cast)], with: " - ")
            component = PathComponentName.sanitised(stem)
        }

        // Drop performers from the end, down to the guaranteed minimum
        var remaining = cast
        while (component == nil || component!.utf8.count >= PathComponentName.maximumBytes)
                && remaining.count > minCast {
            remaining.removeLast()
            stem = join([foldedSeries, marker, castPart(remaining)], with: " - ")
            component = PathComponentName.sanitised(stem)
        }

        guard let finalComponent = component else {
            return .skipped(.noUsableName)
        }
        
        return .path("\(seriesFolder)/\(seasonFolder)/\(finalComponent)\(dot(ext))")
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
        // ⭐ D11b: cast is canonical, filename-carried metadata now, so at
        // least one credited performer survives truncation if any were
        // credited at all — it is no longer fully droppable the way it was
        // before D11b.
        let minCast = cast.isEmpty ? 0 : 1

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

        // 3 · performers from the end, down to the guaranteed minimum,
        // whole names only — CARRYING the title.
        //
        // 🚨 This step used to join cast and date alone, silently dropping the
        // title it had just spent step 2 preserving. A scene with three long
        // names and a long title therefore came out with the pre-title name,
        // reintroducing the very collision the title was added to resolve — and
        // no test reached it, because step 2 returns early for any ordinary
        // cast. Found by the auditor, and it is the same shape as adding a case
        // to an enum and not revisiting every branch that reads it.
        var remaining = cast
        while remaining.count > minCast {
            remaining.removeLast()
            candidate = join([castPart(remaining), shortestTitle, date], with: " - ")
            if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }
        }

        // 4a · title + the guaranteed cast + date, one more time — only
        // reachable when cast was always empty (minCast == 0), since a
        // non-empty cast's final combination was already tried as step 3's
        // last iteration above.
        candidate = join([castPart(remaining), shortestTitle, date], with: " - ")
        if candidate.utf8.count <= PathComponentName.maximumBytes, !candidate.isEmpty {
            return candidate
        }
        // 4b · drop the title too, keeping the guaranteed cast (if any) and
        // the date, which is never dropped.
        candidate = join([castPart(remaining), date], with: " - ")
        if candidate.utf8.count <= PathComponentName.maximumBytes, !candidate.isEmpty {
            return candidate
        }
        // ⚠️ Nothing structured left that fits, even the guaranteed minimum.
        // `performerNameTooLong` in `scene()` already rejects any SINGLE
        // oversized name before this runs, so reaching here means combined
        // overflow, not one name alone. A scene with nothing usable is named
        // from its filename stem (decision 6); this is the same last resort
        // for the truly-impossible case.
        return date ?? PathComponentName.truncated(stem)
    }

    // MARK: - Helpers

    /// Checks if the given title is a legacy fallback (i.e. the file stem) that contains any credited performers.
    private static func isLegacyTitleWithPerformers(title: String, asset: Asset, context: NamingContext) -> Bool {
        // If it's explicitly set in episode or videoName, it's not a legacy fallback.
        if let t = asset.episode?.trimmed, !t.isEmpty, t == title { return false }
        if let s = asset.videoName?.trimmed, !s.isEmpty, s == title { return false }
        
        let stem = (asset.fileName as NSString).deletingPathExtension.trimmed
        if title != stem { return false }
        
        // It is a fallback. Check if it contains any performer name.
        for performer in context.performers {
            if title.localizedCaseInsensitiveContains(performer.name) {
                return true
            }
        }
        return false
    }

    /// Truncates a film or personal name, least-identifying first:
    ///
    /// 1. the **studio** (film only — `nil` for personal, dropped first as
    ///    the newest and least essential field)
    /// 2. the **title**, shortened at a word boundary
    /// 3. **performers** from the end, down to a guaranteed minimum of one
    ///    — see the note below
    /// 4. the **year** is never dropped
    ///
    /// ⭐ D11b: cast is canonical, filename-carried metadata now (same as the
    /// studio), so unlike the pre-D11b version of this function it no longer
    /// drops the whole cast to nothing — at least one credited performer
    /// survives if any were credited at all. `performerNameTooLong`, checked
    /// by the callers before this runs, keeps the impossible case (even one
    /// guaranteed name plus the year won't fit) effectively unreachable.
    private static func truncateFilmOrPersonal(title: String, studio: String?,
                                                cast: [String], year: String?) -> String {
        let yearPart = year.map { "(\($0))" }
        let castPart = { (names: [String]) -> String? in
            names.isEmpty ? nil : names.joined(separator: ", ")
        }
        let minCast = cast.isEmpty ? 0 : 1

        // 1 · everything
        var candidate = join([join([title, studio, castPart(cast)], with: " - "), yearPart], with: " ")
        if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }

        // 2 · without the studio
        candidate = join([join([title, castPart(cast)], with: " - "), yearPart], with: " ")
        if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }

        // 3 · shorten the title at a word boundary
        var words = title.split(separator: " ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            candidate = join([join([words.joined(separator: " "), castPart(cast)], with: " - "), yearPart],
                             with: " ")
            if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }
        }
        let shortestTitle = words.isEmpty ? nil : words.joined(separator: " ")

        // 4 · performers from the end, down to the guaranteed minimum
        var remaining = cast
        while remaining.count > minCast {
            remaining.removeLast()
            candidate = join([join([shortestTitle, castPart(remaining)], with: " - "), yearPart], with: " ")
            if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }
        }

        // 5 · drop the title too, keeping the guaranteed cast (if any) and the year
        candidate = join([castPart(remaining), yearPart], with: " ")
        if candidate.utf8.count <= PathComponentName.maximumBytes, !candidate.isEmpty {
            return candidate
        }

        // 6 · last resort, effectively unreachable given the per-name length
        // guard in film()/personal(): character-truncate whatever we have
        // rather than split a performer's name, which is never truncated
        // mid-name (the same rule `scene()`'s truncation follows).
        if let shortestTitle = shortestTitle, minCast == 0 {
            let budget = PathComponentName.maximumBytes - (yearPart.map { $0.utf8.count + 1 } ?? 0)
            let truncatedTitle = PathComponentName.truncated(shortestTitle, toBytes: budget)
            return join([truncatedTitle, yearPart], with: " ")
        }
        return PathComponentName.truncated(candidate.isEmpty ? title : candidate)
    }

    // MARK: - Recovery (D11b) — reading canonical metadata back out of a
    // generated name

    /// What `film()`/`personal()` wrote, read back out of the path component
    /// they produced — the inverse of `truncateFilmOrPersonal`.
    ///
    /// 🚨 This is the durability guarantee D11b actually rests on. Writing
    /// performers into a filename is only a disaster-recovery layer if this
    /// function can get them back out with no database, no roster, nothing
    /// but the string itself — so it parses SYNTACTICALLY, the same way the
    /// writer builds the string, never by matching against known names.
    ///
    /// ⚠️ Only recovers what the writer actually persisted. A field dropped
    /// by truncation is gone from the string and comes back empty/nil here —
    /// that is the truthful answer, not a bug in this function.
    ///
    /// 🚨 D11b's field-set decision (2026-09-15) gave film a second optional,
    /// droppable segment — studio, alongside cast. That creates the same
    /// ambiguity `recoverEpisodicName` already has: when exactly ONE optional
    /// segment survives truncation, it could be the studio or the cast, and
    /// the write side's drop order (studio first — see
    /// `truncateFilmOrPersonal`) does not by itself say which, because a
    /// film with a dropped studio and a guaranteed one-performer cast
    /// produces the same shape as a film with a studio and no credited
    /// performers. `personal()` never writes a studio, so this ambiguity
    /// never actually arises for a personal-produced name, but this function
    /// serves both and cannot tell which grammar wrote a given string.
    public struct RecoveredFilmOrPersonalName: Equatable, Sendable {
        public let title: String
        public let studio: String?
        public let cast: [String]
        public let year: String?
        /// Set only when exactly one optional segment survived and neither
        /// `knownStudioNames` nor `knownPerformerNames` could resolve it.
        public let ambiguousSegment: String?
    }

    /// - Parameters:
    ///   - component: the extensionless stem `film()`/`personal()` produced
    ///     — the folder name, or the filename with its extension removed;
    ///     both are identical by construction.
    ///   - knownStudioNames: the library's current studio lexicon, used only
    ///     to disambiguate a single surviving segment. Leave empty for a
    ///     true blind parse — e.g. recovering a library from files alone,
    ///     D11b's actual worst case — and the segment comes back in
    ///     `ambiguousSegment` instead of being guessed into the wrong field.
    ///   - knownPerformerNames: same, for the performer roster.
    public static func recoverFilmOrPersonalName(_ component: String,
                                                  knownStudioNames: [String] = [],
                                                  knownPerformerNames: [String] = []) -> RecoveredFilmOrPersonalName {
        var remainder = component
        var year: String?

        // The year is always the trailing " (YYYY)" — never dropped by the
        // writer (`truncateFilmOrPersonal` guards it explicitly).
        if let match = remainder.range(of: #" \((\d{4})\)$"#, options: .regularExpression) {
            year = String(remainder[match].dropFirst(2).dropLast())
            remainder.removeSubrange(match)
        }

        // What remains is "{title}", "{title} - {studio-or-cast}", or
        // "{title} - {studio} - {cast}" — never more fields than that,
        // because `foldingSeparator` folded every OTHER " - " the title (and
        // the studio name) contained before this name was ever written (see
        // `film(_:_:_:)`).
        let parts = remainder.components(separatedBy: " - ")
        let title = parts[0]
        let trailing = Array(parts.dropFirst())

        switch trailing.count {
        case 0:
            return RecoveredFilmOrPersonalName(title: title, studio: nil, cast: [], year: year,
                                                ambiguousSegment: nil)
        case 1:
            let segment = trailing[0]
            if !knownStudioNames.isEmpty,
               knownStudioNames.contains(where: { $0.caseInsensitiveCompare(segment) == .orderedSame }) {
                return RecoveredFilmOrPersonalName(title: title, studio: segment, cast: [], year: year,
                                                    ambiguousSegment: nil)
            }
            let candidateNames = segment.components(separatedBy: ", ").map { $0.trimmed }
            let looksLikeCast = !knownPerformerNames.isEmpty && candidateNames.allSatisfy { name in
                knownPerformerNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            if looksLikeCast {
                return RecoveredFilmOrPersonalName(title: title, studio: nil, cast: candidateNames, year: year,
                                                    ambiguousSegment: nil)
            }
            return RecoveredFilmOrPersonalName(title: title, studio: nil, cast: [], year: year,
                                                ambiguousSegment: segment)
        default:
            // Fixed write-side order: studio is dropped BEFORE cast (see
            // `truncateFilmOrPersonal`), so two segments surviving means
            // nothing was dropped at all — both are present in full, written
            // "{title} - {studio} - {cast}".
            let studio = trailing[0]
            let cast = trailing[1].components(separatedBy: ", ").map { $0.trimmed }.filter { !$0.isEmpty }
            return RecoveredFilmOrPersonalName(title: title, studio: studio, cast: cast, year: year,
                                                ambiguousSegment: nil)
        }
    }

    /// What `episodic()` wrote, read back out — the inverse of its
    /// truncation drop order (title first, then cast).
    ///
    /// 🚨 One genuine ambiguity survives, and this function reports it rather
    /// than guessing: when truncation has dropped exactly one of
    /// {cast, title}, the single remaining segment could be either. The write
    /// side's drop order does not by itself say which, because BOTH being
    /// absent and either one alone are all representable by "one segment
    /// left" once the other kind of segment happens to be empty too — e.g. a
    /// video with no episode title and a one-name cast looks identical, on
    /// the wire, to a video with cast dropped and a one-word title. Pass
    /// `knownPerformerNames` (the library's current roster) to disambiguate
    /// when it's available; leave it empty for a true blind parse — e.g.
    /// recovering a library from files alone, D11b's actual worst case — and
    /// the segment comes back in `ambiguousSegment` instead of being guessed
    /// into the wrong field.
    public struct RecoveredEpisodicName: Equatable, Sendable {
        public let series: String
        public let season: Int
        public let episode: Int
        public let cast: [String]
        public let title: String?
        public let ambiguousSegment: String?
    }

    /// - Parameter component: the extensionless stem `episodic()` produced —
    ///   the filename with its extension removed.
    public static func recoverEpisodicName(_ component: String,
                                            knownPerformerNames: [String] = []) -> RecoveredEpisodicName? {
        let parts = component.components(separatedBy: " - ")
        guard parts.count >= 2,
              let markerMatch = parts[1].range(of: #"^S(\d{2})E(\d{2})$"#, options: .regularExpression),
              markerMatch == parts[1].startIndex..<parts[1].endIndex else {
            return nil
        }
        let digits = parts[1].filter(\.isNumber)
        guard digits.count == 4,
              let season = Int(digits.prefix(2)),
              let episode = Int(digits.suffix(2)) else {
            return nil
        }

        let series = parts[0]
        let trailing = Array(parts.dropFirst(2))

        switch trailing.count {
        case 0:
            return RecoveredEpisodicName(series: series, season: season, episode: episode,
                                          cast: [], title: nil, ambiguousSegment: nil)
        case 1:
            let segment = trailing[0]
            let candidateNames = segment.components(separatedBy: ", ").map { $0.trimmed }
            let looksLikeCast = !knownPerformerNames.isEmpty && candidateNames.allSatisfy { name in
                knownPerformerNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            if looksLikeCast {
                return RecoveredEpisodicName(series: series, season: season, episode: episode,
                                              cast: candidateNames, title: nil, ambiguousSegment: nil)
            }
            return RecoveredEpisodicName(series: series, season: season, episode: episode,
                                          cast: [], title: nil, ambiguousSegment: segment)
        case 2:
            // Fixed write-side order: title is dropped before cast, so if
            // both survived, cast was written first.
            let cast = trailing[0].components(separatedBy: ", ").map { $0.trimmed }.filter { !$0.isEmpty }
            return RecoveredEpisodicName(series: series, season: season, episode: episode,
                                          cast: cast, title: trailing[1], ambiguousSegment: nil)
        default:
            // More segments than this grammar ever writes — not one of ours.
            return nil
        }
    }

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

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
    /// filed here and is reported instead. Defaulting the season to 01 was
    /// considered and rejected: the episode number has no such convention, and
    /// half a guess still produces a wrong path.
    private static func episodic(_ asset: Asset, _ c: NamingContext, _ ext: String) -> NamingOutcome {
        guard let series = asset.videoName?.trimmed, !series.isEmpty else {
            return .skipped(.episodicNeeds("series name"))
        }
        guard let episode = asset.episodeNumber else {
            return .skipped(.episodicNeeds("episode number"))
        }
        guard let season = asset.seasonNumber else {
            return .skipped(.episodicNeeds("season number"))
        }

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

        // ⚠️ A missing field takes its separator with it. The naive join
        // produces " -  - " and a name that no longer parses back.
        var stem = join([studioName, castPart, date], with: " - ")
        if stem.isEmpty {
            // Nothing identifying at all — fall back to whatever the record can
            // still offer rather than producing a nameless file.
            guard let fallback = usableTitle(asset) else { return .skipped(.noUsableName) }
            stem = fallback
        }
        stem = truncateScene(stem, studio: studioName, cast: cast, date: date)

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

    /// Scene truncation: the studio first — it is already the folder name, so
    /// repeating it is the only redundant segment — then performers from the
    /// end, whole names only. The date is never dropped.
    private static func truncateScene(_ stem: String, studio: String?,
                                      cast: [String], date: String?) -> String {
        guard stem.utf8.count > PathComponentName.maximumBytes else { return stem }

        var candidate = join([cast.isEmpty ? nil : cast.joined(separator: ", "), date],
                             with: " - ")
        if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }

        var remaining = cast
        while !remaining.isEmpty {
            remaining.removeLast()
            candidate = join([remaining.isEmpty ? nil : remaining.joined(separator: ", "), date],
                             with: " - ")
            if candidate.utf8.count <= PathComponentName.maximumBytes { return candidate }
        }
        return date ?? stem
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

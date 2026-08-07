// Plugin.swift
// The plugin contract. Core declares the protocols; it declares no source.
//
// Per the Plugin Architecture epic (D4): a plugin owns exactly one thing —
// how to turn a name or a title into candidate records from one source. It has
// no write path. It proposes; core decides how the proposal is reviewed and
// applied.
//
// NOTHING in this file may name a source, an endpoint, or a source-specific
// vocabulary. That is asserted by test (T2), not by convention.

import Foundation

// MARK: - Identity

/// What a plugin needs before a credential is supplied.
public enum CredentialRequirement: String, Equatable, Sendable, CaseIterable {
    case none
    case apiKey
    case token
}

/// What a plugin can enrich. A plugin may declare more than one.
public enum PluginCapability: String, Equatable, Sendable, CaseIterable {
    case videoMetadata
    case actorMetadata
    case studioMetadata
}

/// Identity and description. Everything the Settings screen needs to render a
/// plugin row and detail page without knowing what the plugin actually does.
public protocol Plugin: Sendable {
    /// Stable identifier. Keys the Keychain entry and the response cache, so it
    /// must not change across versions.
    var id: String { get }

    var displayName: String { get }
    var summary: String { get }

    var capabilities: Set<PluginCapability> { get }
    var credentialRequirement: CredentialRequirement { get }

    /// Attribution text the source's licence requires, if any. Displayed
    /// verbatim wherever its data appears.
    var attribution: String? { get }

    /// Human-facing home page for the source, shown in plugin detail.
    var homepage: URL? { get }

    /// Requests per second this plugin's source tolerates. Core's shared HTTP
    /// client enforces it; the plugin declares it (D6).
    var requestsPerSecond: Double { get }

    /// Which stored credential this plugin uses. Defaults to its own id.
    ///
    /// Override it where two plugins are backed by the same ACCOUNT. Splitting
    /// one source into separate capabilities is right — a library may want
    /// video matching without actor lookups — but it must not mean entering the
    /// same API key twice under two names, where revoking it in one place
    /// silently leaves the other half working off a stale copy.
    var credentialId: String { get }
}

public extension Plugin {
    var attribution: String? { nil }
    var homepage: URL? { nil }
    var requestsPerSecond: Double { 1.0 }
    var credentialId: String { id }
}

// MARK: - Candidates

/// One search result, before the user has chosen which record to fetch.
///
/// Deliberately thin: enough to disambiguate two similarly-named records in a
/// picker, and nothing more. The full record costs a second request.
public struct PluginCandidate: Equatable, Sendable, Identifiable {
    /// The source's own identifier, opaque to core and passed back to `fetch`.
    public let id: String
    public let title: String
    /// Secondary line — a year, a disambiguation, a known alias.
    public let subtitle: String?
    /// Small image for a compact row. Kept deliberately small: a picker showing
    /// several rows would otherwise pull a full-size portrait for each.
    public let thumbnailURL: URL?
    /// Full-size image, for when the user needs a better look before choosing.
    ///
    /// Separate from `thumbnailURL` because the two are wanted at different
    /// moments — a list wants small and fast, a decision wants big and clear.
    /// A provider with only one size may supply the same URL for both.
    public let fullImageURL: URL?

    /// EVERY image the source has for this candidate, largest first.
    ///
    /// A picker row shows one image, which is often not enough to tell two
    /// similarly-named performers apart. These let the UI expand a candidate
    /// into a grid without a second request — a search response typically
    /// carries them already, so exposing them costs nothing.
    ///
    /// Empty when the source offers none; never contains `thumbnailURL`
    /// separately from its full-size original.
    public let imageURLs: [URL]

    /// Running time, where the source knows it.
    ///
    /// Carried on the candidate rather than fetched per record because it is
    /// the strongest thing a person has to judge by when browsing: two scenes
    /// with the same cast and studio are told apart by their length long before
    /// anything else. A picker can compare it against the file in hand and say
    /// so. Nil where the source does not publish it — and for candidates that
    /// are not videos at all.
    public let durationSeconds: Int?

    /// When the source says this was released, as the source wrote it —
    /// `YYYY-MM-DD` from every provider so far.
    ///
    /// Structured rather than left inside `subtitle` because it decides
    /// something: where the same work is offered by two studios, the earlier
    /// release is the original production and the later one a redistribution.
    /// A date buried in display text cannot make that comparison.
    public let releaseDate: String?

    public init(id: String, title: String, subtitle: String? = nil,
                thumbnailURL: URL? = nil, fullImageURL: URL? = nil,
                imageURLs: [URL] = [], durationSeconds: Int? = nil,
                releaseDate: String? = nil) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.releaseDate = releaseDate
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.fullImageURL = fullImageURL ?? thumbnailURL
        // Falling back to the single image keeps a provider that supplies only
        // one from producing an empty grid.
        self.imageURLs = imageURLs.isEmpty
            ? [fullImageURL ?? thumbnailURL].compactMap { $0 }
            : imageURLs
    }
}

/// Who a performer IS, as far as the library knows.
///
/// A name alone is not an identity. Two people share it more often than is
/// comfortable — a real search for "Robin Vale" returns two, born nine years
/// apart — and picking the first is a coin flip that fails silently: the search
/// returns nothing and reports "no match" rather than "I chose the wrong
/// person of that name".
///
/// Everything the library has already established about a performer travels
/// with the name, so a match that was validated once is not re-guessed on every
/// subsequent lookup. That is the point of recording it.
public struct PerformerIdentity: Equatable, Sendable {
    public let name: String
    /// From a previous match. The strongest evidence there is: two people of
    /// one name are not born on the same day.
    public let birthDate: String?
    /// The source's own identifier, where a previous match recorded one.
    /// Decisive when present — no searching required.
    public let sourceId: String?

    public init(name: String, birthDate: String? = nil, sourceId: String? = nil) {
        self.name = name
        self.birthDate = birthDate
        self.sourceId = sourceId
    }

    /// Builds identities from the library's own profiles, so a search carries
    /// what previous matching established.
    public static func from(names: [String],
                            profiles: [String: EntityProfile]) -> [PerformerIdentity] {
        names.map { name in
            let profile = profiles["actor:\(name)"] ?? profiles[name]
            return PerformerIdentity(name: name,
                                     birthDate: profile?.birthDate,
                                     sourceId: profile?.enrichmentSourceId)
        }
    }
}

/// What an operator is asking for when they search by hand.
public struct BrowseQuery: Equatable, Sendable {
    public var performerNames: [String]
    public var studio: String?
    /// Narrows to scenes carrying ALL of these — the way a person uses tags to
    /// cut a long list down.
    public var tags: [String]
    public var title: String?

    public init(performerNames: [String] = [], studio: String? = nil,
                tags: [String] = [], title: String? = nil) {
        self.performerNames = performerNames
        self.studio = studio
        self.tags = tags
        self.title = title
    }
}

/// Which filter a suggestion list is for.
public enum BrowseFilterKind: String, Equatable, Sendable, CaseIterable {
    case performer
    case studio
    case tag
}

public struct BrowseResult: Sendable {
    public let candidates: [PluginCandidate]
    public let total: Int
    /// Filters the source could not resolve and therefore did NOT apply.
    ///
    /// Surfaced so the operator can tell "this filter found nothing" from "this
    /// filter was ignored" — two very different situations that otherwise look
    /// identical from a list of results.
    public let unresolvedFilters: [String]

    public init(candidates: [PluginCandidate], total: Int, unresolvedFilters: [String] = []) {
        self.candidates = candidates
        self.total = total
        self.unresolvedFilters = unresolvedFilters
    }
}

// MARK: - Proposals

/// A proposed value for one field.
///
/// `nil` means the source had nothing to say, which is NOT the same as an empty
/// value and must never clear a populated field (D5).
public struct ProposedField<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value?
    /// Shown in the review sheet so the user can weigh where a value came from.
    public let sourceNote: String?

    public init(_ value: Value?, sourceNote: String? = nil) {
        self.value = value
        self.sourceNote = sourceNote
    }

    public static var absent: Self { .init(nil) }
}

/// Everything a plugin may propose about an actor.
///
/// These are CORE's field names and CORE's vocabulary. A plugin never returns
/// its source's enums — mapping happens inside the plugin, which is where
/// source-specific knowledge belongs (D4).
public struct ActorMetadataProposal: Equatable, Sendable {
    /// The source's own identifier for this person.
    ///
    /// Carried so a validated match can be RECORDED rather than re-derived. A
    /// name is not an identity — two people share one often enough that
    /// re-searching later picks the wrong one and fails silently.
    public var sourceId: ProposedField<String> = .absent
    public var bio: ProposedField<String> = .absent
    public var gender: ProposedField<String> = .absent
    public var hairColor: ProposedField<String> = .absent
    public var countryOfOrigin: ProposedField<String> = .absent
    public var birthYear: ProposedField<Int> = .absent
    public var birthDate: ProposedField<String> = .absent
    public var careerStartYear: ProposedField<Int> = .absent
    public var careerEndYear: ProposedField<Int> = .absent
    /// Only when a source STATES it. Core derives one otherwise, so a plugin
    /// that computes this itself would be inventing provenance.
    public var ageAtCareerStart: ProposedField<Int> = .absent
    /// Verbatim career-span text from a prose source. Never synthesised.
    public var careerSpanRaw: ProposedField<String> = .absent
    public var akas: ProposedField<[String]> = .absent
    public var tags: ProposedField<[String]> = .absent
    public var photoURL: ProposedField<URL> = .absent
    /// Additional images offered for the actor's photo gallery.
    ///
    /// Separate from `photoURL` because the user chooses these individually —
    /// none, some, or all — rather than accepting them as one field. Core stores
    /// references and downloads only what the user ticks.
    public var galleryURLs: ProposedField<[URL]> = .absent
    /// Reference links, LABELLED with whatever system each is on.
    ///
    /// Labelled rather than bare URLs because a list of naked links renders
    /// poorly and the source usually knows the site name already. Core stores
    /// them; it never fetches them.
    public var externalLinks: ProposedField<[EntityLink]> = .absent

    public init() {}
}

/// Everything a plugin may propose about a studio.
///
/// Deliberately short. A studio is a company, and the fields that make an actor
/// record useful — a birth date, a career span, a hair colour — describe a
/// person and nothing else. The one thing here that an actor has no equivalent
/// of is the hierarchy, and it is the reason this type exists.
public struct StudioMetadataProposal: Equatable, Sendable {
    /// The source's own identifier for this studio.
    ///
    /// ⚠️ A name is not an identity. Two networks can use the same imprint
    /// name, and an imprint can be renamed — so carrying the id is what lets a
    /// studio hold a confirmed match rather than a spelling.
    public var sourceId: ProposedField<String> = .absent
    /// The source's canonical spelling.
    public var name: ProposedField<String> = .absent
    public var bio: ProposedField<String> = .absent
    /// Former names and alternative spellings.
    public var akas: ProposedField<[String]> = .absent

    /// The network that owns this imprint, where the source knows of one.
    ///
    /// ⚠️ Confirming an imprint therefore asserts a SECOND node and an edge —
    /// one lookup yielding two studios and a `studio_parent` row. That is the
    /// point of matching studios directly rather than waiting for videos.
    public var parentName: ProposedField<String> = .absent
    public var parentSourceId: ProposedField<String> = .absent

    /// The studio's logo.
    ///
    /// ⚠️ Never applied by an unattended run — see `StudioBatchPolicy`. It is
    /// the studio's equivalent of an actor photo, and wrong in the same
    /// immediately visible way on every screen the studio appears on.
    public var logoURL: ProposedField<URL> = .absent
    public var homePage: ProposedField<String> = .absent
    public var externalLinks: ProposedField<[EntityLink]> = .absent

    public init() {}
}

/// Everything a plugin may propose about a video.
/// One performer's appearance in one video, as a source describes it.
///
/// ⭐ The appearance is the thing with properties. A credited name belongs to
/// neither the person nor the video — a performer is credited differently in
/// different scenes, and a video credits each of its cast separately — so it is
/// a property of the edge between them, which is exactly what v29's
/// `credited_as` column is for.
public struct ProposedCredit: Equatable, Sendable, ExpressibleByStringLiteral {
    /// The performer's canonical name — what becomes an `actor:` tag.
    public let name: String

    /// The name used in THIS video, when the source says it differs.
    ///
    /// ⚠️ nil means "credited under their usual name", and is deliberately not
    /// stored as a copy of `name`: a duplicated name is a second place for it
    /// to go stale, and it would make "was credited differently here" —
    /// genuinely interesting — indistinguishable from the ordinary case.
    public let creditedAs: String?

    /// Billing order where the source states it. Never inferred from the order
    /// a list happened to arrive in, which says nothing about billing.
    public let billing: Int?

    /// ⭐ The source's own identifier for this performer.
    ///
    /// 🚨 The whole reason a video match can identify its cast. The source's
    /// scene record LINKS to a confirmed performer record — it is not a name
    /// the app has to look up again — and carrying that link is what stops the
    /// operator re-matching every performer by name, repeating a
    /// disambiguation the source had already done.
    public let sourceId: String?

    public init(name: String, creditedAs: String? = nil, billing: Int? = nil,
                sourceId: String? = nil) {
        self.name = name
        self.creditedAs = creditedAs
        self.billing = billing
        self.sourceId = sourceId
    }

    /// So a plain name still reads as one. Most call sites and every fixture
    /// name a performer and nothing else.
    public init(stringLiteral value: String) {
        self.init(name: value)
    }
}

public struct VideoMetadataProposal: Equatable, Sendable {
    public var title: ProposedField<String> = .absent
    public var releaseYear: ProposedField<Int> = .absent
    /// The full publication day as `yyyy-MM-dd`.
    ///
    /// Separate from `releaseYear` rather than replacing it: a source that
    /// knows only the year should say only the year instead of inventing a
    /// January the first that then looks like a fact.
    public var releaseDate: ProposedField<String> = .absent
    public var seriesTitle: ProposedField<String> = .absent
    /// Who released it. Stored as a `studio:` tag rather than its own column,
    /// which is the convention the library already uses.
    ///
    /// ⚠️ This is the IMPRINT — the specific label a scene was released under,
    /// which is frequently a sub-studio of a much better-known network. It is
    /// the truth about the scene and needs no decision.
    public var studio: ProposedField<String> = .absent

    /// The source's own id for that studio.
    ///
    /// A name is not an identity: two networks can use the same imprint name,
    /// and an imprint can be renamed. Carrying the id is what lets a studio
    /// hold a confirmed match rather than a spelling.
    public var studioSourceId: ProposedField<String> = .absent

    /// The network the imprint belongs to, where the source knows of one.
    ///
    /// ⚠️ NOT an alternative value for `studio` — both are real studios, and
    /// the scene genuinely belongs to the imprint. Which level the operator
    /// wants to SEE and file by is a separate, per-studio preference, and one
    /// they answer once rather than at every scene.
    public var studioParent: ProposedField<String> = .absent

    public var studioParentSourceId: ProposedField<String> = .absent
    public var seasonNumber: ProposedField<Int> = .absent
    public var episodeNumber: ProposedField<Int> = .absent
    public var episodeTitle: ProposedField<String> = .absent
    public var notes: ProposedField<String> = .absent
    /// The cast, each with the name they were credited under in THIS video.
    ///
    /// 🚨 Was `[String]`, which is why v29's `credited_as` column has never held
    /// a value. The source states the name a performer appeared under in a
    /// specific scene; a bare list of canonical names had nowhere to put it, so
    /// it was read and dropped at the plugin boundary.
    public var actors: ProposedField<[ProposedCredit]> = .absent
    public var tags: ProposedField<[String]> = .absent
    public var externalLinks: ProposedField<[URL]> = .absent

    public init() {}
}

/// An artwork reference. Core downloads it only after the user accepts it.
public struct ArtworkReference: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable { case poster, still, portrait }
    public var id: String { url.absoluteString }
    public let url: URL
    public let kind: Kind
    public let width: Int?
    public let height: Int?

    public init(url: URL, kind: Kind, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.kind = kind
        self.width = width
        self.height = height
    }
}

// MARK: - Provider protocols

public enum PluginError: Error, Equatable, Sendable {
    /// The plugin needs a credential that has not been supplied.
    case missingCredential
    /// The source rejected the credential.
    case unauthorized
    /// The source asked us to slow down.
    case rateLimited(retryAfter: TimeInterval?)
    /// The source returned nothing for this identifier.
    case notFound
    /// Anything else, with a message safe to show the user.
    case failed(String)
}

public protocol ActorMetadataProvider: Plugin {
    func search(name: String) async throws -> [PluginCandidate]
    func fetch(actorId: String) async throws -> ActorMetadataProposal
}

/// Looks a studio up directly, rather than learning about it in passing.
///
/// ⚠️ This exists because until now studio facts arrived ONLY as a by-product
/// of matching a video. A library could therefore know a studio's parent for
/// the imprints it happened to have matched and nothing about the rest, and the
/// only way to fill the gap was to re-match every video — an enormous amount of
/// work to answer a question about a few hundred companies.
///
/// A source that can search scenes can almost always search studios too; the
/// capability was simply never asked for.
public protocol StudioMetadataProvider: Plugin {
    func search(name: String) async throws -> [PluginCandidate]
    func fetch(studioId: String) async throws -> StudioMetadataProposal
}

public protocol VideoMetadataProvider: Plugin {
    func search(title: String, year: Int?) async throws -> [PluginCandidate]

    /// Identify a video by what it LOOKS like rather than what it is called.
    ///
    /// This is the path worth trying first where a provider supports it: a
    /// perceptual fingerprint survives re-encoding, so it identifies a file
    /// whose name, container and bitrate have all changed. Measured against one
    /// live source it resolved roughly 70% of a real library outright, with no
    /// human judgement involved — everything else here exists for the
    /// remainder.
    ///
    /// `distance` is the number of differing bits a provider may tolerate.
    /// Providers whose lookup is exact should ignore it.
    func match(perceptualHash: UInt64, distance: Int) async throws -> [PluginCandidate]

    /// Narrow by the people who appear in it.
    ///
    /// Two names together is a far stronger key than one: measured against a
    /// live source, a single performer returned over a hundred candidates for
    /// most queries while a pair collapsed the same searches to five or fewer.
    /// A provider that cannot search this way returns nothing rather than
    /// falling back to one name, because a hundred candidates is not a result.
    func search(performers: [PerformerIdentity], studio: String?) async throws -> [PluginCandidate]

    /// The outcome of an operator-driven search.
    ///
    /// `unresolvedFilters` is the part that matters: a filter the source could
    /// not interpret is DROPPED, and a dropped filter looks exactly like a
    /// filter that did nothing. Studio names in a library come from filenames
    /// and often have the spaces run out of them, so this is common rather than
    /// exotic — and silently returning everything reads as a broken feature.
    ///
    /// An operator-driven search, for when the automatic passes found nothing.
    ///
    /// Deliberately laxer than `search(performerNames:studio:)`. That one
    /// refuses a single name because a hundred candidates is useless to a
    /// machine deciding on its own. A person BROWSING is in a different
    /// position: they are narrowing by eye, one name plus a studio is exactly
    /// how they would do it by hand, and a long list they can page through
    /// beats being told no match exists.
    ///
    /// Returns the page and the total so the UI can say how much is left.
    func browse(_ query: BrowseQuery, page: Int) async throws -> BrowseResult

    /// Names the source recognises, for completing a filter as it is typed.
    ///
    /// These vocabularies are the source's, not the library's, and a filter it
    /// cannot resolve is simply not applied — so typing one from memory fails
    /// quietly and looks like a filter that does nothing. Completing against
    /// the real list turns that from a puzzle into a non-event.
    func suggestions(for kind: BrowseFilterKind, matching text: String) async throws -> [String]
    func fetch(videoId: String) async throws -> VideoMetadataProposal
    func artwork(videoId: String) async throws -> [ArtworkReference]
}

public extension VideoMetadataProvider {
    /// Artwork is optional; a provider that has none need not implement it.
    func artwork(videoId: String) async throws -> [ArtworkReference] { [] }

    /// Defaulted so a provider that only does text search stays valid. Empty
    /// means "this provider cannot answer that", never "no such video".
    func match(perceptualHash: UInt64, distance: Int) async throws -> [PluginCandidate] { [] }

    func search(performers: [PerformerIdentity], studio: String?) async throws -> [PluginCandidate] { [] }

    /// Empty means the provider cannot browse, not that nothing exists.
    func browse(_ query: BrowseQuery, page: Int) async throws -> BrowseResult {
        BrowseResult(candidates: [], total: 0)
    }

    /// Empty means the provider cannot complete that filter, never that no such
    /// name exists — a caller must not treat it as "this name is invalid".
    func suggestions(for kind: BrowseFilterKind, matching text: String) async throws -> [String] {
        []
    }
}

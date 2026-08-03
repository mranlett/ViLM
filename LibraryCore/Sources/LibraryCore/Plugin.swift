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
}

public extension Plugin {
    var attribution: String? { nil }
    var homepage: URL? { nil }
    var requestsPerSecond: Double { 1.0 }
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

    public init(id: String, title: String, subtitle: String? = nil,
                thumbnailURL: URL? = nil, fullImageURL: URL? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.fullImageURL = fullImageURL ?? thumbnailURL
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
    /// Reference links only. Core stores them; it never fetches them.
    public var externalLinks: ProposedField<[URL]> = .absent

    public init() {}
}

/// Everything a plugin may propose about a video.
public struct VideoMetadataProposal: Equatable, Sendable {
    public var title: ProposedField<String> = .absent
    public var releaseYear: ProposedField<Int> = .absent
    public var seriesTitle: ProposedField<String> = .absent
    public var seasonNumber: ProposedField<Int> = .absent
    public var episodeNumber: ProposedField<Int> = .absent
    public var episodeTitle: ProposedField<String> = .absent
    public var notes: ProposedField<String> = .absent
    public var actors: ProposedField<[String]> = .absent
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

public protocol VideoMetadataProvider: Plugin {
    func search(title: String, year: Int?) async throws -> [PluginCandidate]
    func fetch(videoId: String) async throws -> VideoMetadataProposal
    func artwork(videoId: String) async throws -> [ArtworkReference]
}

public extension VideoMetadataProvider {
    /// Artwork is optional; a provider that has none need not implement it.
    func artwork(videoId: String) async throws -> [ArtworkReference] { [] }
}

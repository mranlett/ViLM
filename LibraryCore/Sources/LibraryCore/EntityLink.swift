// EntityLink.swift
// A labelled external reference on an entity's profile.
//
// GENERIC BY CONSTRUCTION. The type names a label and a URL and nothing else:
// "IMDb", "Instagram", "Wikidata" are values supplied at runtime by the operator
// or by whichever plugin is installed. That is what lets this live in core — the
// same reasoning as `enrichmentSource`, which stores a provider's name without
// the repository naming one.
//
// The pipeline STORES links; it never fetches them. Opening one is a human
// action. That is what keeps external references compatible with the app's
// no-background-network posture.

import Foundation

public struct EntityLink: Codable, Equatable, Sendable, Identifiable, Hashable {

    /// Where the link points. Also the identity: the same URL twice is one link,
    /// however it is labelled.
    public let url: String

    /// What system it is on — "IMDb", "Instagram", a studio's name. Supplied by
    /// the operator or by a provider; core never invents one.
    ///
    /// Empty when nothing supplied it, in which case the UI falls back to the
    /// host.
    public var label: String

    public var id: String { url }

    public init(url: String, label: String = "") {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A label worth showing: the supplied one, else the host with any leading
    /// `www.` removed, else the raw URL.
    public var displayLabel: String {
        if !label.isEmpty { return label }
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Only http(s) links are storable.
    ///
    /// A `file:` or `javascript:` value arriving from a provider must never
    /// reach something the app renders as a tappable link.
    public var isValid: Bool {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            return false
        }
        return (scheme == "http" || scheme == "https") && parsed.host?.isEmpty == false
    }

    /// Merges two lists, de-duplicated by URL, preserving order and preferring an
    /// existing label over an incoming blank one.
    ///
    /// Union rather than replace, like tags and AKAs: enrichment may add a link
    /// but must never remove one the operator curated.
    public static func merged(_ existing: [EntityLink], adding incoming: [EntityLink]) -> [EntityLink] {
        var out = existing
        // `uniqueKeysWithValues` would TRAP here: these keys come from stored
        // data, and a list that reached the database by some other path may
        // hold the same URL twice. Keeping the first occurrence matches the
        // de-duplication this function performs anyway.
        var index = Dictionary(existing.enumerated().map { ($1.url, $0) },
                               uniquingKeysWith: { first, _ in first })
        for link in incoming where link.isValid {
            if let at = index[link.url] {
                if out[at].label.isEmpty && !link.label.isEmpty { out[at].label = link.label }
            } else {
                index[link.url] = out.count
                out.append(link)
            }
        }
        return out
    }
}

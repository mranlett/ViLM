// SidecarReader.swift
// Reading a `.nfo` this app did not write (Metadata Sidecars S1, #74).
//
// 🚨 EMITTING A DOCUMENT AND TRUSTING ONE ARE DIFFERENT RISKS, which is why
// this shipped separately from the writer. Everything `MetadataSidecar` writes
// is a projection of data ViLM already holds. Everything read here came from
// somewhere else — another tool, a hand edit, a file copied from an unrelated
// video — and is accepted into the catalogue on the strength of being next to
// a file.
//
// ⚠️ Parsed with `XMLParser` rather than by matching text. A document from
// another tool is arbitrary XML: it can carry entities, a different encoding,
// attributes, comments, and elements in any order. A regex reader would appear
// to work on our own documents and silently mis-read everyone else's — and
// getting a malformed document DETECTED is half of what this type is for.

import Foundation

/// What a sidecar says. Values as written, not yet judged.
///
/// ⚠️ Deliberately not an `Asset`. Turning a document into a record is a
/// decision with rules (`SidecarImport`), and a type that arrives already
/// shaped like the thing it wants to become invites skipping them.
public struct SidecarContents: Equatable, Sendable {
    public var title: String?
    /// Kodi's `set/name` — a series, when the document claims one.
    public var series: String?
    public var plot: String?
    /// `premiered`, an ISO day. `year` is ignored: it is the coarse form of
    /// this same field and cannot disagree usefully.
    public var premiered: String?
    public var studio: String?
    public var tags: [String] = []
    public var actors: [String] = []
    /// Kodi's 0–10 scale, exactly as written. Converting to ViLM's 1–5 is the
    /// importer's job, because halving is lossy and that loss is a decision.
    public var userRating: Int?

    /// 🚨 PARSED BUT NEVER APPLIED — see `SidecarImport`. Read so the value can
    /// be reported and so a future decision has something to work with; a
    /// document that could attach a video to someone else's source record is
    /// the one field where being wrong is not reversible.
    public var uniqueId: SidecarUniqueId?

    public var isEmpty: Bool {
        title == nil && series == nil && plot == nil && premiered == nil
            && studio == nil && userRating == nil && tags.isEmpty && actors.isEmpty
    }

    public init() {}
}

public struct SidecarUniqueId: Equatable, Sendable {
    public let type: String
    public let value: String
}

public enum SidecarReader {

    /// Reads a sidecar document, or nil if it is not one.
    ///
    /// 🚨 S1c — a malformed or partial document imports NOTHING rather than
    /// importing half. `XMLParser` stops at the first structural error, and a
    /// document that failed partway has already handed us some values; keeping
    /// them would mean importing the part of a broken file that happened to
    /// come before the break, which is arbitrary. All or nothing.
    ///
    /// ⚠️ Also nil for a well-formed document that is not about a video —
    /// somebody else's XML sitting under a `.nfo` name parses perfectly and
    /// means nothing here.
    public static func read(_ xml: String) -> SidecarContents? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawKnownRoot else { return nil }
        return delegate.contents.isEmpty ? nil : delegate.contents
    }

    /// The document beside a video, if there is one.
    ///
    /// 🚨 S1d — ONLY the path derived from the video's own name is ever read.
    /// A sidecar is named for the file it accompanies, so a document that
    /// belongs to a different video cannot be reached from here even when it
    /// sits in the same folder. That is the whole defence against a `.nfo`
    /// copied beside the wrong file, and it is a property of never looking
    /// rather than of detecting anything.
    public static func read(besideVideo relativePath: String,
                            in libraryURL: URL) -> SidecarContents? {
        let url = libraryURL.appendingPathComponent(MetadataSidecar.path(forVideo: relativePath))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return read(text)
    }

    // MARK: - Parsing

    private final class Delegate: NSObject, XMLParserDelegate {
        var contents = SidecarContents()
        var sawKnownRoot = false

        private var path: [String] = []
        private var text = ""
        /// The performer currently being read, so `name` inside `actor` is a
        /// cast member and `name` inside `set` is a series.
        private var actorName: String?

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            path.append(element)
            text = ""
            if path.count == 1, element == "movie" || element == "tvshow"
                || element == "episodedetails" || element == "musicvideo" {
                sawKnownRoot = true
            }
            if element == "actor" { actorName = nil }
            if element == "uniqueid", let type = attributes["type"] {
                pendingUniqueIdType = type
            }
        }

        private var pendingUniqueIdType: String?

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast(); text = "" }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.count >= 2 ? path[path.count - 2] : ""

            switch element {
            case "title" where parent != "actor":
                if !value.isEmpty, contents.title == nil { contents.title = value }
            case "name" where parent == "set":
                if !value.isEmpty { contents.series = value }
            case "name" where parent == "actor":
                actorName = value.isEmpty ? nil : value
            case "actor":
                // ⚠️ Order preserved as written. `order` is advisory and
                // frequently absent; re-sorting by a field most documents do
                // not carry would scramble the ones that simply list cast in
                // billing order.
                if let name = actorName, !contents.actors.contains(name) {
                    contents.actors.append(name)
                }
                actorName = nil
            case "plot": if !value.isEmpty, contents.plot == nil { contents.plot = value }
            case "premiered":
                if !value.isEmpty, contents.premiered == nil { contents.premiered = value }
            case "studio": if !value.isEmpty, contents.studio == nil { contents.studio = value }
            case "tag": if !value.isEmpty, !contents.tags.contains(value) { contents.tags.append(value) }
            case "userrating": if contents.userRating == nil { contents.userRating = Int(value) }
            case "uniqueid":
                if !value.isEmpty, contents.uniqueId == nil {
                    contents.uniqueId = SidecarUniqueId(type: pendingUniqueIdType ?? "source",
                                                        value: value)
                }
                pendingUniqueIdType = nil
            default: break
            }
        }
    }
}

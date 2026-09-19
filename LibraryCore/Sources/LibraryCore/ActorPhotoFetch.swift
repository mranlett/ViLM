// ActorPhotoFetch.swift
// Downloading a recorded photo URL to disk, and deciding what a failure MEANS.
//
// 🚨 THE INVARIANT THIS SERVES. A performer's photos are either stored locally
// or absent. There is no third state in which a URL is recorded for a download
// that may happen later — that state is what let 475 performers lose their
// photo files silently: every deletion path in the app (a merge, the duplicate
// cleanup, an undecodable file removed for re-download, and historically a
// glob that destroyed whole galleries on scroll) left the URLs behind looking
// authoritative, so nothing ever reported a loss.
//
// ⭐ Which makes the CLASSIFICATION the interesting part, not the transfer. To
// keep "local or absent" the library must remove an entry whose photo is truly
// gone — and must NOT remove one that merely failed today, or a single flaky
// run erases the only record a performer's pictures ever had. The rule is
// therefore conservative by construction: only an answer that can only mean
// "not there any more" drops an entry. Everything else is kept and reported.
//
// ⚠️ The transport is injected. This type is about the decisions; a test that
// needed a network would assert nothing about them.

import Foundation

public enum ActorPhotoFetch {

    /// What became of one recorded photo URL.
    public enum Outcome: Equatable, Sendable {
        /// Bytes are on disk now. The entry is honest.
        case downloaded
        /// 🚨 The photo is definitively not at this URL any more, so the entry
        /// is a claim the library cannot support and is dropped.
        case gone
        /// Could not be fetched TODAY — offline, rate-limited, a server error,
        /// a refusal that may be hotlink protection. ⚠️ KEPT: this is not
        /// evidence of absence, and treating it as such is how a bad afternoon
        /// becomes permanent data loss.
        case unavailable
    }

    /// What an HTTP answer means for a recorded photo URL.
    ///
    /// ⭐ Pure, and the whole policy lives here so it can be read and tested in
    /// one place rather than inferred from a chain of `if`s around a transfer.
    ///
    /// ⚠️ ONLY 404 and 410 drop an entry. Not 403 — which is commonly hotlink
    /// protection or a temporary block rather than a deletion. Not 5xx, which
    /// is the server having a bad day. Not 429, which is the source asking for
    /// patience and is the one case where dropping would punish the operator
    /// for running the tool too eagerly. The bar for discarding data is that
    /// the answer cannot mean anything else.
    ///
    /// ⚠️ A 200 carrying no usable bytes is `unavailable`, not `gone`: a
    /// truncated transfer and an error page served with the wrong status both
    /// look like this, and neither is proof the photo is missing.
    public static func classify(statusCode: Int, byteCount: Int) -> Outcome {
        switch statusCode {
        case 404, 410:
            return .gone
        case 200..<300:
            return byteCount > 0 ? .downloaded : .unavailable
        default:
            return .unavailable
        }
    }

    /// A URL string that cannot be used at all — unparseable, or a scheme this
    /// app will never fetch.
    ///
    /// ⭐ `gone` rather than `unavailable`, and this is the one place the
    /// conservative rule is deliberately relaxed: retrying is not going to make
    /// `htt;//` parse. Waiting cannot help, so keeping it only preserves an
    /// entry that can never become a file.
    ///
    /// ⚠️ The `local://primary` sentinel is NOT a fetchable URL and is NOT
    /// unusable either — it names the primary file itself. Callers exclude it
    /// before reaching here; it returns nil to say "nothing to fetch".
    public static func unusable(_ urlString: String) -> Bool {
        guard urlString != ProfileImageNaming.localPrimaryToken else { return false }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return true
        }
        return !(scheme == "http" || scheme == "https")
    }

    /// One HTTP answer: the bytes, and the status that came with them.
    /// ⚠️ `nil` means no answer arrived at all — offline, DNS failure, timeout —
    /// which is `unavailable` by definition.
    public typealias Transport = @Sendable (URL) async -> (data: Data, statusCode: Int)?

    /// The default transport. Separated so every other entry point in this
    /// file stays testable without one.
    public static let urlSessionTransport: Transport = { url in
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (data, status)
    }

    /// Downloads one recorded URL to `destination`, and says what happened.
    ///
    /// ⚠️ Writes ONLY on `downloaded`, and atomically. A partial file left at
    /// the destination would be indistinguishable from a real photo until
    /// something tried to decode it — which is exactly the state that gets
    /// files deleted for being undecodable, restarting the whole cycle.
    public static func download(_ urlString: String, to destination: URL,
                                using transport: Transport = urlSessionTransport) async -> Outcome {
        if unusable(urlString) { return .gone }
        guard let url = URL(string: urlString) else { return .gone }
        guard let answer = await transport(url) else { return .unavailable }

        let outcome = classify(statusCode: answer.statusCode, byteCount: answer.data.count)
        guard outcome == .downloaded else { return outcome }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try answer.data.write(to: destination, options: .atomic)
            return .downloaded
        } catch {
            // ⚠️ The transfer worked and the disk did not. That is not evidence
            // the photo is gone, so the entry stays.
            return .unavailable
        }
    }
}

// PathComponentName.swift
// Turning a display name into something a filesystem will accept (T18b).
//
// 🚨 Generating paths from node names reintroduces exactly the defect D3
// rejected filename-encoding over. `/` and `:` are illegal on macOS and both
// occur in real titles; the library volume is ExFAT so Windows' rules apply too
// — a pipe is created happily by macOS and becomes inaccessible the moment the
// drive moves, silent until it matters.
//
// ⚠️ Deterministic substitution, not removal. The same name must always produce
// the same component, in this library and in any other, or a round trip stops
// being a round trip and two libraries disagree about where a file lives.
//
// ⭐ Two names that sanitise alike are a COLLISION, reported and never silently
// merged — see `PathComponentName.collisions`. Silently merging is how two
// studios would end up sharing a folder with no record of which files came from
// which.

import Foundation

public enum PathComponentName {

    /// The per-component ceiling on every filesystem in play.
    public static let maximumBytes = 255

    /// Characters no path component may contain.
    ///
    /// The union of macOS and Windows rules, because the volume is ExFAT and
    /// read on both. Applying only macOS's rules produces names that vanish
    /// when the drive is plugged into something else.
    private static let illegal: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// Names Windows refuses outright, whatever the extension.
    private static let reserved: Set<String> = {
        var out: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 { out.insert("COM\(n)"); out.insert("LPT\(n)") }
        return out
    }()

    /// A display name as a single path component, or nil when nothing usable
    /// survives.
    ///
    /// ⚠️ Nil rather than a placeholder. A name that sanitises to nothing is a
    /// finding — the caller reports it — and inventing `untitled` would file a
    /// real video under a name that says nothing and collides with every other
    /// one that did the same.
    public static func sanitised(_ raw: String) -> String? {
        var out = String(raw.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if illegal.contains(c) { return "_" }
            // Control characters are legal in some filesystems and a menace in
            // all of them.
            return scalar.value < 0x20 ? "_" : c
        })

        // ⚠️ Windows rejects a trailing dot or space, and strips them silently
        // on some paths — which turns two distinct names into one.
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !out.isEmpty else { return nil }

        // A reserved name gets a suffix rather than a substitution, so it stays
        // recognisable to a person reading the folder.
        if reserved.contains(out.uppercased()) { out += "_" }

        return truncated(out)
    }

    /// Cuts to the byte ceiling on a CHARACTER boundary.
    ///
    /// 🚨 Bytes, not characters. The limit is 255 bytes and a name in a
    /// non-Latin script reaches it in far fewer characters — truncating by
    /// character count produces a path the filesystem then rejects, which is
    /// the failure this exists to prevent rather than cause.
    public static func truncated(_ text: String, toBytes limit: Int = maximumBytes) -> String {
        guard text.utf8.count > limit else { return text }
        var out = text
        while out.utf8.count > limit, !out.isEmpty { out.removeLast() }
        // Removing the last character can leave a trailing space or dot behind.
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Groups names that sanitise to the same component.
    ///
    /// ⭐ Returned rather than resolved. Which of two colliding studios owns the
    /// folder is not a decision this type can make, and picking one silently is
    /// how files end up under a name that was never theirs.
    public static func collisions(among names: [String]) -> [String: [String]] {
        var byComponent: [String: [String]] = [:]
        for name in names {
            guard let key = sanitised(name) else { continue }
            byComponent[key, default: []].append(name)
        }
        return byComponent.filter { $0.value.count > 1 }
    }
}

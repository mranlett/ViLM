// QoSConventionTests.swift
// F2 (#5) — the QoS convention, written down where it is enforced.
//
// 🚨 A LINT, NOT A BEHAVIOUR TEST, and the difference matters. This project has
// logged a source scan that stood in for a test it could not write and passed
// for the wrong reason. This is the other thing: QoS is a STATIC property of
// the source — there is no runtime behaviour to assert, because the whole point
// is which constant was typed. Scanning the source is not an approximation of
// the check here; it is the check.
//
// ⚠️ Why it exists at all. The audit that produced F2 found 20 `.userInitiated`
// sites; by the time it was built there were 37, because nothing wrote the rule
// down and every new piece of work reached for the interactive default. The
// convention's acceptance criterion was "documented in-repo so the default does
// not regress" — prose does not do that, and a failing test does.

import XCTest

final class QoSConventionTests: XCTestCase {

    /// THE RULE.
    ///
    /// `.userInitiated` tells the OS **the user is blocked on this**, and the
    /// scheduler answers by pinning performance cores at high clock. That is
    /// right for a tap whose result is the next thing on screen. It is wrong for
    /// anything that sweeps the library, because a multi-minute operation at
    /// interactive priority is how a phone gets hot and a laptop gets loud.
    ///
    ///   • **`.userInitiated`** — a screen's primary content is blocked, and the
    ///     work is small and bounded. Decoding one image. Reading one record.
    ///   • **`.utility`** — anything that sweeps the library or the filesystem,
    ///     and anything with its own progress or status text. The status text is
    ///     the tell: if the screen has to explain that it is working, the user
    ///     is no longer in a tap-to-response interaction.
    ///   • **`.background`** — the user is not watching at all.
    ///
    /// ⚠️ Success is LESS THERMAL ESCALATION, not less wall-clock. A downgraded
    /// sweep may legitimately take longer, and that is the trade being made, not
    /// a regression to be tuned back out.
    ///
    /// ⭐ Every entry below is a site that stays interactive, with the reason.
    /// Adding a `.userInitiated` anywhere else fails this test — which is the
    /// point, because the failure arrives with the rule attached.
    private static let interactiveSites: [String: String] = [
        "AppComponents.swift":
            "Decodes ONE thumbnail for a cell that is on screen now.",
        "DashboardComponents.swift":
            "Decodes ONE profile photo for a card that is on screen now.",
        "ContactSheetFrames.swift":
            "Loads the poster and contact sheet for the video being looked at.",
        "EditContextPanels.swift":
            "Eight videos for a panel, bounded and small; the panel is empty until it returns.",
        "ActorEnrichmentSheet.swift":
            "One actor's studios, and one actor's exposure check — both gate a picker "
            + "opening, and the file itself says this must never be why it fails to open.",
        "HeadToHeadModel.swift":
            "The screen's whole stated purpose is that it opens instantly.",
        "ContentView.swift":
            "Opening a library IS the user-initiated action; the app has no content "
            + "until it returns.",
    ]

    /// Where the app's sources live, found from this file rather than assumed.
    private func appSourceDirectory() throws -> URL {
        // …/LibraryCore/Tests/LibraryCoreTests/ThisFile.swift → …/ViLM/
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent()   // LibraryCoreTests
            .deletingLastPathComponent()                  // Tests
            .deletingLastPathComponent()                  // LibraryCore
            .deletingLastPathComponent()                  // repo root
        let app = repoRoot.appendingPathComponent("ViLM", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: app.path),
                          "app sources not present next to the package")
        return app
    }

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: directory,
                                                        includingPropertiesForKeys: nil)
        else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// 🚨 The regression guard. A new `.userInitiated` in a file that is not on
    /// the list fails here, and the failure carries the rule.
    func testNoNewInteractivePrioritySitesAppear() throws {
        let app = try appSourceDirectory()
        var unlisted: [String] = []

        for file in swiftFiles(under: app) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = file.lastPathComponent
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                // Skip the comment that documents the rule.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(".userInitiated"),
                      !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if Self.interactiveSites[name] == nil {
                    unlisted.append("\(name):\(number + 1)")
                }
            }
        }

        XCTAssertTrue(unlisted.isEmpty, """
            New `.userInitiated` site\(unlisted.count == 1 ? "" : "s") appeared:

              \(unlisted.joined(separator: "\n              "))

            `.userInitiated` means THE USER IS BLOCKED ON THIS, and the scheduler
            answers by pinning performance cores at high clock. Use it only when a
            screen's primary content is waiting AND the work is small and bounded.

            For anything that sweeps the library or the filesystem, or that shows
            its own progress or status text, use `.utility`. If the screen has to
            explain that it is working, the user is not in a tap-to-response
            interaction any more.

            If this site really is interactive, add it to `interactiveSites` above
            WITH THE REASON — that list is the record F2 asked for, and an entry
            without a reason is how the default crept back to 37 sites last time.
            """)
    }

    /// ⚠️ The other direction. A listed file that no longer contains one means
    /// the list is drifting out of date, and a stale allowlist quietly widens
    /// what is permitted.
    func testEveryListedSiteStillExists() throws {
        let app = try appSourceDirectory()
        let filesWithInteractive = Set(swiftFiles(under: app).filter { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.contains(".userInitiated") && !trimmed.hasPrefix("//")
            }
        }.map(\.lastPathComponent))

        let stale = Set(Self.interactiveSites.keys).subtracting(filesWithInteractive)
        XCTAssertTrue(stale.isEmpty, """
            These files are on the interactive allowlist but no longer contain a
            `.userInitiated` site: \(stale.sorted().joined(separator: ", ")).

            Remove them from `interactiveSites`. An allowlist that outlives its
            entries permits sites nobody has judged.
            """)
    }
}

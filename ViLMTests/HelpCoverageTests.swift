// HelpCoverageTests.swift
// Every tool in Settings has a help entry (#61).
//
// 🚨 `HelpContent.settings` enumerates the maintenance tools item by item,
// which makes it a list PRESENTED AS COMPLETE. An incomplete list presented as
// complete is worse than no list: help once pointed at a "Danger Zone section"
// removed three weeks earlier, and the operator spent real time looking for it.
//
// ⚠️ The rule the review spike asked for is "a tool ships with its help entry".
// A rule nobody can check is a rule that decays — nine tools had drifted out of
// the list by the time anyone looked, and the spike's own record of WHICH nine
// was itself stale. So this asserts it.
//
// ⭐ It reads the SOURCE rather than the runtime, because the labels live in
// view code and cannot be enumerated from a running app. That is unusual for a
// test and worth the oddity: the alternative is a rule enforced by memory.

import XCTest
@testable import ViLM

final class HelpCoverageTests: XCTestCase {

    /// The app sources, found relative to this file.
    private func source(_ name: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDir = testsDir.deletingLastPathComponent().appendingPathComponent("ViLM")
        let url = appDir.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { r in String(text[r]) }
        }
    }

    func testEverySettingsToolHasAHelpEntry() throws {
        let tools = try matches(#"toolButton\("([^"]+)""#, in: source("SettingsView.swift"))
        let documented = Set(try matches(#"\.init\(label:\s*"([^"]+)""#, in: source("HelpContent.swift")))

        XCTAssertFalse(tools.isEmpty, "found no tools — the parse broke, not the coverage")

        // ⚠️ The numbered run (`1 · …`) is documented as a sequence under its own
        // heading rather than per item, so it is matched by prefix instead.
        let undocumented = tools.filter { tool in
            if tool.range(of: #"^\d+ ·"#, options: .regularExpression) != nil { return false }
            return !documented.contains(tool)
        }

        XCTAssertTrue(undocumented.isEmpty, """
            \(undocumented.count) tool(s) in Settings have no entry in HelpContent:

              \(undocumented.joined(separator: "\n              "))

            A tool ships with its help entry. `HelpContent.settings` lists the
            tools item by item, so a missing one reads as "this tool does not
            exist" rather than "this list is incomplete".
            """)
    }

    /// ⚠️ The other direction. Help describing a tool that was removed is the
    /// exact Danger Zone failure — the operator goes looking for something that
    /// is not there.
    ///
    /// Advisory rather than failing: `HelpContent` legitimately documents far
    /// more than Settings (grids, filters, the player), so an entry with no
    /// matching button is usually correct.
    func testHelpEntriesNamingASettingsToolStillMatchOne() throws {
        let tools = Set(try matches(#"toolButton\("([^"]+)""#, in: source("SettingsView.swift")))
        let documented = try matches(#"\.init\(label:\s*"([^"]+)""#, in: source("HelpContent.swift"))

        // Only the ones that look like maintenance tools — a verb phrase the
        // Settings screen would plausibly carry.
        let toolish = documented.filter { label in
            ["Match ", "Repair ", "Remove ", "Fix ", "Merge ", "Classify ", "Export ", "Import "]
                .contains { label.hasPrefix($0) }
        }
        let orphaned = toolish.filter { !tools.contains($0) }
        if !orphaned.isEmpty {
            print("ℹ️ Help entries with no Settings button (may be other surfaces): \(orphaned)")
        }
    }

    // MARK: - 🚨 #60 — one convention for sheet sizing

    /// The review spike's finding was not that sheets were broken — none was.
    /// It was that THREE conventions existed for one job, and establishing which
    /// was in use took four attempts, each producing a confident, different,
    /// wrong answer.
    ///
    /// > If the state cannot be determined with one search, the next person
    /// > adding a sheet cannot determine it either — which is exactly how seven
    /// > sheets once shipped collapsed.
    ///
    /// So this IS that one search, run automatically.
    ///
    /// ⚠️ Scoped to views actually presented via `.sheet`. `InspectorView` and
    /// `PlaylistDetailView` carry raw platform-guarded frames and are correct to
    /// — they are not sheets, and converting them was the mistake this scoping
    /// exists to prevent.
    func testSheetPresentedViewsUseTheSizingHelper() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ViLM")
        let files = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // Every view type presented in a `.sheet { … }` anywhere in the app.
        var presented: Set<String> = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in try matches(#"\.sheet\([^)]*\)\s*\{([\s\S]{0,400}?)\n\s{0,16}\}"#, in: text) {
                for name in try matches(#"\b([A-Z][A-Za-z0-9]*View)\s*\("#, in: m) { presented.insert(name) }
            }
        }
        XCTAssertFalse(presented.isEmpty, "found no sheets — the parse broke, not the code")

        var offenders: [String] = []
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard presented.contains(name) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            // ⚠️ The lazy `[\s\S]{0,220}?` this replaced ran straight past an
            // `#else` and flagged a frame in the iOS branch — making this the
            // FIFTH wrong answer to the question the spike said takes four.
            // The scan now stops at `#else` or `#endif`, so it can only match a
            // frame genuinely inside the macOS branch.
            if text.range(of: #"#if os\(macOS\)(?:(?!#else|#endif)[\s\S]){0,220}?\.frame\(\s*min"#,
                          options: .regularExpression) != nil {
                offenders.append(name)
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) sheet-presented view(s) size themselves with a raw
            `#if os(macOS)` + `.frame(min…)` instead of `.macSheet` / `.macFormSheet`:

              \(offenders.joined(separator: "\n              "))

            One convention, so one search answers the question and a missing
            modifier is visible in review.
            """)
    }
}

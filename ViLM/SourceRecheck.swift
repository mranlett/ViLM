// SourceRecheck.swift
// Asking the source about every match the library holds.
//
// 🚨 Extracted from `StaleMatchAuditView` because the ACCOUNTING is the whole
// feature, and it was unreachable inside a view.
//
// Three outcomes look alike and are not:
//
//   present/deleted/merged  the source answered — record it
//   unreachable             the source said nothing — record NOTHING
//   notFound                the source answered "no record under that id"
//
// Collapsing the second into the first marks a whole library deleted the first
// time a connection drops, which is the failure U2 exists to prevent. Merging
// the third into the second is subtler and cost a day: if the source returns
// deleted records as null rather than as records flagged `deleted`, `notFound`
// is the ONLY signal there will ever be — and it was being filed under
// "network problem", so the feature looked permanently, inexplicably empty.

import Foundation
import LibraryCore

enum SourceRecheck {

    /// What a fetch concluded, from the sweep's point of view.
    enum Answer: Equatable {
        case state(SourceRecordState)
        /// The source could not be reached. Concluded nothing.
        case unreachable
        /// The source answered, and has no record under that id.
        case notFound
    }

    struct Summary: Equatable {
        var checked = 0
        var recorded = 0
        var unreachable = 0
        var notFound = 0

        /// ⚠️ Reports every category, because a sweep that failed nine times
        /// in ten must not read as a clean bill of health.
        func sentence(of total: Int) -> String {
            var parts = ["Checked \(checked) of \(total)."]
            if unreachable > 0 {
                parts.append("\(unreachable) could not be reached and were left as they were.")
            }
            if notFound > 0 {
                // ⭐ Said as an observation, not a verdict. The id stopped
                // resolving; whether that is a removal, a merge we cannot
                // follow, or an id that was always wrong is the operator's to
                // decide from the list.
                parts.append("\(notFound) no longer resolve to any record at the source, and are now listed below.")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Runs the sweep, recording only what the source actually concluded.
    ///
    /// - Parameters:
    ///   - ask: performs one lookup. Injected so the accounting can be tested
    ///     without a provider, a network or a registry.
    ///   - record: persists a conclusion. Called ONLY for a real answer.
    ///   - isCancelled: checked between records, so stopping keeps what was
    ///     already written.
    static func run(targets: [RecheckTarget],
                    ask: (RecheckTarget) async -> Answer,
                    record: (RecheckTarget, SourceRecordState) -> Void,
                    isCancelled: () -> Bool = { false },
                    progress: (Int) -> Void = { _ in }) async -> Summary {
        var summary = Summary()
        for target in targets {
            if isCancelled() { break }
            switch await ask(target) {
            case let .state(state):
                // 🚨 Recorded only here. A conclusion we were not given is not
                // a conclusion, however tempting it is to infer one.
                record(target, state)
                summary.recorded += 1
            case .unreachable:
                summary.unreachable += 1
            case .notFound:
                // 🚨 Recorded as of 2026-08-11. It used to be counted and
                // dropped, on the reasoning that only a stated conclusion
                // should be stored — but measuring the device showed the
                // source NEVER states one: 21 of 301 returned no record and
                // none carried a `deleted` flag. This is the answer, and
                // discarding it left the audit permanently empty.
                record(target, .unresolved)
                summary.notFound += 1
            }
            summary.checked += 1
            progress(summary.checked)
        }
        return summary
    }
}

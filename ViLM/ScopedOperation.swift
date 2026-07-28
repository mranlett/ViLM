// ScopedOperation.swift
// Ties security-scoped filesystem access to an *operation's* lifetime instead
// of the presenting view's (DEFECT_INVENTORY H5). Long-running work (restore,
// merge, batch move, duplicate scan, library scan) used to depend on scopes
// held in view @State and released in onDisappear — so dismissing the sheet or
// switching libraries mid-operation revoked file access out from under
// in-flight I/O, producing partial multi-step operations.
//
// Security-scope claims are balanced (each successful start needs one stop,
// and access survives until the *matching* stop), so an operation that claims
// the URLs itself keeps access even after the view releases its own claim.
// The same primitive suits any future long operation (playback prefetch,
// ingestion) — wrap the work, list the URLs it touches.

import Foundation

enum ScopedOperation {
    /// Runs `operation` while independently holding security-scoped access to
    /// `urls`, releasing the claims only when the operation finishes —
    /// regardless of what the view that started it does in the meantime.
    /// URLs that decline scoped access (non-scoped paths, already-open
    /// folders on macOS) are simply skipped; the work proceeds either way.
    @discardableResult
    static func run<T>(holding urls: [URL], _ operation: () async throws -> T) async rethrows -> T {
        let claimed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in claimed { url.stopAccessingSecurityScopedResource() } }
        return try await operation()
    }
}

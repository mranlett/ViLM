// SameIdentityView.swift
// Two profiles, one identity at the source.
//
// ⭐ The sibling of *Duplicate Performers*, and the stronger of the two. That
// screen compares a name against another profile's aliases — a heuristic, and
// one that misses a pair whose names differ only by a space. This one has no
// heuristic in it: the source has already decided these are one person.
//
// 🚨 It also reaches rows nothing else can. A shadow profile — an id, a photo
// and a source id, but no name and no videos — is invisible to the actor grid,
// unfindable by name, and invisible to *Duplicate Performers*. Its source id is
// the only handle on it that exists.

import SwiftUI
import LibraryCore

struct SameIdentityView: View {
    let libraryURL: URL
    var onRefresh: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var findings: [SameIdentityFinding] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var merged = 0
    @State private var isMerging = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Same Person, Twice")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            if merged > 0 { onRefresh() }
                            dismiss()
                        }
                    }
                }
                .overlay {
                    if isMerging {
                        ProgressView("Merging…")
                            .padding().background(.regularMaterial).cornerRadius(10)
                    }
                }
                .task { await load() }
        }
        .macSheet(minWidth: 620, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Comparing identities…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if findings.isEmpty {
            ContentUnavailableView {
                Label(merged > 0 ? "\(merged) merged" : "Every identity is held once",
                      systemImage: "checkmark.seal")
            } description: {
                Text("No two profiles in this library claim the same record at the source. This is the one duplicate check that needs no judgement — the source has already decided who is who.")
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Text(SameIdentityAudit.headline(findings)).font(.callout)
                if merged > 0 {
                    Text("\(merged) merged just now")
                        .font(.caption).foregroundStyle(.green)
                }
            } footer: {
                Text("Each group is one record at the source that two or more of your profiles claim. Merging keeps the profile you choose; every video, photo and alias moves across, and the other name is kept as an alias.")
            }

            ForEach(findings) { finding in
                Section {
                    ForEach(finding.members) { member in
                        row(member, in: finding)
                    }
                } header: {
                    HStack {
                        Image(systemName: finding.isUnambiguous
                              ? "person.crop.circle.badge.checkmark"
                              : "person.2.crop.square.stack")
                            .foregroundStyle(finding.isUnambiguous ? Color.accentColor : .orange)
                        Text(finding.isUnambiguous ? "One name, one shadow" : "Two names")
                        Spacer()
                    }
                } footer: {
                    // ⚠️ Says what a shadow IS. Left unexplained, a row showing
                    // a uid reads as corruption rather than as a duplicate the
                    // operator can safely absorb.
                    if finding.members.contains(where: \.isNameless) {
                        Text("The row shown as an identifier has no name of its own — it was created alongside the real profile and never filled in. It holds nothing but its photo, which moves across when you merge.")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    @ViewBuilder
    private func row(_ member: SameIdentityFinding.Member,
                     in finding: SameIdentityFinding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if member.isNameless {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text(member.displayName)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(member.videoCount == 1 ? "1 video" : "\(member.videoCount) videos")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }

            // ⭐ The action is on the row that would SURVIVE, phrased as what
            // it keeps rather than what it destroys. "Keep this one" is a
            // choice; "delete the other" is the same act read as a loss.
            if !member.isNameless {
                Button("Keep \(member.displayName)") {
                    merge(keeping: member, in: finding)
                }
                .font(.caption)
                .disabled(isMerging)
            }
        }
    }

    private func merge(keeping survivor: SameIdentityFinding.Member,
                       in finding: SameIdentityFinding) {
        let url = libraryURL
        let losers = finding.members.filter { $0.id != survivor.id }.map(\.id)
        isMerging = true
        Task {
            let error: Error? = await Task.detached(priority: .utility) {
                do {
                    let store = try LibraryStore(at: url)
                    // ⚠️ Every other member, not just one. A group can hold two
                    // shadows of the same person — leaving one behind would put
                    // the finding straight back on the list.
                    for loser in losers {
                        try store.mergeSameIdentity(losing: loser, into: survivor.id)
                    }
                    return nil
                } catch { return error }
            }.value

            if let error { failure = error.localizedDescription } else { merged += 1 }
            isMerging = false
            await load()
        }
    }

    private func load() async {
        isLoading = true
        failure = nil
        let url = libraryURL
        let result: Result<[SameIdentityFinding], Error> = await Task.detached {
            do { return .success(try LibraryStore(at: url).sameIdentityFindings()) }
            catch { return .failure(error) }
        }.value

        switch result {
        case let .success(found): findings = found
        case let .failure(error): failure = error.localizedDescription
        }
        isLoading = false
    }
}

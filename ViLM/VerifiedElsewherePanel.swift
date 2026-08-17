// VerifiedElsewherePanel.swift
// "I looked this up myself, and here is where" (#79).
//
// 🚨 THE APP HAD TWO STATES AND THE COMMON CASE IS THE THIRD. Matched by a
// provider, or unmatched — so a video the operator resolved against a real
// listing in their own browser was indistinguishable from one nobody had
// looked at. It stayed in the lookup queue, returned in every audit, and the
// next batch run asked the question that had already failed.
//
// 🚨 INBOUND ONLY. This panel makes no request and has no provider. The
// operator reads a page themselves and types what they found — which is why it
// works for any source at all, including ones no plugin will ever exist for.
//
// ⚠️ It names no source, and must not learn how. The field is free text
// (D7/D9): a picker of known sources would put the names in the public
// repository, and would also be wrong the first time somebody used a fifth one.

import SwiftUI
import LibraryCore

struct VerifiedElsewherePanel: View {
    let asset: Asset
    let libraryURL: URL?
    var onChange: (Asset) -> Void

    @State private var source = ""
    @State private var reference = ""
    @State private var link = ""
    @State private var refusal: String?
    @State private var isEditing = false

    /// ⭐ Derived, not stored. `wasVerifiedByHand` reads the record — a flag
    /// would be a second source of truth about one fact and the two would
    /// disagree the first time anything else wrote the source.
    private var installedProviders: Set<String> {
        Set(PluginEnvironment.registry.installedVideoProviders().map(\.displayName))
    }

    private var isVerifiedByHand: Bool {
        VerifiedElsewhere.wasVerifiedByHand(asset, knownProviders: installedProviders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Found it somewhere else?")
                .font(.subheadline).foregroundColor(.secondary)

            if isVerifiedByHand && !isEditing {
                recorded
            } else if isEditing {
                form
            } else {
                Button {
                    source = asset.enrichmentSource ?? ""
                    reference = asset.enrichmentSourceId ?? ""
                    link = asset.enrichmentUrl ?? ""
                    refusal = nil
                    isEditing = true
                } label: {
                    Label("Record where you verified this", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                Text("For a video the automatic lookup cannot find. Note where you confirmed it and it stops coming back in the queue.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var recorded: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(asset.enrichmentSource ?? "", systemImage: "bookmark.fill")
                .font(.callout)
            if let reference = asset.enrichmentSourceId, !reference.isEmpty {
                Text("reference \(reference)").font(.caption).foregroundStyle(.secondary)
            }
            // ⚠️ The link is OPENABLE, which is the entire reason it is stored.
            // A reference nobody can check is a claim, not evidence.
            if let raw = asset.enrichmentUrl, let url = URL(string: raw) {
                Link(destination: url) {
                    Label("Open the page", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
            if let checked = asset.enrichmentCheckedAt {
                Text("recorded \(checked.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Button("Change") {
                    source = asset.enrichmentSource ?? ""
                    reference = asset.enrichmentSourceId ?? ""
                    link = asset.enrichmentUrl ?? ""
                    refusal = nil
                    isEditing = true
                }
                .font(.caption)
                // ⚠️ Says what it costs. Clearing returns the video to the
                // lookup queue, which is the point, but it is not obvious from
                // the word "remove".
                Button("Remove", role: .destructive) {
                    onChange(VerifiedElsewhere.clearing(from: asset))
                }
                .font(.caption)
            }
            Text("Your title, cast and other edits stay either way — only the note about where you checked is removed.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Where did you look? (required)", text: $source)
                .textFieldStyle(.roundedBorder)
            TextField("Its reference or id (optional)", text: $reference)
                .textFieldStyle(.roundedBorder)
            TextField("Link to the page (optional)", text: $link)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif

            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { isEditing = false; refusal = nil }
                    .font(.caption)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Nothing is sent anywhere — this only records what you found, so the video stops appearing as unidentified.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 🚨 The DECISION is `VerifiedElsewhere.read`, in LibraryCore under test.
    /// Only the wording is here — the same split every other screen on this
    /// project ended up needing, because a rule inside a view is a rule no test
    /// can reach.
    private func save() {
        switch VerifiedElsewhere.read(source: source, reference: reference, link: link) {
        case let .success(verification):
            onChange(VerifiedElsewhere.applying(verification, to: asset))
            isEditing = false
            refusal = nil
        case let .failure(problem):
            refusal = problem.reason
        }
    }
}

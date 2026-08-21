// VerifiedElsewhereProfileSheet.swift
// "I confirmed this studio — or this performer — myself, and here is where" (#79).
//
// 🚨 THE SAME GAP AS THE VIDEO ONE, ONE LEVEL UP, and the operator hits it from
// the other direction: the page they found was a STUDIO's own catalogue, not a
// film listing. 60 of 462 studios and 70 performer profiles carry no identity.
//
// ⚠️ The core half of this shipped on 2026-08-17 — `applying(_:to profile:)`,
// `clearing(from profile:)` and `wasVerifiedByHand(_ profile:)`, with tests —
// and NOTHING CALLED ANY OF IT, because that commit touched no UI file. The
// gap it was written to close stayed open. This is that screen.
//
// 🚨 INBOUND ONLY, like the video panel. No request is made and no provider is
// involved; the operator reads a page themselves and types what they found.
//
// ⚠️ It names no source and must not learn how. Free text (D7/D9) — a picker
// of known sources would put their names in this public repository.

import SwiftUI
import LibraryCore

struct VerifiedElsewhereProfileSheet: View {
    let profile: EntityProfile
    /// Persisted by the caller, which owns the store for this profile.
    var onChange: (EntityProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var source = ""
    @State private var reference = ""
    @State private var link = ""
    @State private var refusal: String?

    private var isStudio: Bool { profile.entityType == "studio" }

    /// ⭐ Which names are the app's, so anything else reads as the operator's.
    /// Both provider kinds, because this one sheet serves studios and
    /// performers and each has its own source.
    private var installedProviders: Set<String> {
        Set(PluginEnvironment.registry.installedStudioProviders().map(\.displayName))
            .union(PluginEnvironment.registry.installed
                .compactMap { ($0 as? any ActorMetadataProvider)?.displayName })
    }

    private var isVerifiedByHand: Bool {
        VerifiedElsewhere.wasVerifiedByHand(profile, knownProviders: installedProviders)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isVerifiedByHand { recorded }
                entry
            }
            .formStyle(.grouped)
            .navigationTitle(profile.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .macFormSheet(minWidth: 560, minHeight: 460)
        .onAppear {
            source = profile.enrichmentSource ?? ""
            reference = profile.enrichmentSourceId ?? ""
            // ⚠️ A profile has no `enrichmentUrl`. The link lives in `links`,
            // and only the one this feature added is offered back for editing —
            // found by its label, which `applying` sets to the source name.
            link = profile.links.first { $0.label == profile.enrichmentSource }?.url ?? ""
        }
    }

    @ViewBuilder
    private var recorded: some View {
        Section {
            LabeledContent("Verified against", value: profile.enrichmentSource ?? "")
            if let checked = profile.enrichmentCheckedAt {
                LabeledContent("Recorded",
                               value: checked.formatted(date: .abbreviated, time: .omitted))
            }
            // ⚠️ Says what it costs, and what it does NOT cost. Clearing undoes
            // the provenance; the link stays in the operator's own list,
            // because deleting from that list because a match was withdrawn
            // would throw away something they never called provenance.
            Button("Remove This Verification", role: .destructive) {
                onChange(VerifiedElsewhere.clearing(from: profile))
                dismiss()
            }
        } footer: {
            Text("Removing it returns \(profile.name) to the unidentified list. Your link, bio and other edits stay.")
        }
    }

    @ViewBuilder
    private var entry: some View {
        Section {
            TextField("Where did you look? (required)", text: $source)
            TextField("Its reference or id (optional)", text: $reference)
            TextField("Link to the page (optional)", text: $link)
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
        } header: {
            Text(isVerifiedByHand ? "Change what you recorded" : "Record where you verified it")
        } footer: {
            Text("Nothing is sent anywhere. This records what you found, so \(isStudio ? "this studio" : "this performer") stops appearing as unidentified and an automatic run will not overwrite it.")
        }
    }

    /// 🚨 The DECISION is `VerifiedElsewhere.read`, in LibraryCore under test.
    /// Only the wording is here — the same split the video panel needed, and
    /// for the same reason: a rule inside a view is a rule no test can reach.
    private func save() {
        switch VerifiedElsewhere.read(source: source, reference: reference, link: link) {
        case let .success(verification):
            onChange(VerifiedElsewhere.applying(verification, to: profile))
            dismiss()
        case let .failure(problem):
            refusal = problem.reason
        }
    }
}

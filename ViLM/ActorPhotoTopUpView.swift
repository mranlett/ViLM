// ActorPhotoTopUpView.swift
// Settings tool: fill in galleries for performers with barely any pictures (#44).
//
// TRACKED and PUBLIC. Names no source.
//
// 🚨 Adds to the gallery and never touches `photoUrl`. The rule and the reason
// live in `ActorPhotoTopUp`; this screen must not quietly acquire an exception
// to it.
//
// ⚠️ Sequential and cancellable. Three hundred requests fired at once is how a
// rate limit gets discovered the hard way, and what has already been applied
// stays applied when the operator stops.

import SwiftUI
import LibraryCore

struct ActorPhotoTopUpView: View {
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ActorPhotoTopUp.Candidate] = []
    @State private var selected: Set<String> = []
    @State private var threshold = ActorPhotoTopUp.defaultThreshold
    @State private var isRunning = false
    @State private var progress = 0
    @State private var toppedUp = 0
    @State private var nothingNew = 0
    @State private var failed = 0
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    private var provider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installedActorProviders().first
    }
    private var fetchable: [ActorPhotoTopUp.Candidate] { candidates.filter(\.canFetch) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Get More Photos")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { task?.cancel(); dismiss() }
                    }
                }
                .task(id: threshold) { load() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Stepper("Fewer than \(threshold) photo\(threshold == 1 ? "" : "s")",
                        value: $threshold, in: 1...10)
                    .disabled(isRunning)
                // ⚠️ Says how many can actually be fetched, not just how many
                // are thin. The difference is the whole reason unmatched
                // performers are listed rather than hidden.
                Text("\(candidates.count) performer\(candidates.count == 1 ? "" : "s") below that, "
                     + "\(fetchable.count) matched to a source and fetchable.")
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Adds to each performer's gallery. Your chosen profile picture is never changed.")
            }

            if let message {
                Section { Text(message).font(.callout) }
            }

            if isRunning {
                Section {
                    HStack {
                        ProgressView()
                        Text("\(progress) of \(selected.count) · \(toppedUp) topped up")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .destructive) { task?.cancel(); isRunning = false }
                }
            } else if !selected.isEmpty {
                Section {
                    Button("Get photos for \(selected.count) performer\(selected.count == 1 ? "" : "s")") {
                        run()
                    }
                    .disabled(provider == nil)
                    if provider == nil {
                        Text("No metadata source is installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(candidates) { candidate in
                    row(candidate)
                }
            } header: {
                HStack {
                    Text("Thinnest first")
                    Spacer()
                    Button(selected.isEmpty ? "Select all fetchable" : "Clear") {
                        selected = selected.isEmpty ? Set(fetchable.map(\.id)) : []
                    }
                    .font(.caption)
                    .disabled(isRunning || fetchable.isEmpty)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func row(_ candidate: ActorPhotoTopUp.Candidate) -> some View {
        Button {
            guard candidate.canFetch, !isRunning else { return }
            if selected.contains(candidate.id) { selected.remove(candidate.id) }
            else { selected.insert(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(candidate.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(candidate.canFetch ? Color.accentColor : Color.secondary.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.profile.name).lineLimit(1)
                    if !candidate.canFetch {
                        // ⚠️ Says WHY rather than just being disabled.
                        Text("Not matched to a source yet — match them first.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(candidate.photoCount == 1 ? "1 photo" : "\(candidate.photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!candidate.canFetch || isRunning)
    }

    // MARK: - Work

    private func load() {
        guard let store = try? LibraryStore(at: libraryURL),
              let profiles = try? store.fetchAllEntityProfiles() else { return }
        candidates = ActorPhotoTopUp.worklist(profiles.filter { $0.type == "actor" },
                                              threshold: threshold)
        selected = selected.filter { id in candidates.contains { $0.id == id } }
    }

    private func run() {
        guard let provider else { return }
        let targets = candidates.filter { selected.contains($0.id) && $0.canFetch }
        isRunning = true
        progress = 0; toppedUp = 0; nothingNew = 0; failed = 0
        message = nil

        task = Task {
            for candidate in targets {
                if Task.isCancelled { break }
                await topUp(candidate, provider: provider)
                await MainActor.run { progress += 1 }
            }
            await MainActor.run {
                isRunning = false
                // ⭐ Reports all three outcomes. "42 done" hides that thirty of
                // them already had everything the source offers, which is the
                // number that says whether to bother running it again.
                message = "\(toppedUp) topped up · \(nothingNew) already complete"
                    + (failed > 0 ? " · \(failed) failed" : "")
                selected = []
                load()
            }
        }
    }

    private func topUp(_ candidate: ActorPhotoTopUp.Candidate,
                       provider: any ActorMetadataProvider) async {
        guard let sourceId = candidate.profile.enrichmentSourceId else { return }
        do {
            let proposal = try await provider.fetch(actorId: sourceId)
            let fetched = proposal.galleryURLs.value ?? []

            // 🚨 Re-read before writing. A long run against a library the
            // operator is also editing must not save a profile captured
            // minutes ago and discard what they did in between.
            let store = try LibrarySession.shared.store(forProfile: candidate.profile.id)
            let current = try store.fetchEntityProfile(for: candidate.profile.id)
                ?? candidate.profile

            guard let updated = ActorPhotoTopUp.applying(fetched, to: current) else {
                await MainActor.run { nothingNew += 1 }
                return
            }
            try store.saveEntityProfile(updated)
            await MainActor.run { toppedUp += 1 }
        } catch {
            await MainActor.run { failed += 1 }
        }
    }
}

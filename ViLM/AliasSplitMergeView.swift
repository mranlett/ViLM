// AliasSplitMergeView.swift
// Settings tool: one performer recorded as two profiles, reunited.
//
// 🚨 The cleanup for the credited-name inversion. The video plugin preferred
// the name a performer was CREDITED under in a scene over their canonical name,
// so someone who worked under three aliases became three profiles — each with
// part of a filmography, none with all of it.
//
// ⭐ The evidence is already in the data: the surviving profile lists the other
// one's name in its own aliases. This screen assembles that and hands it over.
//
// ⚠️ It never merges on its own, and there is deliberately no "merge all".
// A short alias can belong to more than one performer — the real library has
// one name listed as an alias of two different people — and a wrong merge
// fuses two careers into one profile, which no later tool can separate.

import SwiftUI
import LibraryCore

struct AliasSplitMergeView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let onRefresh: () -> Void

    @State private var candidates: [AliasSplitCandidate] = []
    @State private var isLoading = true
    @State private var isMerging = false
    @State private var merged = 0
    @State private var errorMessage: String?
    /// The merge awaiting confirmation: which profile goes, which survives.
    /// 🚨 NAMES, not ids. The merge is performed by `renameTagGlobally`, which
    /// matches `actor:Name` strings in `Asset.tags` — so handing it profile
    /// ids silently matched nothing. Before the re-key an id WAS `actor:Name`
    /// and this worked; afterwards it became a uid and the merge quietly
    /// stopped doing anything, while the dialog showed the uid to the operator.
    @State private var pending: (losing: String, surviving: String)?
    /// Candidates the operator has explicitly set aside this session.
    @State private var dismissed: Set<String> = []

    // MARK: - The visual evidence (#64)
    //
    // ⭐ Resolved HERE rather than carried on `AliasSplitCandidate.Claimant`,
    // which was the choice the issue recommended and the right one: the audit's
    // job is deciding WHICH pairs to offer, and what a face looks like has no
    // bearing on that. Putting photos in the finding would make a pure,
    // testable function depend on the photo store.
    //
    // ⚠️ Loaded in the SAME detached pass as the audit. A second read on the
    // main actor would stall the sheet on a 2,000-asset library.

    /// Each claimant's OWN films, by profile id, newest first.
    ///
    /// 🚨 Keyed by profile id and selected WITHOUT AKA folding — see
    /// `LibraryStore.videoIdsByPerformerProfile`. The obvious choice,
    /// `ActorKnownFor.build`, folds an alias into its owner, and on this screen
    /// that is exactly backwards: the two records being compared are an alias
    /// and its claimant, so folding would draw the same filmography under both
    /// and destroy the comparison the operator opened this screen to make.
    ///
    /// ⭐ It also comes from the same union as the video count printed beside
    /// the name, so the strip can never contradict that number.
    @State private var filmsByProfile: [String: [ActorKnownFor.VideoRef]] = [:]
    /// Profiles by id, for photos. Claimants carry an id; crediting carries a name.
    @State private var profilesById: [String: EntityProfile] = [:]
    /// Assets by id, so a `VideoRef` can become something showable.
    @State private var assetsById: [UUID: Asset] = [:]

    /// The video whose stills are open, and the profile whose gallery is.
    @State private var enlargedVideo: Asset?
    @State private var enlargedPhotoId: String?

    private var visible: [AliasSplitCandidate] {
        candidates.filter { !dismissed.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Duplicate Performers")
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
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage ?? "") }
                .confirmationDialog(
                    pending.map { "Merge \($0.losing) into \($0.surviving)?" } ?? "",
                    isPresented: Binding(get: { pending != nil },
                                         set: { if !$0 { pending = nil } }),
                    titleVisibility: .visible
                ) {
                    if let pending {
                        Button("Merge", role: .destructive) {
                            Task { await merge(losing: pending.losing, surviving: pending.surviving) }
                        }
                    }
                    Button("Cancel", role: .cancel) { pending = nil }
                } message: {
                    Text("Every video, photo and alias moves across. This cannot be undone, and two performers merged by mistake cannot be separated again.")
                }
                .task { await load() }
                // The video's own stills, exactly as Head to Head shows them —
                // tap a film, then page through its contact-sheet frames.
                .sheet(item: $enlargedVideo) { asset in
                    StillBrowser(asset: asset) { enlargedVideo = nil }
                }
                // Full screen on a phone, a sheet on the desktop — the rule
                // every other photo expansion in the app follows.
                .fullScreenCoverOnPhone(isPresented: Binding(
                    get: { enlargedPhotoId != nil },
                    set: { if !$0 { enlargedPhotoId = nil } }
                )) {
                    if let id = enlargedPhotoId, let profile = profilesById[id] {
                        FullScreenPhotoBrowser(
                            libraryURL: libraryURL,
                            entityId: id,
                            primaryPhotoUrl: profile.photoUrl,
                            identifiers: ["primary"] + profile.galleryUrls,
                            initialIdentifier: "primary",
                            onClose: { enlargedPhotoId = nil })
                    }
                }
        }
        .macFormSheet(minWidth: 620, minHeight: 540)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Looking for duplicates…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40)).foregroundStyle(.green)
                Text(merged > 0
                     ? "\(merged) performer\(merged == 1 ? "" : "s") merged."
                     : "No duplicate performers found.")
                    .font(.title3)
                Text("This looks for a profile whose name is recorded as an alias of a different profile — which is how one performer ends up filed as two.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    Text(headline).font(.callout)
                } footer: {
                    Text("Each of these is one profile whose name another profile lists as an alias. Merging keeps the name you choose; every video, photo and alias moves across.")
                }

                ForEach(visible) { candidate in
                    section(for: candidate)
                }
            }
        }
    }

    private var headline: String {
        let ambiguous = visible.filter(\.isAmbiguous).count
        let clear = visible.count - ambiguous
        if ambiguous == 0 {
            return "\(clear) likely duplicate\(clear == 1 ? "" : "s")."
        }
        if clear == 0 {
            return "\(ambiguous) name\(ambiguous == 1 ? "" : "s") claimed by more than one performer — each needs your judgement."
        }
        return "\(clear) likely duplicate\(clear == 1 ? "" : "s"), and \(ambiguous) claimed by more than one performer — those need your judgement."
    }

    @ViewBuilder
    private func section(for candidate: AliasSplitCandidate) -> some View {
        Section {
            row(candidate.alias, note: "listed as an alias elsewhere")

            ForEach(candidate.claimants) { claimant in
                row(claimant, note: "lists “\(candidate.alias.displayName)” as an alias")

                HStack {
                    Button("Keep \(claimant.displayName)") {
                        pending = (losing: candidate.alias.displayName,
                                   surviving: claimant.displayName)
                    }
                    .disabled(isMerging)
                    Spacer()
                    // ⚠️ Offered both ways. The profile listing the alias is
                    // usually the fuller record, but not always — the operator
                    // may have enriched the other one by hand.
                    Button("Keep \(candidate.alias.displayName)") {
                        pending = (losing: claimant.displayName,
                                   surviving: candidate.alias.displayName)
                    }
                    .disabled(isMerging)
                }
                .font(.caption)
            }

            Button("Not the same person") { dismissed.insert(candidate.id) }
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Image(systemName: candidate.isAmbiguous
                      ? "questionmark.circle" : "person.2")
                    .foregroundStyle(candidate.isAmbiguous ? .orange : .secondary)
                Text(candidate.alias.displayName)
                // ⭐ D2 is a RANKING, and a ranking nobody can see buys nothing.
                // The list is already ordered by evidence; this says why, so the
                // operator knows which rows are a fact and which are a guess.
                if candidate.evidence != .aliasOverlap {
                    Label(candidate.evidence == .both ? "confirmed" : "source merge",
                          systemImage: "arrow.triangle.merge")
                        .font(.caption2).labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                }
                Spacer()
                Text("\(candidate.combinedVideos) video\(candidate.combinedVideos == 1 ? "" : "s")")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } footer: {
            if candidate.isAmbiguous {
                // 🚨 The one case where being helpful would be harmful.
                Text("⚠️ \(candidate.claimants.count) performers list this name as an alias, so it cannot be a duplicate of all of them. Check the photos and dates before choosing — or leave it.")
            } else if candidate.upstreamSurvivorId != nil {
                // ⚠️ Says what the source did and what it did NOT do. An
                // upstream merge means the source decided two of ITS records
                // were one person; it does not decide that for these two local
                // profiles, so the operator still confirms (D1).
                Text(candidate.evidence == .both
                     ? "The source has already merged these two records, and the names overlap. Still worth a glance before you confirm."
                     : "The source has already merged these two records — the names do not overlap, so nothing else would have found this. Still worth a glance before you confirm.")
            }
        }
    }

    /// One claimant: face, name, the settling facts, and their filmography.
    ///
    /// 🚨 #64 — deciding *"are these two the same person?"* is a visual
    /// judgement, and this screen used to offer none of the visual evidence. It
    /// asked for an identification while withholding the two things an
    /// identification is actually made from, both of which the library already
    /// held. A birth year is far weaker evidence than a face and a filmography.
    @ViewBuilder
    private func row(_ claimant: AliasSplitCandidate.Claimant, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                face(for: claimant)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(claimant.displayName).fontWeight(.medium)
                        if claimant.isMatched {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        Spacer()
                        Text("\(claimant.videoCount) video\(claimant.videoCount == 1 ? "" : "s")")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    // The two facts that most often settle it: whether a lookup
                    // has confirmed the profile, and whether the birth years
                    // agree.
                    Text([note, claimant.birthYear.map { "born \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            videoStrip(for: claimant)
        }
    }

    /// The claimant's photo, tappable into their gallery.
    ///
    /// ⚠️ The chevron badge appears only when there IS more than one picture. A
    /// control that does nothing teaches the operator to ignore the control —
    /// the same rule the Head to Head card's gallery counter follows.
    @ViewBuilder
    private func face(for claimant: AliasSplitCandidate.Claimant) -> some View {
        let profile = profilesById[claimant.id]
        let galleryCount = 1 + (profile?.galleryUrls.count ?? 0)

        Button {
            enlargedPhotoId = claimant.id
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ProfileImageView(libraryURL: libraryURL,
                                 entityId: claimant.id,
                                 photoUrl: profile?.photoUrl) { image in
                    Color.clear.overlay(image.resizable().scaledToFill(), alignment: .top)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "person.fill")
                            .font(.system(size: 20)).foregroundStyle(.secondary))
                }
                .frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if galleryCount > 1 {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 8))
                        .padding(3)
                        .background(.thinMaterial, in: Circle())
                        .padding(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(profile == nil)
    }

    /// The films in YOUR library for this claimant, as stills.
    ///
    /// ⭐ Selected by PROFILE ID from the same union that produced the count
    /// beside the name, so the strip can never disagree with it. Re-selecting
    /// here by name would fork the rule and drift from it.
    @ViewBuilder
    private func videoStrip(for claimant: AliasSplitCandidate.Claimant) -> some View {
        let all = filmsByProfile[claimant.id] ?? []
        let shown = all.prefix(stripLimit)

        if !shown.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(shown), id: \.id) { ref in
                        if let asset = assetsById[ref.id] {
                            Button {
                                enlargedVideo = asset
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    VideoThumbnailView(
                                        asset: asset,
                                        libraryURL: LibrarySession.shared.url(for: asset.id))
                                        .frame(width: 80, height: 45)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                    Text(ref.title)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .frame(width: 80, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // ⚠️ Whatever is cut is COUNTED and said out loud. A strip
                    // that quietly stops reads as a performer with fewer videos
                    // than the line above it just claimed.
                    if all.count > stripLimit {
                        Text("+\(all.count - stripLimit)")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(height: 45)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ⚠️ Bounded, for the same reason Head to Head bounds its strip: a
    /// performer with two hundred videos would otherwise build two hundred
    /// thumbnail views inside a row the operator scrolls past in a second.
    private var stripLimit: Int { 12 }

    private func load() async {
        do {
            let url = libraryURL
            // ⚠️ ONE detached pass for the audit AND the evidence (#64). Two
            // passes would read the same 2,000 assets twice, and a second read
            // landing after the first would repaint the list under the
            // operator's finger.
            let loaded = try await Task.detached(priority: .userInitiated) {
                () -> (candidates: [AliasSplitCandidate],
                       films: [String: [ActorKnownFor.VideoRef]],
                       profiles: [String: EntityProfile],
                       assets: [UUID: Asset]) in
                let store = try LibraryStore(at: url)
                let found = try store.auditAliasSplits()
                let assets = try store.fetchAllAssets()
                let profiles = try store.fetchAllEntityProfiles()
                let assetsById = Dictionary(assets.map { ($0.id, $0) },
                                            uniquingKeysWith: { a, _ in a })

                // Only the profiles actually on screen — a library with 1,300
                // performers has a handful of candidates, and ordering the
                // other 1,290 filmographies would be work nobody looks at.
                let onScreen = Set(found.flatMap { [$0.alias.id] + $0.claimants.map(\.id) })
                let byProfile = try store.videoIdsByPerformerProfile()
                let films = byProfile
                    .filter { onScreen.contains($0.key) }
                    .mapValues { ids in
                        ActorKnownFor.refs(from: ids
                            .compactMap { UUID(uuidString: $0) }
                            .compactMap { assetsById[$0] })
                    }

                return (found, films,
                        Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                        assetsById)
            }.value
            await MainActor.run {
                self.candidates = loaded.candidates
                self.filmsByProfile = loaded.films
                self.profilesById = loaded.profiles
                self.assetsById = loaded.assets
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn't read the library: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    /// ⭐ The decision lives in `AliasMerge`, where it can be tested. Both
    /// halves of it shipped broken inside this view: it passed profile ids to
    /// a function that matches tag strings, and then discarded the result, so
    /// a rename that matched nothing counted as a merge.
    private func merge(losing: String, surviving: String) async {
        pending = nil
        isMerging = true
        let url = libraryURL
        let outcome = await Task.detached(priority: .userInitiated) {
            AliasMerge.perform(losing: losing, surviving: surviving, in: url)
        }.value

        if let message = outcome.message {
            errorMessage = message
        } else {
            merged += 1
            await load()
        }
        isMerging = false
    }
}

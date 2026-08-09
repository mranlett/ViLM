// ProfileGraphHeaderView.swift
// The header shown on an entity's profile page: collapsible related-links
// explorer (studios, co-actors, tags, series), the photo strip and
// full-screen pinch-zoomable photo browser, and the rename/edit/delete menu.

import SwiftUI
import LibraryCore

struct ProfileGraphHeaderView: View {
    let filteredAssets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let currentSelection: SidebarItem
    let libraryURL: URL?
    
    @State private var entityProfile: EntityProfile?
    @State private var tagVocabulary: [TagRecord] = []
    /// Loaded only for a studio page. `nil` means "not looked up yet"; an empty
    /// lineage means "looked, and nothing is recorded" — two different things,
    /// and the page says something different about each.
    @State private var studioLineage: StudioLineage?
    /// Networks this studio used to belong to. Empty for almost everything —
    /// nothing supplies acquisition dates yet, so this fills only where the
    /// operator has reassigned a parent by hand.
    @State private var formerParents: [StudioParentPeriod] = []
    @State private var isShowingEditor = false
    @State private var isShowingEnrichment = false
    @State private var sourceGapProfile: EntityProfile?
    @State private var isShowingScopedMatch = false
    @State private var isShowingRenameDialog = false
    @State private var selectedFullImageIdentifier: String? = nil
    @State private var newGlobalName = ""
    @State private var isExpanded: Bool

    init(filteredAssets: [Asset], sidebarSelection: Binding<Set<SidebarItem>>, currentSelection: SidebarItem, libraryURL: URL?) {
        self.filteredAssets = filteredAssets
        self._sidebarSelection = sidebarSelection
        self.currentSelection = currentSelection
        self.libraryURL = libraryURL
        // A series graph is purely a jumping-off point (no photo/bio), so it
        // defaults closed. Actor/studio profiles carry a photo and bio worth
        // showing, so they default open.
        let isSeries: Bool = { if case .series = currentSelection { return true }; return false }()
        _isExpanded = State(initialValue: !isSeries)
    }
    
    private var relatedStudios: [String] {
        let studios = filteredAssets.flatMap { $0.studios }
        return uniqueEntities(from: studios, excluding: currentSelectionName(for: "studio"))
    }
    
    private var relatedActors: [String] {
        let actors = filteredAssets.flatMap { $0.actors }
        return uniqueEntities(from: actors, excluding: currentSelectionName(for: "actor"))
    }
    
    private var relatedTags: [String] {
        let tags = filteredAssets.flatMap { $0.actions }
        return uniqueEntities(from: tags, excluding: currentSelectionName(for: "tag"))
    }
    
    private var relatedSeries: [String] {
        let series = filteredAssets.compactMap { $0.videoName }.filter { !$0.isEmpty }
        return uniqueEntities(from: series, excluding: currentSelectionName(for: "series"))
    }
    
    /// Whether this page is about a company rather than a person.
    ///
    /// Studios reused the actor layout wholesale, so a studio page showed a
    /// gender, a hair colour, a birth date and a career span — four fields that
    /// describe a person and nothing else — and said nothing about the one
    /// relationship a studio actually has.
    private var isStudio: Bool {
        switch currentSelection {
        case .studio, .studioFamily: return true
        default: return false
        }
    }

    /// Whether the page is currently showing the imprints' videos too.
    private var isShowingFamily: Bool {
        if case .studioFamily = currentSelection { return true }
        return false
    }

    /// Best-effort, and only needed when the page is a studio.
    ///
    /// ⚠️ Failure is silent and leaves an EMPTY lineage rather than `nil`. The
    /// page distinguishes "not loaded" from "nothing recorded", and a failed
    /// read that stayed `nil` would leave the block invisible instead of saying
    /// there is no network yet.
    private func fetchStudioLineage() {
        guard isStudio, let libraryURL, let id = currentEntityId else {
            studioLineage = nil
            formerParents = []
            return
        }
        let store = try? LibraryStore(at: libraryURL)
        studioLineage = (try? store?.studioLineage(for: id))
            ?? StudioLineage(parent: nil, siblings: [], children: [])
        formerParents = ((try? store?.studioParentHistory(of: id)) ?? [])?
            .filter { !$0.isCurrent } ?? []
    }

    /// Best-effort, and only needed when the page is a tag. An empty vocabulary
    /// simply means the tag reads as "Not yet classified", which is true.
    private func fetchTagVocabulary() {
        guard case .tag = currentSelection, let libraryURL else {
            tagVocabulary = []
            return
        }
        tagVocabulary = (try? LibraryStore(at: libraryURL).fetchTagVocabulary()) ?? []
    }

    /// What this page should say about a tag, when the page IS a tag.
    ///
    /// Read from the vocabulary rather than recomputed here, so the profile
    /// page, the gallery card and the classification worklist cannot disagree
    /// about what a tag is called or what it describes.
    struct TagDetail {
        let kindLabel: String
        let isClassified: Bool
        let uses: Int
        let otherSpellings: [String]
    }

    private var tagDetail: TagDetail? {
        guard case .tag(let name) = currentSelection else { return nil }

        let key = TagNormalizer.identityKey(name)
        let record = tagVocabulary.first { $0.identityKey == key }

        let spellings = Set(filteredAssets.flatMap { $0.actions }
            .filter { TagNormalizer.identityKey($0) == key })

        let label: String
        switch record?.resolvedKind() {
        case .some(let kind) where kind == .action:             label = "Action in a video"
        case .some(let kind) where kind == .videoAttribute:     label = "About the video"
        case .some(let kind) where kind == .performerAttribute: label = "About a performer"
        case .some(let kind):                                   label = kind.name
        case .none:                                             label = "Not yet classified"
        }

        return TagDetail(
            kindLabel: label,
            isClassified: record?.kind != nil,
            uses: filteredAssets.count,
            otherSpellings: spellings
                .filter { $0 != (record?.displayName ?? name) }
                .sorted())
    }

    private func currentSelectionName(for type: String) -> String? {
        switch currentSelection {
        case .studio(let name) where type == "studio": return name
        case .actor(let name) where type == "actor": return name
        case .tag(let name) where type == "tag": return name
        case .series(let name) where type == "series": return name
        default: return nil
        }
    }
    
    private var currentName: String? {
        switch currentSelection {
        case .actor(let name): return name
        // Both cases are the same studio — only the videos below differ — so
        // the identity block, lineage and edit menu must behave identically.
        case .studio(let name), .studioFamily(let name): return name
        case .tag(let name): return name
        case .series(let name): return name
        default: return nil
        }
    }
    
    private func uniqueEntities(from list: [String], excluding: String?) -> [String] {
        var set = Set(list)
        if let excluding = excluding {
            set.remove(excluding)
        }
        return Array(set).sorted()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Explore Related Links")
                                .font(.headline)
                            Text(exploreSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Menu {
                    if let name = currentName {
                        Button {
                            newGlobalName = name
                            isShowingRenameDialog = true
                        } label: {
                            Label("Rename Globally", systemImage: "pencil")
                        }
                    }
                    
                    if isEditableEntity {
                        Button {
                            isShowingEditor = true
                        } label: {
                            Label("Edit Profile", systemImage: "person.text.rectangle")
                        }

                        // Matching lives beside the other actions on the record,
                        // the way the video page puts "Match with …" in its own
                        // ellipsis menu rather than inside its edit sheet.
                        //
                        // Labelled with the source's own name — this file must
                        // not know which sources exist.
                        if !isStudio, let provider = installedActorProvider {
                            Button {
                                isShowingEnrichment = true
                            } label: {
                                Label("Match with \(provider.displayName)",
                                      systemImage: "sparkle.magnifyingglass")
                            }

                            // ⭐ The spec's D2 entry point, and the obvious
                            // place for it: the operator is already looking at
                            // this performer. It first shipped as a context
                            // menu on the grid card, which on iOS means a
                            // long-press nobody discovers.
                            //
                            // ⚠️ Only when the record carries a source id.
                            // Offering it otherwise buys a request that can
                            // only fail, and a failure the operator cannot act
                            // on reads as the feature being broken.
                            if let id = currentEntityId,
                               let profile = ownerRawProfile(for: id),
                               !(profile.enrichmentSourceId ?? "").isEmpty {
                                Button {
                                    sourceGapProfile = profile
                                } label: {
                                    Label("What else are they in?",
                                          systemImage: "questionmark.folder")
                                }
                            }
                        }

                        // The whole-library run, narrowed to what this page is
                        // showing. Matching two thousand videos to fix one
                        // studio's forty is most of an hour of rate-limited
                        // requests to do a minute of work.
                        //
                        // ⚠️ Scoped to `filteredAssets` — the videos ON SCREEN,
                        // not every video this entity has. If a filter is
                        // narrowing the page, the run follows it, which is why
                        // the label states the count rather than the entity.
                        if hasVideoProvider, !filteredAssets.isEmpty {
                            Button {
                                isShowingScopedMatch = true
                            } label: {
                                Label("Match These \(filteredAssets.count) Videos",
                                      systemImage: "sparkles.rectangle.stack")
                            }
                        }
                        
                        if filteredAssets.count == 0 && entityProfile != nil {
                            Divider()
                            Button(role: .destructive) {
                                deleteProfile()
                            } label: {
                                Label("Delete Profile", systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }

            if isExpanded {
            // A tag has no EntityProfile — no bio, no photo — so its page had
            // nothing but related links. It does have a vocabulary record, and
            // what a tag DESCRIBES is the most important thing about it.
            if let tagDetail {
                HStack(spacing: 8) {
                    Text(tagDetail.kindLabel)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tagDetail.isClassified
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.orange.opacity(0.18),
                                    in: Capsule())
                        .foregroundStyle(tagDetail.isClassified ? Color.accentColor : .orange)

                    Text("\(tagDetail.uses) video\(tagDetail.uses == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !tagDetail.otherSpellings.isEmpty {
                        Text("also spelled \(tagDetail.otherSpellings.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Whether this studio has been confirmed against a source.
            //
            // It belongs here rather than only in the gallery because it is not
            // decoration: an unconfirmed studio cannot break the tie when a
            // video offers both an imprint and its network (StudioResolution),
            // and only a confirmed one may drive a folder name.
            if isStudio, let profile = entityProfile {
                let confirmed = profile.enrichmentState == .matched
                HStack(spacing: 8) {
                    Label(confirmed ? "Confirmed" : "Not yet confirmed",
                          systemImage: confirmed ? "checkmark.seal.fill" : "questionmark.circle")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(confirmed
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.orange.opacity(0.18),
                                    in: Capsule())
                        .foregroundStyle(confirmed ? Color.accentColor : .orange)

                    if confirmed, let source = profile.enrichmentSource {
                        Text("via \(source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let profile = entityProfile, !profile.akas.isEmpty {
                Text("AKA: \(profile.akas.joined(separator: ", "))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let profile = entityProfile {
                HStack(alignment: .top, spacing: 16) {
                    Button(action: {
                        selectedFullImageIdentifier = "primary"
                    }) {
                        ProfileImageView(libraryURL: libraryURL, entityId: currentEntityId ?? "unknown", photoUrl: profile.photoUrl, isGallery: false) { image in
                            Color.clear
                                .overlay(
                                    image
                                        .resizable()
                                        // ⚠️ Fit, not fill, for a studio. A
                                        // portrait fills a square well because
                                        // a face is centred in it; a wordmark
                                        // is wide, and filling crops it to the
                                        // middle few letters.
                                        .aspectRatio(contentMode: isStudio ? .fit : .fill),
                                    alignment: isStudio ? .center : .top
                                )
                        } placeholder: {
                            ZStack {
                                portraitShape.fill(Color.secondary.opacity(0.2))
                                Image(systemName: isStudio ? "building.2.fill" : "person.fill")
                                    .font(.system(size: 40)).foregroundColor(.secondary)
                                if profile.photoUrl != nil {
                                    ProgressView()
                                }
                            }
                        }
                        .frame(width: 80, height: 80)
                        // A logo is a wordmark, not a face. Circle-cropping one
                        // clips the ends off the name it consists of.
                        .contentShape(portraitShape)
                        .clipShape(portraitShape)
                    }
                    .buttonStyle(.plain)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if let bio = profile.bio {
                            Text(bio).font(.body)
                        }
                        
                        if let rating = profile.rating, rating > 0 {
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { star in
                                    Image(systemName: star <= rating ? "star.fill" : "star")
                                        .font(.caption)
                                        .foregroundColor(.yellow)
                                }
                            }
                            .accessibilityLabel("Rated \(rating) of 5 stars")
                        }

                        // ⚠️ Every one of these describes a PERSON, so a studio
                        // gets none of them. `EntityProfile` is one record for
                        // both, and a company that has somehow acquired a hair
                        // colour should not advertise it.
                        //
                        // Country is the exception worth keeping: a studio has
                        // one, and it means the same thing.
                        let metadataStrings: [String] = (isStudio ? [
                            profile.countryOfOrigin.map { "Country: \($0)" }
                        ] : [
                            profile.gender.map { "Gender: \($0)" },
                            profile.hairColor.map { "Hair Color: \($0)" },
                            // resolvedBirthYear rather than birthYear: a record
                            // that carries only a full date still shows a year.
                            profile.resolvedBirthYear.map { "Birth Year: \($0)" },
                            profile.countryOfOrigin.map { "Country: \($0)" }
                        ]).compactMap { $0 }

                        if !metadataStrings.isEmpty {
                            Text(metadataStrings.joined(separator: " • "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // ⚠️ Their own lines, WITH the date they were checked.
                        //
                        // Free text that can run long, so joining the bulleted
                        // list above would swamp it. And they are the one thing
                        // here that goes stale on its own — a piercing comes
                        // out, a tattoo is covered — so they are shown as of
                        // when the profile was last looked up rather than as a
                        // standing fact about a person. `marksAsOf` pairs them
                        // with that date precisely so no caller can forget.
                        if !isStudio, let marks = profile.marksAsOf {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(marks.marks, id: \.0) { label, value in
                                    Text("\(label): \(value)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let checked = marks.checked {
                                    Text("as recorded \(checked.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        // Career span gets its own line rather than joining the
                        // bulleted list: it is a sentence, not a field, and it
                        // would crowd the line out on a phone.
                        //
                        // Every part of it is computed from stored years, so the
                        // "years active" figure moves on its own each year
                        // instead of going stale.
                        //
                        // ⚠️ Never for a studio: it reads "aged 24 at career
                        // start" off fields that describe a person.
                        if !isStudio, let career = profile.careerDisplay {
                            Label(career, systemImage: "calendar")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Career: \(career)")
                        }

                    }
                }
            }

            // Links get a full-width section of their own rather than a line in
            // the identity block: a record can carry a dozen of them, and they
            // need room to wrap. The home page joins them instead of keeping a
            // separate "Visit Website" line, so there is one place to look.
            if let profile = entityProfile {
                EntityLinksView(links: displayLinks(for: profile))
            }

            if let profile = entityProfile, !profile.tags.isEmpty {
                tagSection(title: "Profile Tags", items: profile.tags, color: .accentColor) { item in
                    .tag(item)
                }
            }
            
            if let profile = entityProfile, !galleryOnlyTokens(for: profile).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photo Gallery").font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(galleryOnlyTokens(for: profile), id: \.self) { url in
                                Button(action: {
                                    selectedFullImageIdentifier = url
                                }) {
                                    ProfileImageView(libraryURL: libraryURL, entityId: currentEntityId ?? "unknown", photoUrl: url, isGallery: url != profile.photoUrl) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ZStack {
                                            Rectangle().fill(Color.secondary.opacity(0.2))
                                            ProgressView()
                                        }
                                    }
                                    .frame(width: 80, height: 80)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            
            if isStudio {
                studioLineageSection
            }

            // ⚠️ Not on a studio page. There it listed studios CO-OCCURRING on
            // the same videos, which after Fix Duplicate Studios is very nearly
            // a definition of the two-studio defect — so it presented a data
            // error as a relationship. Lineage above is the real answer.
            if !isStudio, !relatedStudios.isEmpty {
                tagSection(title: "Studios", items: relatedStudios, color: .purple) { item in
                    .studio(item)
                }
            }
            if !relatedActors.isEmpty {
                // "Co-Actors" is true on an actor page and wrong on a studio
                // page: these people are not the studio's co-anything.
                tagSection(title: isStudio ? "Actors" : "Co-Actors",
                           items: relatedActors, color: .blue) { item in
                    .actor(item)
                }
            }
            if !relatedTags.isEmpty {
                tagSection(title: "Tags", items: relatedTags, color: .green) { item in
                    .tag(item)
                }
            }
            if !relatedSeries.isEmpty {
                tagSection(title: "Video Series", items: relatedSeries, color: .orange, isAdditive: true) { item in
                    .series(item)
                }
            }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
        .onAppear { fetchProfile() }
        .onChange(of: currentSelection) { old, new in fetchProfile() }
        // ⚠️ Match All Studios writes `studio_parent` and posts this. Without
        // it, a studio page open at the time keeps saying "no network recorded
        // yet" after the run that recorded one — which is exactly the message
        // the empty state exists to avoid being wrong about.
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name("ReloadAssets"))) { _ in fetchProfile() }
        .sheet(isPresented: $isShowingEditor) {
            if let id = currentEntityId {
                EntityProfileEditorView(libraryURL: libraryURL, entityId: id, profile: ownerRawProfile(for: id), onSave: saveProfile)
            }
        }
        .sheet(isPresented: $isShowingScopedMatch) {
            // Every open library, like the Settings run — the scope is the set
            // of asset ids, and those already identify which library each video
            // lives in once the crawl finds it.
            let urls = LibrarySession.shared.allURLs
            if !urls.isEmpty {
                VideoBatchMatchView(libraryURLs: urls, scope: scopedMatchScope) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ReloadAssets"), object: nil)
                }
            }
        }
        .sheet(item: $sourceGapProfile) { profile in
            SourceGapView(performers: [profile], allProfiles: [profile],
                          libraryURL: LibrarySession.shared.url(forProfile: profile.id)
                              ?? libraryURL)
        }
        .sheet(isPresented: $isShowingEnrichment) {
            if let provider = installedActorProvider, let id = currentEntityId,
               let name = currentName {
                ActorEnrichmentSheet(
                    provider: provider,
                    entityId: id,
                    actorName: name,
                    // The OWNING library's raw copy, not the merged view: the
                    // merged one carries other libraries' fields, and saving it
                    // back would copy them into the owner as if they had been
                    // entered there.
                    currentProfile: ownerRawProfile(for: id),
                    libraryURL: libraryURL,
                    onApply: { merged, renameTo in
                        // ⚠️ Save BEFORE renaming. The rename rewrites this
                        // record's identity, so writing afterwards would target
                        // a row that has just moved.
                        saveProfile(merged)
                        // 🚨 The match EDGE, not only the columns.
                        //
                        // This site set `enrichmentSourceId` by hand and never
                        // recorded the edge — so an actor matched here stayed
                        // on the Missing Identities worklist no matter how many
                        // times it was re-matched. And Missing Identities sends
                        // the operator to exactly this screen: "open one and use
                        // Match Again on its profile."
                        //
                        // ⚠️ `confirmEntityMatch` exists precisely so the two
                        // cannot drift, and its own comment says why — "every
                        // call site that set enrichmentSourceId by hand is a
                        // site that could forget the edge." This was that site.
                        // Reported from the device 2026-08-08.
                        recordIdentityEdge(for: merged, provider: provider)
                        if let renameTo, !renameTo.isEmpty, renameTo != name {
                            newGlobalName = renameTo
                            performGlobalRename()
                        }
                    }
                )
            }
        }
        .alert("Rename Globally", isPresented: $isShowingRenameDialog) {
            TextField("New Name", text: $newGlobalName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { performGlobalRename() }
        } message: {
            Text("This will rename the entity across all videos in your library.")
        }
        .sheet(isPresented: Binding(
            get: { selectedFullImageIdentifier != nil },
            set: { if !$0 { selectedFullImageIdentifier = nil } }
        )) {
            if let profile = entityProfile {
                let allImageIdentifiers = ["primary"] + galleryOnlyTokens(for: profile)

                FullScreenPhotoBrowser(
                    libraryURL: libraryURL,
                    entityId: currentEntityId ?? "unknown",
                    primaryPhotoUrl: profile.photoUrl,
                    identifiers: allImageIdentifiers,
                    initialIdentifier: selectedFullImageIdentifier ?? "primary",
                    onClose: { selectedFullImageIdentifier = nil }
                )
                .presentationDetents([.large])
            }
        }
    }
    
    /// The one relationship a studio genuinely owns: who owns it, what it owns,
    /// and what else its network owns.
    ///
    /// ⚠️ Degrades to a sentence rather than an empty box. `studio_parent`
    /// starts unpopulated, so "nothing recorded" is the common state, and three
    /// blank groups would read as a broken page instead of an unfinished
    /// library.
    @ViewBuilder
    private var studioLineageSection: some View {
        if let lineage = studioLineage {
            if lineage.isEmpty {
                Label("No network recorded yet — Match All Studios can find it.",
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let parent = lineage.parent {
                        lineageRow(title: "Part of", relatives: [parent], color: .purple)
                    }
                    // Former owners, where any are recorded. A company's
                    // ownership history is a real fact about it and was
                    // unrepresentable before the hierarchy gained a lifetime.
                    if !formerParents.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Previously").font(.subheadline)
                                .foregroundColor(.secondary).fontWeight(.medium)
                            ForEach(formerParents) { period in
                                Text(period.displayText)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !lineage.children.isEmpty {
                        lineageRow(title: "Imprints", relatives: lineage.children, color: .purple)
                        includeImprintsToggle(lineage)
                    }
                    if !lineage.siblings.isEmpty {
                        lineageRow(title: "Alongside", relatives: lineage.siblings, color: .purple)
                    }
                }
            }
        }
    }

    /// Switches the grid below between this studio's own releases and the whole
    /// family's, split by imprint.
    ///
    /// ⚠️ Shown only when the studio actually has imprints. On a leaf imprint
    /// it would be a control that visibly does nothing, and the lineage block
    /// is where the operator has just been told there are none.
    ///
    /// Flips the pinned selection rather than filtering here: the grid owns
    /// what it shows, and this view only says which question to ask.
    @ViewBuilder
    private func includeImprintsToggle(_ lineage: StudioLineage) -> some View {
        if let name = currentName {
            let total = lineage.children.reduce(0) { $0 + $1.videoCount }
            Toggle(isOn: Binding(
                get: { isShowingFamily },
                set: { on in
                    sidebarSelection = [on ? .studioFamily(name) : .studio(name)]
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Include imprints")
                        .font(.subheadline)
                    Text("\(total) more video\(total == 1 ? "" : "s") across \(lineage.children.count) imprint\(lineage.children.count == 1 ? "" : "s"), grouped separately below")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.top, 2)
        }
    }

    /// A lineage row. Each entry carries its video count, because a bare list
    /// of company names is trivia — the count is what makes it worth a tap.
    private func lineageRow(title: String,
                            relatives: [StudioLineage.Relative],
                            color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
            FlowLayout(spacing: 6) {
                ForEach(relatives) { relative in
                    let label = "\(relative.name) · \(relative.videoCount)"
                    #if os(iOS)
                    TagBubble(label: label, color: color,
                              navRoute: .entityProfile(category: "studio",
                                                       name: relative.name))
                    #else
                    TagBubble(label: label, color: color, onPivot: {
                        sidebarSelection = [.studio(relative.name)]
                    })
                    #endif
                }
            }
        }
    }

    /// The installed actor source, if any.
    ///
    /// `installed` is the only list the enrichment UI may consult — an
    /// available but uninstalled plugin must have no affordance anywhere (D3).
    private var installedActorProvider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installed
            .compactMap { $0 as? any ActorMetadataProvider }
            .first
    }

    /// Whether a scoped video run could do anything. Same rule as everywhere
    /// else — an available but uninstalled plugin gets no affordance (D3).
    private var hasVideoProvider: Bool {
        !PluginEnvironment.registry.installedVideoProviders().isEmpty
    }

    /// What this page is showing, as a run scope.
    ///
    /// The label names the entity as well as the count, because the run screen
    /// is otherwise identical to the whole-library one and there would be
    /// nothing on it saying which forty videos it meant.
    private var scopedMatchScope: VideoBatchMatchModel.Scope {
        VideoBatchMatchModel.Scope(
            label: "Matching the \(filteredAssets.count) video\(filteredAssets.count == 1 ? "" : "s") shown for \(currentName ?? "this page").",
            assetIDs: Set(filteredAssets.map(\.id)))
    }

    /// Circle for a face, rounded rectangle for a logo.
    private var portraitShape: AnyShape {
        isStudio ? AnyShape(RoundedRectangle(cornerRadius: 10)) : AnyShape(Circle())
    }

    struct IdentifiableString: Identifiable {
        let id: String
    }

    // Gallery entries that are actually *additional* photos. Tokens equal to
    // the primary URL, and the local://primary placeholder, both resolve to
    // the primary photo file — listing them alongside the header photo (or
    // as extra pages in the full-screen browser) showed the primary twice.
    private func galleryOnlyTokens(for profile: EntityProfile) -> [String] {
        profile.galleryUrls.filter {
            $0 != profile.photoUrl && $0 != ProfileImageNaming.localPrimaryToken
        }
    }

    // MARK: - Full Screen Photo Browser

    /// Full-screen photo viewer with endless wrap-around swiping.
    private struct FullScreenPhotoBrowser: View {
        let libraryURL: URL?
        let entityId: String
        let primaryPhotoUrl: String?
        let identifiers: [String]      // "primary" + gallery URLs
        let initialIdentifier: String
        let onClose: () -> Void

        @State private var index: Int = 0
        // Full-size images preloaded up front and keyed by identifier, so the
        // pager's neighbouring pages render their photo as they slide in
        // instead of showing the black background until they become active.
        @State private var images: [String: Image] = [:]

        var body: some View {
            NavigationStack {
                WrappingPhotoPager(count: identifiers.count, index: $index) { i in
                    photoPage(for: identifiers[i])
                }
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(identifiers.count > 1 ? "\(index + 1) of \(identifiers.count)" : "")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onClose() }
                    }
                }
                .onAppear {
                    index = identifiers.firstIndex(of: initialIdentifier) ?? 0
                }
                .task { await preloadImages() }
            }
            // Larger than the shared default because this is the one sheet
            // whose entire purpose is looking at a photograph — sizing it like
            // a settings pane would defeat the point of opening it.
            .macSheet(minWidth: 900, minHeight: 700)
        }

        @ViewBuilder
        private func photoPage(for identifier: String) -> some View {
            ZoomablePhoto {
                if let image = images[identifier] {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Fallback for anything not yet on disk (e.g. a gallery URL not
                    // downloaded yet); ProfileImageView will fetch it.
                    let isGallery = identifier != "primary" && identifier != primaryPhotoUrl
                    let photoUrl = identifier == "primary" ? primaryPhotoUrl : identifier
                    ProfileImageView(libraryURL: libraryURL, entityId: entityId, photoUrl: photoUrl, isGallery: isGallery) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Fresh zoom state per photo — otherwise the pager's fixed three
            // HStack slots would carry over a stale scale as `index` changes
            // which photo occupies a given slot.
            .id(identifier)
        }

        // Resolves the on-disk file for an identifier (no I/O), matching the
        // naming scheme ProfileImageView writes with.
        private func fileURL(for identifier: String) -> URL? {
            guard let libraryURL else { return nil }
            let dir = libraryURL.appendingPathComponent(".catalog/profiles")
            let isGallery = identifier != "primary" && identifier != primaryPhotoUrl
            let fileName = ProfileImageNaming.fileName(for: entityId, token: identifier, isGallery: isGallery)
            return dir.appendingPathComponent(fileName)
        }

        private func preloadImages() async {
            // Load the initially-shown photo first so it appears fastest, then
            // the rest so neighbours are ready before the first swipe.
            let start = identifiers.firstIndex(of: initialIdentifier) ?? 0
            let ordered = (0..<identifiers.count).map { identifiers[(start + $0) % identifiers.count] }
            for identifier in ordered {
                if images[identifier] != nil { continue }
                guard let url = fileURL(for: identifier),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                // Decode off the main thread, but build the SwiftUI Image on the
                // main actor (its initializer is main-actor isolated).
                let platformImage = await Task.detached { () -> PlatformImage? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return PlatformImage(data: data)
                }.value
                if let platformImage { images[identifier] = Image(platformImage: platformImage) }
            }
        }
    }

    
    // Framed as an invitation to explore, not a set of active filters.
    private var exploreSubtitle: String {
        // A studio page no longer lists other studios — it lists its network
        // and its imprints — so promising "studios" here would describe a
        // section that is deliberately not there.
        let kinds = isStudio ? "Network, imprints, actors, and tags"
                             : "Actors, studios, and tags"
        if let name = currentName, !name.isEmpty {
            return "\(kinds) connected to \(name)"
        }
        return kinds
    }
    
    /// The id to edit, photograph and rename through.
    ///
    /// ⭐ Prefers the LOADED profile's own id. The name-form fallback below is
    /// for the first frame and for a selection with no profile row yet — after
    /// the re-key it names nothing, and this id reaches `ProfileImageView`
    /// (whose filenames follow the id) and the rename and edit paths.
    private var currentEntityId: String? {
        if let loaded = entityProfile?.id { return loaded }
        return nameFormEntityId
    }

    private var nameFormEntityId: String? {
        switch currentSelection {
        case .actor(let name): return "actor:\(name)"
        case .studio(let name), .studioFamily(let name): return "studio:\(name)"
        case .tag(let name): return "tag:\(name)"
        case .series(let name): return "series:\(name)"
        default: return nil
        }
    }
    
    private var isEditableEntity: Bool {
        switch currentSelection {
        case .actor, .studio, .studioFamily: return true
        default: return false
        }
    }
    
    private func fetchProfile() {
        fetchTagVocabulary()
        fetchStudioLineage()
        guard libraryURL != nil, let id = currentEntityId else { return }
        do {
            // DISPLAY is the merged view across every open library that has
            // this profile (higher precedence wins, lists union) — an actor
            // whose rating lives only in an attachment must still show it.
            var layers: [[String: EntityProfile]] = []
            for libURL in LibrarySession.shared.allURLs {
                if let profile = try LibraryStore(at: libURL).fetchEntityProfile(for: id) {
                    layers.append([id: profile])
                }
            }
            entityProfile = MergeSemantics.mergedProfileView(ordered: layers)[id]
        } catch {
            print("Failed to fetch profile: \(error)")
        }
    }

    /// The OWNING library's raw copy, for the edit sheet. Never hand the
    /// merged view to an editor: saving merged form state wholesale would
    /// copy other libraries' fields into the owner — an accidental merge.
    private func ownerRawProfile(for id: String) -> EntityProfile? {
        (try? LibrarySession.shared.store(forProfile: id).fetchEntityProfile(for: id)) ?? nil
    }

    /// Records WHICH external record this profile is, as a graph edge.
    ///
    /// 🚨 Without this the profile carries `enrichmentState = .matched` and a
    /// source id in a column, and the graph holds no edge — which is precisely
    /// the state Missing Identities reports and cannot be cleared by any amount
    /// of re-matching.
    ///
    /// ⚠️ Silent when the source supplied no id. A match with nothing to look
    /// up by is exactly what this project spent a day discovering it had 1,287
    /// of; recording an edge with an empty id would hide them again rather than
    /// leaving them findable.
    private func recordIdentityEdge(for profile: EntityProfile,
                                    provider: (any ActorMetadataProvider)?) {
        do {
            let store = try LibrarySession.shared.store(forProfile: profile.id)
            // ⭐ The one entry point. `.operator` — a person looked at a list
            // and chose, which is a different kind of trust from a name search
            // and the only method besides a fingerprint that propagates
            // identity.
            _ = try store.applyReviewedMatch(profile, source: provider?.displayName)
        } catch {
            AppErrorReporter.report(
                "Matched, but couldn't record which record it matched: \(error.localizedDescription)")
        }
    }

    private func saveProfile(_ profile: EntityProfile) {
        guard libraryURL != nil else { return }
        do {
            // Writes land in the profile's owning library only.
            let store = try LibrarySession.shared.store(forProfile: profile.id)
            try store.saveEntityProfile(profile)
            self.entityProfile = profile
            // "ReloadAssets" is this app's general "library data changed"
            // signal — every view sharing the centralized profile cache
            // listens for it, not just asset lists.
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            print("Failed to save profile: \(error)")
            AppErrorReporter.report("Couldn't save the profile: \(error.localizedDescription)")
        }
    }

    private func deleteProfile() {
        guard libraryURL != nil, let id = currentEntityId else { return }
        do {
            let store = try LibrarySession.shared.store(forProfile: id)
            try store.deleteEntityProfile(for: id)
            self.entityProfile = nil
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)

            // Navigate back to the appropriate gallery
            let parts = id.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return }
            let category = String(parts[0])
            if category == "actor" {
                sidebarSelection = [.actorGallery]
            } else if category == "tag" {
                sidebarSelection = [.tagGallery]
            } else {
                sidebarSelection = [.allAssets]
            }
        } catch {
            print("Failed to delete profile: \(error)")
            AppErrorReporter.report("Couldn't delete the profile: \(error.localizedDescription)")
        }
    }
    
    private func performGlobalRename() {
        guard let url = libraryURL, let id = currentEntityId, !newGlobalName.isEmpty else { return }
        
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let category = String(parts[0])
        let newTag = "\(category):\(newGlobalName)"
        let normalizedNewName = TagNormalizer.normalize(tagValue: newGlobalName)
        
        do {
            // A global rename applies to EVERY open library: the user sees
            // one tag space, and renaming in only one would leave the union
            // showing old and new names side by side. Each library runs its
            // own hardened files-first rename; nothing crosses libraries.
            _ = url
            for libURL in LibrarySession.shared.allURLs {
                let store = try LibraryStore(at: libURL)
                try store.renameTagGlobally(oldTag: id, newTag: newTag)
            }

            var pivotItem: SidebarItem
            switch category {
            case "actor": pivotItem = .actor(normalizedNewName)
            case "studio": pivotItem = .studio(normalizedNewName)
            default: pivotItem = .tag(normalizedNewName)
            }
            sidebarSelection = [pivotItem]
            
            fetchProfile()
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            print("Failed to rename globally: \(error)")
            AppErrorReporter.report("Couldn't rename across the library: \(error.localizedDescription)")
        }
    }
    
    private func route(for item: SidebarItem, fallbackName: String) -> AppRoute {
        switch item {
        case .actor(let name): return .entityProfile(category: "actor", name: name)
        case .studio(let name): return .entityProfile(category: "studio", name: name)
        case .tag(let name): return .entityProfile(category: "tag", name: name)
        case .series(let name): return .entityProfile(category: "series", name: name)
        default: return .entityProfile(category: "unknown", name: fallbackName)
        }
    }
    
    /// The home page ahead of imported links.
    ///
    /// The home page is the one the operator typed, so it leads. It carries an
    /// explicit label because `displayLabel` would otherwise fall back to the
    /// bare host, which reads as an accident next to named links.
    ///
    /// `EntityLinksView` de-duplicates by URL, so a home page that an importer
    /// also supplied appears once, under this label.
    private func displayLinks(for profile: EntityProfile) -> [EntityLink] {
        let trimmed = profile.homePage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return profile.links }
        return [EntityLink(url: trimmed, label: "Home Page")] + profile.links
    }

    private func tagSection(title: String, items: [String], color: Color, isAdditive: Bool = false, itemType: @escaping (String) -> SidebarItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    let sidebarItem = itemType(item)
                    
                    #if os(iOS)
                    TagBubble(label: item, color: color, navRoute: route(for: sidebarItem, fallbackName: item))
                    #else
                    TagBubble(label: item, color: color, onPivot: {
                        if isAdditive {
                            sidebarSelection.insert(sidebarItem)
                        } else {
                            sidebarSelection = [sidebarItem]
                        }
                    })
                    #endif
                }
            }
        }
    }
}

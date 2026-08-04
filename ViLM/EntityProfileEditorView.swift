// EntityProfileEditorView.swift
// The Edit Bio form for an actor/studio profile: photo gallery management
// (add by URL, choose primary, delete), bio, home page, demographics, tags,
// and AKAs. Persistence is the caller's job via onSave; photo downloads are
// validated before they touch disk.

import SwiftUI
import LibraryCore
import CryptoKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension View {
    @ViewBuilder
    func popoverFrame() -> some View {
        #if os(macOS)
        self.frame(width: 250, height: 120, alignment: .top)
        #else
        self.frame(minWidth: 200, maxWidth: 300)
        #endif
    }
}

struct EntityProfileEditorView: View {
    let libraryURL: URL?
    let entityId: String
    let initialProfile: EntityProfile?
    // True when presented as a sheet (needs its own stack for the toolbar);
    // false when pushed inside an existing NavigationStack — nesting stacks
    // breaks links and toolbars on iOS.
    let embedsInNavigationStack: Bool
    let onSave: (EntityProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var bio: String = ""
    @State private var photoUrl: String = ""
    @State private var homePage: String = ""
    @State private var gender: String = ""
    @State private var hairColor: String = ""
    @State private var birthYearString: String = ""
    @State private var countryOfOrigin: String = ""
    @State private var rating: Int = 0
    
    @State private var tags: [String] = []
    @State private var akas: [String] = []
    @State private var links: [EntityLink] = []
    @State private var newLinkUrl: String = ""
    @State private var newLinkLabel: String = ""
    @State private var galleryUrls: [String] = []
    @State private var newGalleryUrl: String = ""
    
    @State private var allUniqueTags: [String] = []
    @State private var allUniqueGenders: [String] = []
    
    // Tag Entry State
    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    @State private var editingTagValue: String? = nil
    
    // AKA Entry State
    @State private var isShowingAkaEntry = false
    @State private var newAkaValue = ""
    @State private var editingAkaValue: String? = nil
    
    // Gender Entry State
    @State private var isShowingGenderSuggestions = false

    // Enrichment. The button exists only when a plugin that can do it is
    // installed — in a default build there is no such plugin, so this section
    // is absent rather than disabled (D3).
    @State private var isShowingEnrichment = false

    /// A canonical name the operator accepted, applied on Save.
    ///
    /// Deferred rather than applied immediately because renaming changes this
    /// record's identity — doing it mid-edit would leave the open form pointing
    /// at an id that no longer exists.
    @State private var pendingCanonicalName: String?

    // Career span (schema v17). No UI yet — these are carried through so that
    // opening the editor and pressing Save cannot erase values that arrived by
    // CSV import or enrichment. Every field the editor does not render still
    // has to survive it.
    @State private var birthDate: String?
    @State private var careerSpanRaw: String?
    @State private var careerStartYear: Int?
    @State private var careerEndYear: Int?
    @State private var ageAtCareerStart: Int?

    // Enrichment state (v18). No UI — carried so that opening the editor and
    // pressing Save cannot erase it. This is the site that silently destroyed
    // v17's career fields for exactly this reason.
    @State private var enrichmentState: EnrichmentState?
    @State private var enrichmentSource: String?
    @State private var enrichmentCheckedAt: Date?
    
    private var filteredTagSuggestions: [String] {
        if newTagValue.isEmpty { return [] }
        return allUniqueTags.filter { $0.localizedCaseInsensitiveContains(newTagValue) && !tags.contains($0) }.prefix(10).map { $0 }
    }
    
    private var filteredGenderSuggestions: [String] {
        if gender.isEmpty { return allUniqueGenders }
        return allUniqueGenders.filter { $0.localizedCaseInsensitiveContains(gender) }
    }
    
    enum Field: Hashable {
        case newGalleryUrl, homePage, gender, hairColor, birthYear, country, bio
        case newLinkUrl
    }
    @FocusState private var focusedField: Field?
    
    init(libraryURL: URL?, entityId: String, profile: EntityProfile?, embedsInNavigationStack: Bool = true, onSave: @escaping (EntityProfile) -> Void) {
        self.libraryURL = libraryURL
        self.entityId = entityId
        self.initialProfile = profile
        self.embedsInNavigationStack = embedsInNavigationStack
        self.onSave = onSave
        _bio = State(initialValue: profile?.bio ?? "")
        _photoUrl = State(initialValue: profile?.photoUrl ?? "")
        _homePage = State(initialValue: profile?.homePage ?? "")
        _gender = State(initialValue: profile?.gender ?? "")
        _hairColor = State(initialValue: profile?.hairColor ?? "")
        _birthYearString = State(initialValue: profile?.birthYear.map { String($0) } ?? "")
        var initialCountry = profile?.countryOfOrigin ?? ""
        if !initialCountry.isEmpty {
            let flag = CountryFlagHelper.flagEmoji(for: initialCountry)
            if !flag.isEmpty && !initialCountry.contains(flag) {
                initialCountry = "\(initialCountry) \(flag)"
            }
        }
        _countryOfOrigin = State(initialValue: initialCountry)
        _rating = State(initialValue: profile?.rating ?? 0)
        _birthDate = State(initialValue: profile?.birthDate)
        _careerSpanRaw = State(initialValue: profile?.careerSpanRaw)
        _careerStartYear = State(initialValue: profile?.careerStartYear)
        _careerEndYear = State(initialValue: profile?.careerEndYear)
        _ageAtCareerStart = State(initialValue: profile?.ageAtCareerStart)
        _enrichmentState = State(initialValue: profile?.enrichmentState)
        _enrichmentSource = State(initialValue: profile?.enrichmentSource)
        _enrichmentCheckedAt = State(initialValue: profile?.enrichmentCheckedAt)
        _tags = State(initialValue: profile?.tags ?? [])
        _akas = State(initialValue: profile?.akas ?? [])
        _links = State(initialValue: profile?.links ?? [])
        
        var initialGallery = profile?.galleryUrls ?? []
        if let photo = profile?.photoUrl, !photo.isEmpty, !initialGallery.contains(photo) {
            initialGallery.insert(photo, at: 0)
        } else if libraryURL != nil, (profile?.photoUrl ?? "").isEmpty {
            let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
            // The local-primary placeholder refers to the OWNING library's file.
            let dir = LibrarySession.shared.profilesDir(forProfile: entityId)
                ?? libraryURL!.appendingPathComponent(".catalog/profiles")
            let fileURL = dir.appendingPathComponent("\(safeId).jpg")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if !initialGallery.contains("local://primary") {
                    initialGallery.insert("local://primary", at: 0)
                }
            }
        }
        _galleryUrls = State(initialValue: initialGallery)
    }
    
    var body: some View {
        Group {
            if embedsInNavigationStack {
                NavigationStack { editorForm }
            } else {
                editorForm
            }
        }
#if os(macOS)
        .frame(minWidth: 400, minHeight: 650)
#endif
    }

    private var editorForm: some View {
            Form {
                // Federated session: this form edits the OWNING library's
                // copy only — say so when the actor also exists elsewhere,
                // or edits look like they "didn't take" in the other library.
                if let owner = LibrarySession.shared.url(forProfile: entityId),
                   !LibrarySession.shared.otherLibraries(containingProfile: entityId).isEmpty {
                    let others = LibrarySession.shared.otherLibraries(containingProfile: entityId)
                    Section {
                        Label(
                            "This actor also exists in \(others.count) other open librar\(others.count == 1 ? "y" : "ies"). Edits here apply to “\(LibrarySession.shared.fullLabel(for: owner))” only.",
                            systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                if let provider = installedActorProvider {
                    Section {
                        Button {
                            isShowingEnrichment = true
                        } label: {
                            Label("Import from \(provider.displayName)", systemImage: "sparkles")
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text("Looks this actor up by name and shows you what it found. "
                             + "Nothing changes until you review it and press Save.")
                    }
                }

                Section(header: Text("Photo Gallery").font(.headline)) {
                    HStack {
                        TextField("https://...", text: $newGalleryUrl)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .focused($focusedField, equals: .newGalleryUrl)
                            .submitLabel(.done)
                            .onSubmit {
                                addGalleryUrl(newGalleryUrl)
                                newGalleryUrl = ""
                                focusedField = .newGalleryUrl // keep focus
                            }
                        Button("Add") {
                            addGalleryUrl(newGalleryUrl)
                            newGalleryUrl = ""
                        }
                        .disabled(newGalleryUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    if !galleryUrls.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(galleryUrls, id: \.self) { url in
                                    VStack {
                                        // isGallery decides which FILE to read, so it must
                                        // reflect what's on disk (the SAVED primary), not the
                                        // live-edited photoUrl field — otherwise promoting a
                                        // URL in the editor renders it from the primary file,
                                        // which still holds the previous photo's bytes.
                                        ProfileImageView(libraryURL: libraryURL, entityId: entityId, photoUrl: url, isGallery: url != (initialProfile?.photoUrl ?? "")) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            ZStack {
                                                Rectangle().fill(Color.secondary.opacity(0.2))
                                                ProgressView()
                                            }
                                        }
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(photoUrl == url ? Color.accentColor : Color.clear, lineWidth: 3)
                                        )
                                        
                                        HStack {
                                            Button(action: {
                                                photoUrl = url
                                            }) {
                                                Image(systemName: photoUrl == url ? "star.fill" : "star")
                                                    .foregroundColor(photoUrl == url ? .yellow : .secondary)
                                            }
                                            .buttonStyle(.plain)
                                            
                                            Spacer()
                                            
                                            Button(action: {
                                                if let idx = galleryUrls.firstIndex(of: url) {
                                                    galleryUrls.remove(at: idx)
                                                }
                                                if photoUrl == url {
                                                    photoUrl = galleryUrls.first ?? ""
                                                }
                                            }) {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .frame(width: 100)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                
                Section(header: Text("Details").font(.headline)) {
                    TextField("Home Page URL", text: $homePage)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focusedField, equals: .homePage)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .gender }
                    
                    VStack(alignment: .leading) {
                        TextField("Gender", text: $gender)
                            .focused($focusedField, equals: .gender)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .hairColor }
                            .onChange(of: gender) { _, _ in isShowingGenderSuggestions = true }
                        
                        if isShowingGenderSuggestions && !filteredGenderSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(filteredGenderSuggestions, id: \.self) { suggestion in
                                        Button(action: {
                                            gender = suggestion
                                            isShowingGenderSuggestions = false
                                        }) {
                                            Text(suggestion)
                                                .font(.caption)
                                                .padding(6)
                                                .background(Color.secondary.opacity(0.2))
                                                .cornerRadius(6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                        
                    TextField("Hair Color", text: $hairColor)
                        .focused($focusedField, equals: .hairColor)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .birthYear }
                    
                    HStack {
                        Text("Birth Year")
                        Spacer()
                        TextField("YYYY", text: $birthYearString)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .birthYear)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .country }
                    }
                    
                    TextField("Country of Origin", text: $countryOfOrigin)
                        .focused($focusedField, equals: .country)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .bio }
                        .onChange(of: countryOfOrigin) { _, newValue in
                            let flag = CountryFlagHelper.flagEmoji(for: newValue)
                            if !flag.isEmpty && !newValue.contains(flag) {
                                countryOfOrigin = "\(newValue.trimmingCharacters(in: .whitespaces)) \(flag)"
                            }
                        }

                    // Favorite rating — same star control as videos; tapping
                    // the current rating clears it.
                    HStack(spacing: 6) {
                        Text("Rating:").font(.subheadline).foregroundColor(.secondary)
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .foregroundColor(.yellow)
                                .onTapGesture {
                                    rating = (rating == star) ? 0 : star
                                }
                                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .contain)

                    // "Notes" rather than "Bio": no external source supplies a
                    // biography here (the chosen provider carries none at all,
                    // 1 of 1,336 rows populated), so this field is and always
                    // has been the operator's own free text. Naming it after
                    // data that never arrives invites the question of why it is
                    // empty.
                    Text("Notes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $bio)
                        .frame(minHeight: 100)
                        .focused($focusedField, equals: .bio)
                }
                
                Section(header: Text("Also Known As (AKAs)").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Button {
                                newAkaValue = ""
                                editingAkaValue = nil
                                isShowingAkaEntry = true
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        
                        if akas.isEmpty {
                            Text("No AKAs").font(.caption).foregroundColor(.secondary)
                        } else {
                            FlowLayout(spacing: 8) {
                                ForEach(akas, id: \.self) { aka in
                                    TagBubble(
                                        label: aka,
                                        color: .green,
                                        onPivot: nil,
                                        onEdit: {
                                            newAkaValue = aka
                                            editingAkaValue = aka
                                            isShowingAkaEntry = true
                                        },
                                        onDelete: {
                                            if let idx = akas.firstIndex(of: aka) {
                                                akas.remove(at: idx)
                                            }
                                        },
                                        navRoute: nil
                                    )
                                }
                            }
                        }
                    }
                }
                
                Section(header: Text("Links").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        // URL and label are separate fields because the label is
                        // the part worth reading and the URL is the part that
                        // has to be exact. An importer fills both; a person
                        // typing one by hand can leave the label off and get the
                        // host as a fallback.
                        // Deliberately the same shape as the Photo Gallery
                        // adder above: a labelled default-style button plus
                        // onSubmit. An icon-only .plain button between two
                        // text fields had no reliable hit area here — the URL
                        // field expands and starves it.
                        HStack {
                            TextField("https://...", text: $newLinkUrl)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                #endif
                                .focused($focusedField, equals: .newLinkUrl)
                                .submitLabel(.done)
                                .onSubmit { addLink(); focusedField = .newLinkUrl }
                            TextField("Label (optional)", text: $newLinkLabel)
                                .autocorrectionDisabled()
                                .frame(maxWidth: 160)
                                .onSubmit { addLink(); focusedField = .newLinkUrl }
                            Button("Add") { addLink() }
                                // A bad address stored is worse than one
                                // refused: it renders as a dead chip with no
                                // way to tell why.
                                .disabled(!canAddLink)
                        }

                        if links.isEmpty {
                            Text("No links").font(.caption).foregroundColor(.secondary)
                        } else {
                            EntityLinksView(links: links, title: nil) { link in
                                links.removeAll { $0.url == link.url }
                            }
                        }
                    }
                }

                Section(header: Text("Tags").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Button {
                                newTagValue = ""
                                editingTagValue = nil
                                isShowingTagEntry = true
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        
                        if tags.isEmpty {
                            Text("No tags").font(.caption).foregroundColor(.secondary)
                        } else {
                            FlowLayout(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    TagBubble(
                                        label: tag,
                                        color: .blue,
                                        onPivot: nil,
                                        onEdit: {
                                            newTagValue = tag
                                            editingTagValue = tag
                                            isShowingTagEntry = true
                                        },
                                        onDelete: {
                                            if let idx = tags.firstIndex(of: tag) {
                                                tags.remove(at: idx)
                                            }
                                        },
                                        navRoute: nil
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Edit Profile")
            .sheet(isPresented: $isShowingEnrichment) {
                if let provider = installedActorProvider {
                    ActorEnrichmentSheet(
                        provider: provider,
                        entityId: entityId,
                        actorName: displayName,
                        // Built from the LIVE field values, not the profile this
                        // view opened with — otherwise an edit made just now
                        // would read as an empty field and be "filled" with the
                        // source's value.
                        currentProfile: editedProfile,
                        onApply: { merged, renameTo in
                            applyEnrichment(merged)
                            // Held until Save: the rename rewrites this record's
                            // identity, so it must not happen while the form is
                            // still open against the old one.
                            pendingCanonicalName = renameTo
                        }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let finalPhotoUrl = photoUrl.trimmingCharacters(in: .whitespacesAndNewlines)

                        // If a new remote primary is about to overwrite a
                        // local-only primary (a photo file with no source
                        // URL — unrecoverable once overwritten), preserve
                        // the old file as a regular gallery photo first.
                        preserveLocalPrimaryIfBeingReplaced(by: finalPhotoUrl)

                        var finalCountry = countryOfOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !finalCountry.isEmpty {
                            let flag = CountryFlagHelper.flagEmoji(for: finalCountry)
                            if !flag.isEmpty && !finalCountry.contains(flag) {
                                finalCountry = "\(finalCountry) \(flag)"
                            }
                        }
                        
                        // RENAME FIRST, then write. renameTagGlobally moves the
                        // profile row, every video's actor: tag and every photo
                        // file; saving before it would write a row the rename
                        // then moves out from under us.
                        //
                        // Runs across EVERY open library because the user sees
                        // one tag space — renaming in only one would leave the
                        // federated view showing both names.
                        let savedEntityId = performCanonicalRename() ?? entityId

                        var profile = EntityProfile(
                            id: savedEntityId,
                            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
                            photoUrl: finalPhotoUrl.isEmpty ? nil : finalPhotoUrl,
                            homePage: homePage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : homePage,
                            gender: gender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : gender,
                            hairColor: hairColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hairColor,
                            birthYear: Int(birthYearString.trimmingCharacters(in: .whitespacesAndNewlines)),
                            countryOfOrigin: finalCountry.isEmpty ? nil : finalCountry,
                            rating: rating == 0 ? nil : rating,
                            tags: tags,
                            galleryUrls: galleryUrls,
                            akas: akas,
                            createdAt: initialProfile?.createdAt ?? Date(),
                            birthDate: birthDate,
                            careerSpanRaw: careerSpanRaw,
                            careerStartYear: careerStartYear,
                            careerEndYear: careerEndYear,
                            ageAtCareerStart: ageAtCareerStart,
                            enrichmentState: enrichmentState,
                            enrichmentSource: enrichmentSource,
                            enrichmentCheckedAt: enrichmentCheckedAt,
                            links: links
                        )

                        // An unresolved lookup verdict is only as good as the
                        // data it was based on. If the operator supplied an
                        // alias or a birth date — the things a lookup uses to
                        // find and disambiguate — the old answer is stale and
                        // the actor returns to the queue.
                        //
                        // Rating, bio and notes changes leave it alone: they
                        // cannot change what a lookup would find.
                        let revised = EnrichmentInvalidation.afterManualEdit(
                            previous: initialProfile ?? profile, edited: profile)
                        profile.enrichmentState = revised.state
                        profile.enrichmentSource = revised.source
                        profile.enrichmentCheckedAt = revised.checkedAt
                        
                        if !finalPhotoUrl.isEmpty {
                            // Re-fetch only when the primary actually changed, so
                            // editing an unrelated field still costs no network.
                            let primaryChanged = finalPhotoUrl != (initialProfile?.photoUrl ?? "")
                            downloadProfileImage(urlString: finalPhotoUrl,
                                                 isGallery: false,
                                                 overwrite: primaryChanged,
                                                 forEntityId: savedEntityId)
                        }
                        for url in galleryUrls {
                            if url != finalPhotoUrl {
                                downloadProfileImage(urlString: url, isGallery: true,
                                                     forEntityId: savedEntityId)
                            }
                        }
                        
                        onSave(profile)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        .popover(isPresented: $isShowingTagEntry) {
            tagEntryPopover
        }
        .popover(isPresented: $isShowingAkaEntry) {
            akaEntryPopover
        }
        .onAppear {
            guard libraryURL != nil else { return }
            do {
                // Suggestion vocabularies span every open library.
                var profiles: [EntityProfile] = []
                for libURL in LibrarySession.shared.allURLs {
                    profiles.append(contentsOf: try LibraryStore(at: libURL).fetchAllEntityProfiles())
                }
                let allTagsSet = Set(profiles.flatMap { $0.tags })
                allUniqueTags = Array(allTagsSet).sorted()

                let gendersSet = Set(profiles.compactMap { $0.gender }.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                allUniqueGenders = Array(gendersSet).sorted()
            } catch {
                print("Failed to fetch unique tags/genders: \(error)")
            }
        }
    }
    
    private var tagEntryPopover: some View {
        VStack(spacing: 12) {
            Text(editingTagValue == nil ? "Add Tag" : "Edit Tag")
                .font(.headline)
            TextField("Tag Name...", text: $newTagValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTag() }
                
            if !filteredTagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(filteredTagSuggestions, id: \.self) { suggestion in
                            Button(action: {
                                newTagValue = suggestion
                                saveTag()
                            }) {
                                Text(suggestion)
                                    .font(.caption)
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button("Save") { saveTag() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .popoverFrame()
    }
    
    /// The entity's name. Ids follow the "actor:Name" convention used across
    /// the app, so the name is everything after the first colon.
    private var displayName: String {
        guard let colon = entityId.firstIndex(of: ":") else { return entityId }
        return String(entityId[entityId.index(after: colon)...])
    }

    /// The first installed plugin that can enrich an actor.
    ///
    /// `installed` is the only list the enrichment UI may consult — an available
    /// but uninstalled plugin must have no affordance anywhere (D3). Takes the
    /// first because provider precedence is still an open spec decision; with
    /// one plugin installed the question does not arise.
    private var installedActorProvider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installed
            .compactMap { $0 as? any ActorMetadataProvider }
            .first
    }

    /// A candidate link built from the two entry fields, or nil when the URL
    /// is blank or unusable.
    ///
    /// Bare hosts are accepted and given a scheme: someone typing an address
    /// from memory writes `example.com`, and refusing that would be pedantry.
    private var pendingLink: EntityLink? {
        var raw = newLinkUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        let link = EntityLink(
            url: raw,
            label: newLinkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return link.isValid ? link : nil
    }

    private var canAddLink: Bool { pendingLink != nil }

    private func addLink() {
        guard let link = pendingLink else { return }
        // Same URL twice is a no-op rather than a duplicate row. Re-adding an
        // address with a better label updates the label, which is the only
        // reason someone would do it deliberately.
        if let existing = links.firstIndex(where: {
            $0.url.caseInsensitiveCompare(link.url) == .orderedSame
        }) {
            if !link.label.isEmpty { links[existing].label = link.label }
        } else {
            links.append(link)
        }
        newLinkUrl = ""
        newLinkLabel = ""
    }

    /// The profile as it stands in the form right now.
    private var editedProfile: EntityProfile {
        EntityProfile(
            id: entityId,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
            photoUrl: photoUrl.isEmpty ? nil : photoUrl,
            homePage: homePage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : homePage,
            gender: gender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : gender,
            hairColor: hairColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hairColor,
            birthYear: Int(birthYearString.trimmingCharacters(in: .whitespacesAndNewlines)),
            countryOfOrigin: countryOfOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : countryOfOrigin,
            rating: rating == 0 ? nil : rating,
            tags: tags,
            galleryUrls: galleryUrls,
            akas: akas,
            createdAt: initialProfile?.createdAt,
            birthDate: birthDate,
            careerSpanRaw: careerSpanRaw,
            careerStartYear: careerStartYear,
            careerEndYear: careerEndYear,
            ageAtCareerStart: ageAtCareerStart,
            enrichmentState: enrichmentState,
            enrichmentSource: enrichmentSource,
            enrichmentCheckedAt: enrichmentCheckedAt,
            links: links
        )
    }

    /// Drops accepted values into the form. Deliberately NOT a save: the user
    /// still reviews the populated fields and presses Save, and the gallery
    /// downloads happen on that existing save path.
    private func applyEnrichment(_ merged: EntityProfile) {
        bio = merged.bio ?? bio
        photoUrl = merged.photoUrl ?? photoUrl
        gender = merged.gender ?? gender
        hairColor = merged.hairColor ?? hairColor
        birthYearString = merged.birthYear.map(String.init) ?? birthYearString
        countryOfOrigin = merged.countryOfOrigin ?? countryOfOrigin
        tags = merged.tags
        akas = merged.akas
        // The merge already unioned these against what the form holds, so
        // assigning the result is what keeps an accepted "Links" row from
        // being silently discarded on the way back into the editor.
        links = merged.links
        galleryUrls = merged.galleryUrls
        birthDate = merged.birthDate ?? birthDate
        careerSpanRaw = merged.careerSpanRaw ?? careerSpanRaw
        careerStartYear = merged.careerStartYear ?? careerStartYear
        careerEndYear = merged.careerEndYear ?? careerEndYear
        ageAtCareerStart = merged.ageAtCareerStart ?? ageAtCareerStart
        enrichmentState = merged.enrichmentState ?? enrichmentState
        enrichmentSource = merged.enrichmentSource ?? enrichmentSource
        enrichmentCheckedAt = merged.enrichmentCheckedAt ?? enrichmentCheckedAt
    }

    /// Applies an accepted canonical name across every open library.
    ///
    /// Returns the new entity id, or nil when there was nothing to do. Errors
    /// are surfaced rather than swallowed: a half-completed rename is exactly
    /// the failure this operation is most prone to, and silence would leave the
    /// operator believing it worked.
    private func performCanonicalRename() -> String? {
        guard let newName = pendingCanonicalName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !newName.isEmpty else { return nil }
        let newTag = "actor:\(newName)"
        guard TagNormalizer.normalize(fullTag: newTag)
                != TagNormalizer.normalize(fullTag: entityId) else { return nil }

        do {
            for libURL in LibrarySession.shared.allURLs {
                let store = try LibraryStore(at: libURL)
                try store.renameTagGlobally(oldTag: entityId, newTag: newTag)
            }
            pendingCanonicalName = nil
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
            return TagNormalizer.normalize(fullTag: newTag)
        } catch {
            AppErrorReporter.report("Couldn't rename this actor across the library: "
                                    + error.localizedDescription)
            // Fall back to saving under the EXISTING id. The other enrichment
            // values are still worth keeping, and the operator can retry the
            // rename from the profile menu.
            return nil
        }
    }

    private func saveTag() {
        let val = newTagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else {
            isShowingTagEntry = false
            return
        }
        let normalized = TagNormalizer.normalize(tagValue: val)
        
        if let editing = editingTagValue {
            if let idx = tags.firstIndex(of: editing) {
                tags[idx] = normalized
            }
        } else {
            if !tags.contains(normalized) {
                tags.append(normalized)
            }
        }
        tags.sort()
        isShowingTagEntry = false
    }
    
    private var akaEntryPopover: some View {
        VStack(spacing: 12) {
            Text(editingAkaValue == nil ? "Add AKA" : "Edit AKA")
                .font(.headline)
            TextField("AKA Name...", text: $newAkaValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveAka() }
                
            Button("Save") { saveAka() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .popoverFrame()
    }
    
    private func saveAka() {
        let val = newAkaValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else {
            isShowingAkaEntry = false
            return
        }
        let normalized = TagNormalizer.normalize(tagValue: val)
        
        if let editing = editingAkaValue {
            if let idx = akas.firstIndex(of: editing) {
                akas[idx] = normalized
            }
        } else {
            if !akas.contains(normalized) {
                akas.append(normalized)
            }
        }
        akas.sort()
        isShowingAkaEntry = false
    }
    
    /// The primary photo file (`<safeId>.jpg`) is overwritten on save when a
    /// remote primary URL is set. If the CURRENT primary is local-only (no
    /// URL — the `local://primary` placeholder), that file is the only copy
    /// in existence. Copy it to a content-addressed gallery file and swap
    /// the placeholder token for a synthetic one (same convention as Actor
    /// Library Merge), so the old photo survives the overwrite.
    private func preserveLocalPrimaryIfBeingReplaced(by newPrimaryUrl: String) {
        guard !newPrimaryUrl.isEmpty,
              (initialProfile?.photoUrl ?? "").isEmpty,
              let idx = galleryUrls.firstIndex(of: ProfileImageNaming.localPrimaryToken),
              let libraryURL else { return }

        // Photo files belong to the profile's OWNING library.
        let profilesDir = LibrarySession.shared.profilesDir(forProfile: entityId)
            ?? libraryURL.appendingPathComponent(".catalog/profiles")
        let primaryFile = profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: entityId))
        guard let data = try? Data(contentsOf: primaryFile) else {
            // No file to preserve — just drop the now-meaningless placeholder.
            galleryUrls.remove(at: idx)
            return
        }

        let token = "imported-photo://\(ProfileImageNaming.sha256Hex(data))"
        let destination = profilesDir.appendingPathComponent(ProfileImageNaming.galleryFileName(for: entityId, token: token))
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination)
            }
            galleryUrls[idx] = token
        } catch {
            print("Failed to preserve local primary photo: \(error)")
            AppErrorReporter.report("Couldn't preserve the previous profile photo: \(error.localizedDescription)")
        }
    }

    private func addGalleryUrl(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !galleryUrls.contains(url) else { return }
        galleryUrls.append(url)
        // Only auto-promote to primary when there's truly no primary yet.
        // An empty photoUrl does NOT mean "no primary" — a local-only
        // primary (the local://primary placeholder) has a photo file on
        // disk but no URL. Auto-promoting over it made the new URL render
        // as "the primary" (showing the OLD photo's bytes, so the gallery
        // appeared to hold two copies of the old photo), and saving then
        // overwrote — permanently — the local-only original.
        if photoUrl.isEmpty && !galleryUrls.contains(ProfileImageNaming.localPrimaryToken) {
            photoUrl = url
        }
    }

    /// - Parameter overwrite: replace a cached file that already exists.
    ///   Required when the PRIMARY changes, because the primary's filename is
    ///   fixed per actor (`actor_Name.jpg`) rather than content-addressed like
    ///   the gallery's. Without it, "the file exists" means "this actor has a
    ///   primary", not "this image is cached" — so starring a different photo
    ///   updated photo_url in the database and then declined to replace the
    ///   file the UI actually renders.
    /// - Parameter forEntityId: whose profile these files belong to. Defaults to
    ///   this view's id, but a Save that renamed the actor must pass the NEW one:
    ///   the files have already been moved by then, and writing under the old id
    ///   would strand them.
    private func downloadProfileImage(urlString: String, isGallery: Bool,
                                      overwrite: Bool = false,
                                      forEntityId: String? = nil) {
        let entityId = forEntityId ?? self.entityId
        guard urlString != "local://primary" else { return }
        guard let url = URL(string: urlString), let libraryURL = libraryURL,
              url.scheme == "http" || url.scheme == "https" else { return }
        let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        // Downloads land in the profile's OWNING library.
        let profilesDir = LibrarySession.shared.profilesDir(forProfile: entityId)
            ?? libraryURL.appendingPathComponent(".catalog/profiles")

        let fileName: String
        if isGallery {
            let hashData = SHA256.hash(data: Data(urlString.utf8))
            let hashString = hashData.compactMap { String(format: "%02x", $0) }.joined()
            fileName = "\(safeId)_\(hashString).jpg"
        } else {
            fileName = "\(safeId).jpg"
        }

        let fileURL = profilesDir.appendingPathComponent(fileName)

        // Download-once contract: a photo already cached on disk is never
        // re-fetched. Without this, every Save re-downloaded the primary and
        // the entire gallery — hitting the network (and any now-broken hosts)
        // just for editing an unrelated field like the rating.
        //
        // The contract holds ONLY while the filename identifies the image.
        // Gallery files are content-addressed, so it always does. The primary
        // is not, so the caller must say when the URL behind it has changed.
        guard overwrite || !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // A starred photo is a GALLERY entry, so its bytes are almost always
        // already on disk under the content-addressed gallery name. Copy them
        // rather than re-fetching.
        //
        // Re-fetching raced the UI: the profile page's .task(id: photoUrl)
        // re-runs on save and reads the primary file, but the download runs
        // detached, so the read usually won and the page kept showing the old
        // photo until the view was recreated. A previously-used photo appeared
        // to work only because URLCache made its fetch fast enough to win that
        // race — luck, not correctness.
        //
        // Written atomically so the primary is never momentarily absent.
        if !isGallery,
           let source = LibrarySession.shared.existingProfilePhotoURL(
                fileName: ProfileImageNaming.galleryFileName(for: entityId, token: urlString)),
           let bytes = try? Data(contentsOf: source),
           (try? bytes.write(to: fileURL, options: .atomic)) != nil {
            return
        }

        Task.detached {
            do {
                try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: nil)
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                    print("Failed to download profile image for \(entityId): HTTP \(httpResponse.statusCode)")
                    return
                }

                // Validate the bytes decode as an image before persisting —
                // some hosts return an HTML error page with a 200 status,
                // and saving that as a .jpg poisons the cache on disk.
                #if os(iOS)
                let decodable = UIImage(data: data) != nil
                #else
                let decodable = NSImage(data: data) != nil
                #endif
                guard decodable else {
                    print("Downloaded profile image for \(entityId) is not decodable; not saving")
                    return
                }

                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Failed to forcefully download profile image for \(entityId): \(error)")
            }
        }
    }
}

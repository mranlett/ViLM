// InspectorView.swift
// Video Details: dispatches to the batch editor for multi-selections, and
// otherwise renders the full single-video inspector - frame grid, inline
// player, scene markers, metadata/series fields, tag sections, rename, play
// tracking, and the delete flow.

import SwiftUI
import LibraryCore
import AVFoundation

#if os(macOS)
import AppKit
#endif

struct InspectorView: View {
    @Binding var sidebarSelection: Set<SidebarItem>
    let selectedAssetIDs: Set<Asset.ID>
    @Binding var assets: [Asset]
    @Binding var selectedAssetBinding: Set<Asset.ID>
    @Binding var gridRefreshID: UUID
    let libraryURL: URL?
    @Binding var missingAssetIDs: Set<Asset.ID>
    var contextAssetIDs: [Asset.ID] = []
    /// When this matches the shown asset, Video Details auto-starts playback
    /// (set by a direct-play quick action). Cleared once consumed.
    var autoPlayAssetID: Binding<UUID?> = .constant(nil)

    var body: some View {
        if selectedAssetIDs.count > 1 {
            BatchInspectorView(
                selectedAssetIDs: selectedAssetIDs,
                assets: $assets,
                libraryURL: libraryURL
            )
        } else if let assetID = selectedAssetIDs.first, let asset = assets.first(where: { $0.id == assetID }) {
            SingleInspectorView(
                sidebarSelection: $sidebarSelection,
                asset: asset,
                assets: $assets,
                selectedAssetBinding: $selectedAssetBinding,
                gridRefreshID: $gridRefreshID,
                libraryURL: libraryURL,
                missingAssetIDs: $missingAssetIDs,
                contextAssetIDs: contextAssetIDs,
                autoPlayAssetID: autoPlayAssetID
            )
            .id(asset.id)
        } else {
            ContentUnavailableView("Selection Lost", systemImage: "questionmark")
        }
    }
}

struct SingleInspectorView: View {
    /// The source page for this video, opened in the app's private browser.
    @State private var browsingLink: BrowsableURL?

    /// `URL` is not `Identifiable`, and `sheet(item:)` needs identity.
    struct BrowsableURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
    @Binding var sidebarSelection: Set<SidebarItem>
    let asset: Asset
    @Binding var assets: [Asset]
    @Binding var selectedAssetBinding: Set<Asset.ID>
    @Binding var gridRefreshID: UUID
    let libraryURL: URL?
    @Binding var missingAssetIDs: Set<Asset.ID>
    let contextAssetIDs: [Asset.ID]
    @Binding var autoPlayAssetID: UUID?
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    /// Why a tag was refused. Surfaced, never swallowed: a tag that silently
    /// failed to save reads as the app losing the edit.
    @State private var tagRejectionMessage: String?
    @State private var activeCategory = "tag"
    @State private var editingTagValue: String? = nil
    @State private var isShowingRenameDialog = false
    @State private var suggestedRenameValue = ""
    @State private var showDeleteConfirmation = false
    @State private var isShowingHelp = false
    /// Non-nil = the "New Playlist" prompt is up for these videos.
    @State private var newPlaylistPendingIDs: [Asset.ID]? = nil
    // Watch-first layout: browsing is the default; all metadata editing lives
    // behind the ✎ sheet, maintenance behind the ⋯ menu.
    @State private var isShowingEditSheet = false
    /// Remembered rather than reset each time.
    ///
    /// It stays collapsed by DEFAULT — it duplicates the player's seek job and
    /// is the biggest space consumer on this screen. But someone working
    /// through untagged videos needs it open on every one of them, and
    /// re-expanding it per video is the kind of friction that stops a
    /// thousand-video pass.
    @AppStorage("inspectorShowsFrames") private var isShowingFrames = false
    
    private var currentIndex: Int? {
        contextAssetIDs.firstIndex(of: asset.id)
    }
    
    private var hasPrevious: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }
    
    private var hasNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < contextAssetIDs.count - 1
    }
    
    private func goToPrevious() {
        guard let idx = currentIndex, idx > 0 else { return }
        selectedAssetBinding = [contextAssetIDs[idx - 1]]
    }
    
    private func goToNext() {
        guard let idx = currentIndex, idx < contextAssetIDs.count - 1 else { return }
        selectedAssetBinding = [contextAssetIDs[idx + 1]]
    }

    // Playback / selection
    @State private var scrubTime: Double = 0
    @State private var duration: Double = 1
    @State private var playback = VideoPlaybackController()
    @State private var isShowingPlayer = false
    // Counts at most once per viewing session (reset when the parent view's
    // .id(asset.id) gives us a fresh instance for a different video), so
    // scrubbing around the same video several times isn't several "plays."
    @State private var hasRecordedPlayThisSession = false

    // Scene markers
    @State private var sceneMarkers: [SceneMarker] = []
    @State private var isShowingAddMarkerPopover = false
    @State private var pendingMarkerTimestamp: Double = 0
    @State private var editingMarker: SceneMarker? = nil
    // Bumped once a newly-added marker's thumbnail finishes generating
    // asynchronously, so its card's .task re-checks disk for the new file.
    @State private var markerThumbnailRefreshID = UUID()

    // iOS/Mac shared progress flags
    @State private var isSavingThumb = false
    @State private var isGeneratingSheet = false

    // Face-based actor suggestions
    @State private var isShowingEditVideo = false
    @State private var isShowingVideoMatch = false

    // Notes editing buffer (see annotationsSection for why edits are
    // debounced instead of bound directly to the asset).
    @State private var notesDraft: String = ""
    @State private var notesSaveTask: Task<Void, Never>?

    // Series Name and Episode Title editing buffers. Normalizing to title
    // case on every keystroke would fight the typist (and jump the cursor),
    // so each field edits its draft freely and commits the title-cased result
    // when the user submits or leaves the field/video.
    @State private var seriesNameDraft: String = ""
    @State private var episodeTitleDraft: String = ""

    // macOS-only state
    #if os(macOS)
    @State private var previewFrame: NSImage?
    @State private var popout = PlayerWindowController()
    @State private var playerHeight: CGFloat = 280
    private let minPlayerHeight: CGFloat = 180
    private let maxPlayerHeight: CGFloat = 700
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // The filename first, because on an untagged video it carries
                // the metadata being entered — performers, tags and studio are
                // encoded in it for ~95% of files, while the catalogue knows
                // them for far fewer. Selectable so a name can be copied into a
                // field rather than retyped.
                sourceFileNameHeader

                // Frame grid ABOVE the player (user decision), folded into an
                // accordion. Still collapsed by default for space, but the
                // choice now persists — see isShowingFrames.
                framesAccordion

                // Playback controls (platform-specific)
                #if os(macOS)
                HStack {
                    Button("Pop Out Player") {
                        isShowingPlayer = false
                        popout.show(title: asset.fileName, player: playback.player)
                    }
                    .buttonStyle(.bordered)

                    Button(isShowingPlayer ? "Hide Inline Player" : "Show Inline Player") {
                        isShowingPlayer.toggle()
                        if !isShowingPlayer { playback.player.pause() }
                    }
                    .buttonStyle(.bordered)
                }

                if isShowingPlayer {
                    PlayerView(player: playback.player)
                        .frame(height: playerHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottom) {
                            // Drag handle
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.6))
                                        .frame(width: 36, height: 3)
                                )
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let newHeight = playerHeight + value.translation.height
                                            playerHeight = min(max(newHeight, minPlayerHeight), maxPlayerHeight)
                                        }
                                )
                        }
                }
                #else
                // iOS: simplest UX: show/hide inline player
                HStack {
                    Button(isShowingPlayer ? "Hide Player" : "Show Player") {
                        isShowingPlayer.toggle()
                        if !isShowingPlayer { playback.player.pause() }
                    }
                    .buttonStyle(.bordered)

                    Button("Play From Start") {
                        if let url = videoURL() {
                            isShowingPlayer = true
                            recordPlayIfNeeded()
                            playback.load(url: url, startSeconds: 0, autoplay: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isShowingPlayer {
                    PlayerView(player: playback.player)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                #endif

                // Markers ride with the player: jump points are a WATCHING
                // feature (capture at the playhead lives here too).
                sceneMarkersSection

                Divider()

                titleBlock

                browsePillsSection

                browseNotesSection

                // The operator's own writing comes first; the source's follows.
                browseSourceDescriptionSection

                Color.clear.frame(height: 40)
            }
            .padding()
        }
        .frame(minWidth: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) {
                    Button {
                        isShowingEditSheet = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .help("Edit metadata")
                    .accessibilityLabel("Edit metadata")

                    Menu {
                        Menu {
                            AddToPlaylistMenuItems(assetIDs: [asset.id]) {
                                newPlaylistPendingIDs = [asset.id]
                            }
                        } label: {
                            Label("Add to Playlist", systemImage: "list.and.film")
                        }
                        // ⚠️ Labels here are kept SHORT, and the two regenerate
                        // actions live in a submenu, because this menu has to
                        // fit on a phone at an accessibility text size.
                        //
                        // At a large type size every row wraps to two or three
                        // lines, and seven rows then ran past the bottom of the
                        // screen — taking `Delete Video…` with them, since a
                        // destructive action belongs last. The action was
                        // present and unreachable, which reads exactly like it
                        // having been removed.
                        Button {
                            isShowingEditVideo = true
                        } label: {
                            Label("Trim / Flip", systemImage: "slider.horizontal.below.rectangle")
                        }
                        .disabled(missingAssetIDs.contains(asset.id))
                        // Only offered when a source is actually installed, and
                        // labelled with ITS name rather than a hard-coded one —
                        // this file must not know which sources exist.
                        if let source = videoMetadataSourceName {
                            Button {
                                isShowingVideoMatch = true
                            } label: {
                                Label("Match with \(source)", systemImage: "sparkle.magnifyingglass")
                            }
                            .disabled(missingAssetIDs.contains(asset.id) || libraryURL == nil)
                        }
                        Button {
                            suggestedRenameValue = asset.suggestedFileNameFromTags ?? asset.fileName
                            isShowingRenameDialog = true
                        } label: {
                            Label("Rename File…", systemImage: "pencil.line")
                        }
                        // One row instead of two, and they are a genuine pair —
                        // both rebuild imagery from the file.
                        Menu {
                            Button {
                                regenerateDefaultThumbnail()
                            } label: {
                                Label("Thumbnail", systemImage: "photo")
                            }
                            .disabled(isSavingThumb)
                            Button {
                                generateContactSheet()
                            } label: {
                                Label("Contact Sheet", systemImage: "square.grid.3x3")
                            }
                            .disabled(isGeneratingSheet)
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Video…", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More actions")
                }
            }
        }
        .sheet(isPresented: $isShowingEditSheet) {
            editSheet
        }
#if os(macOS)
        // ⌘⌫ opens the same delete confirmation as the Danger Zone button
        // (hidden so it works even while the DisclosureGroup is collapsed).
        .background(
            Button("") { showDeleteConfirmation = true }
                .keyboardShortcut(.delete, modifiers: [.command])
                .hidden()
                .accessibilityHidden(true)
        )
#endif
        .sheet(isPresented: $isShowingRenameDialog) {
            RenameDialogView(
                oldFileName: asset.fileName,
                newFileName: $suggestedRenameValue,
                onCancel: { isShowingRenameDialog = false },
                onConfirm: {
                    performRename()
                }
            )
        }
        .alert("Delete Video?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteVideo()
            }
        } message: {
            Text("This will move the video file and its metadata to the Trash. This action cannot be undone here.")
        }
        .sheet(isPresented: $isShowingVideoMatch) {
            if let url = libraryURL {
                VideoEnrichmentSheet(asset: asset, libraryURL: url,
                                     knownTags: knownTagVocabulary) { updated in
                    updateAsset(updated, at: LibrarySession.shared.url(for: updated.id) ?? url)
                    // Every other write on this screen announces itself. Without
                    // it the grid behind, and anything deriving from the title,
                    // keep rendering the values from before the match until the
                    // view is rebuilt by navigating away and back.
                    gridRefreshID = UUID()
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ReloadAssets"), object: nil)
                }
            }
        }
        .sheet(isPresented: $isShowingEditVideo) {
            if let url = libraryURL {
                EditVideoView(asset: asset, libraryURL: url, sceneMarkers: sceneMarkers,
                              onCompleted: { handleVideoEdited() })
            }
        }
        .onAppear {
            #if os(macOS)
            loadDuration()
            #endif
            loadSceneMarkers()
            notesDraft = asset.notes ?? ""
            seriesNameDraft = asset.videoName ?? ""
            episodeTitleDraft = asset.episode ?? ""
            startAutoPlayIfRequested()
        }
        .modifier(NewPlaylistPrompt(pendingAssetIDs: $newPlaylistPendingIDs))
        .onDisappear {
            // Commit any un-committed notes/series-name/episode-title edit
            // before the view goes away, and stop audio — on iPhone, pushing
            // deeper (e.g. tapping an actor tag) keeps this view alive in the
            // navigation stack, so without this the video kept playing
            // underneath the new screen.
            notesSaveTask?.cancel()
            commitNotesDraft()
            commitSeriesNameDraft()
            commitEpisodeTitleDraft()
            playback.player.pause()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Leaving the foreground is the last reliable moment before a
            // possible swipe-kill: flush the debounced notes/series/episode
            // drafts now, or an edit typed in the final ~600ms dies with the
            // process (DEFECT_INVENTORY L9).
            if newPhase != .active {
                notesSaveTask?.cancel()
                commitNotesDraft()
                commitSeriesNameDraft()
                commitEpisodeTitleDraft()
            }
        }
        .onChange(of: asset.id) { _, _ in
            #if os(macOS)
            loadDuration()
            #endif
            loadSceneMarkers()
            notesDraft = asset.notes ?? ""
            seriesNameDraft = asset.videoName ?? ""
            episodeTitleDraft = asset.episode ?? ""
        }
        .onChange(of: scrubTime) { _, newValue in
            #if os(macOS)
            guard isShowingPlayer else { return }
            Task { await playback.seek(to: newValue, autoplay: nil) }
            #endif
        }
        .navigationTitle("Video Details")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleFullScreen"), object: nil)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Toggle Full Screen")
                .accessibilityLabel("Toggle Full Screen")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { isShowingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.videoDetails.id)
        }
    }

    // MARK: - Scene Markers

    // The real, live playback position — NOT `scrubTime`, which is just a
    // one-shot "seek to here" request set when tapping a frame-grid thumbnail
    // or dragging the macOS scrubber. It never tracks ongoing playback, so
    // using it here would record the same stale timestamp for every marker
    // regardless of where the video is actually paused.
    private func currentPlaybackSeconds() -> Double {
        let seconds = playback.player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : scrubTime
    }

    private func formattedTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    // MARK: - Watch-first browse sections

    /// Frame grid above the player (user decision), collapsed by default.
    /// On macOS the thumbnail scrubber tools live here too — they're
    /// frame-preview machinery.
    /// The file's name on disk, readable and copyable.
    ///
    /// Distinct from the display title: `videoName` is what the user chose to
    /// call it, this is what the file is actually called. When tagging an
    /// unreviewed video the two differ, and the filename is the useful one.
    private var sourceFileNameHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("File name", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(asset.fileName)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var framesAccordion: some View {
        DisclosureGroup(isExpanded: $isShowingFrames) {
            VStack(alignment: .leading, spacing: 10) {
                DetailGridView(asset: asset, libraryURL: libraryURL, isInteractive: true) { t in
                    scrubTime = t

                    #if os(macOS)
                    // If the popout is open, keep inline hidden.
                    if popout.isOpen {
                        isShowingPlayer = false
                        popout.bringToFront()
                    } else {
                        isShowingPlayer = true
                    }
                    #else
                    isShowingPlayer = true
                    #endif

                    if let url = videoURL() {
                        if !missingAssetIDs.contains(asset.id) {
                            recordPlayIfNeeded()
                            playback.load(url: url, startSeconds: t, autoplay: true)
                        }
                    }
                }
                .id(asset.id)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 2)

                #if os(macOS)
                ZStack {
                    if let preview = previewFrame {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.black)
                            .aspectRatio(1.33, contentMode: .fit)
                    }

                    if isSavingThumb {
                        ProgressView()
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Slider(
                    value: $scrubTime,
                    in: 0...max(1, duration),
                    onEditingChanged: { _ in
                        generatePreview()
                    }
                )

                HStack {
                    Button("Set as Main Thumbnail") {
                        saveNewThumbnailFromScrubTime()
                    }
                    .disabled(isSavingThumb)
                    .controlSize(.small)

                    Button {
                        if let url = videoURL() {
                            isShowingPlayer = true
                            recordPlayIfNeeded()
                            playback.load(url: url, startSeconds: scrubTime, autoplay: true)
                        }
                    } label: {
                        Label("Play from Scrubber", systemImage: "play.circle.fill")
                    }
                    .controlSize(.small)
                }
                #endif
            }
            .padding(.top, 8)
        } label: {
            Label("Preview Frames", systemImage: "square.grid.3x3")
                .font(.subheadline.bold())
        }
    }

    /// Title, series line, and the glanceable meta row (rating, status,
    /// library, play count) — plus prev/next and the missing-file rescue.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.videoName ?? asset.fileName)
                        .font(.headline)
                        .lineLimit(nil)
                    if !asset.seriesTitleBlock.isEmpty {
                        Text(asset.seriesTitleBlock)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if hasPrevious || hasNext {
                    HStack(spacing: 12) {
                        Button(action: goToPrevious) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!hasPrevious)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .help("Previous Video")
                        .accessibilityLabel("Previous Video")

                        Button(action: goToNext) {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!hasNext)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .help("Next Video")
                        .accessibilityLabel("Next Video")
                    }
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= (asset.rating ?? 0) ? "star.fill" : "star")
                            .foregroundColor(.yellow)
                            .onTapGesture {
                                var updated = asset
                                if updated.rating == star {
                                    updated.rating = nil
                                } else {
                                    updated.rating = star
                                }
                                if let url = LibrarySession.shared.url(for: asset.id) { updateAsset(updated, at: url) }
                            }
                    }
                }
                .accessibilityLabel("Rating: \(asset.rating ?? 0) of 5")

                Button(action: { toggleStatus() }) {
                    Label(asset.status == .reviewed ? "Reviewed" : "Unreviewed",
                          systemImage: asset.status == .reviewed ? "checkmark.seal.fill" : "circle")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(asset.status == .reviewed
                            ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12)))
                        .foregroundColor(asset.status == .reviewed ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Tap to toggle reviewed")

                if LibrarySession.shared.isFederated,
                   let owner = LibrarySession.shared.url(for: asset.id) {
                    Text(LibrarySession.shared.shortLabel(for: owner))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.teal.opacity(0.15)))
                        .foregroundColor(.teal)
                        .help(LibrarySession.shared.fullLabel(for: owner))
                        .accessibilityLabel("In library \(LibrarySession.shared.fullLabel(for: owner))")
                }
            }

            HStack(spacing: 12) {
                Label(asset.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                if asset.playCount > 0 {
                    Label(playCountSummary, systemImage: "play.circle")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if missingAssetIDs.contains(asset.id) {
                Button("Remove Missing File") {
                    removeMissingAsset()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 4)
            }
        }
    }

    /// Browse mode: pills NAVIGATE (tap opens that actor/tag/studio page).
    /// All add/edit/delete chrome lives in the ✎ Edit sheet only.
    @ViewBuilder
    private var browsePillsSection: some View {
        browsePillRow(title: "Actors", items: asset.actors, category: "actor", color: .blue)
        creditedAsRow
        ageAtReleaseRow
        browsePillRow(title: "Tags", items: asset.actions, category: "tag", color: .green)
        browsePillRow(title: "Studios", items: asset.studios, category: "studio", color: .purple)
    }

    /// How old each credited actor was when this was released.
    ///
    /// Derived on the fly from the actor's birth date and this video's release
    /// date — nothing is stored, because either can be corrected later and a
    /// cached answer would quietly disagree with the record it came from.
    ///
    /// Shown only where it can actually be worked out. An actor with no birth
    /// date is absent rather than listed as unknown: a row of blanks is noise,
    /// and the gap is already visible on the actor's own page.
    @ViewBuilder
    private var ageAtReleaseRow: some View {
        let ages = AgeAtReleaseCalculator.ages(for: asset, profiles: actorProfiles)
        if !ages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Age at release").font(.caption).foregroundColor(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(ages.keys.sorted(), id: \.self) { name in
                        if let age = ages[name] {
                            HStack(spacing: 4) {
                                Text(name).fontWeight(.medium)
                                // An approximate figure renders as a range so
                                // it cannot be mistaken for a precise one: a
                                // birth year cannot say whether the birthday
                                // had come round yet.
                                Text(age.displayText)
                                if !age.isExact {
                                    Image(systemName: "questionmark.circle")
                                        .font(.caption2).opacity(0.6)
                                }
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.teal.opacity(0.18))
                            .foregroundColor(.teal)
                            .clipShape(Capsule())
                            .help(age.isExact
                                  ? "Exact — from a full birth date"
                                  : "Approximate — only a birth year is recorded, so this is \(age.years - 1) or \(age.years)")
                        }
                    }
                }
            }
        }
    }

    /// Names a performer was credited under in THIS video.
    ///
    /// ⭐ Shown only where one exists, and only where it differs — an "as" line
    /// repeating the cast list above would be noise on every video. The whole
    /// value of the field is that it is rare.
    ///
    /// ⚠️ Deliberately NOT a browse pill. Tapping it would have to search for a
    /// performer filed under a name the library does not use, which finds
    /// nothing; the canonical name in the row above is the one that navigates.
    @ViewBuilder
    private var creditedAsRow: some View {
        let credits = (try? LibrarySession.shared.store(for: asset.id)
            .performerCredits(forVideo: asset.id))?
            .filter { $0.creditedAs?.isEmpty == false } ?? []
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Credited As").font(.subheadline).fontWeight(.bold)
                ForEach(credits) { credit in
                    Text("\(credit.performerId.replacingOccurrences(of: "actor:", with: "")) — as \(credit.creditedAs ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Profiles for this video's cast, from whichever library owns each one.
    private var actorProfiles: EntityProfileIndex {
        var out: [EntityProfile] = []
        for name in asset.actors {
            // ⭐ Resolved by NAME. The cast name is what this has; building
            // `"actor:\(name)"` and treating it as a key stops working at the
            // re-key, and would silently return nil for every performer.
            let entityId = "actor:\(name)"
            if let profile = try? LibrarySession.shared.store(forProfile: entityId)
                .fetchEntityProfile(named: name, type: "actor") {
                out.append(profile)
            }
        }
        return EntityProfileIndex(out)
    }

    @ViewBuilder
    private func browsePillRow(title: String, items: [String], category: String, color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).fontWeight(.bold)
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        browsePill(item, category: category, color: color)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func browsePill(_ item: String, category: String, color: Color) -> some View {
        let label = HStack(spacing: 4) {
            Text(item)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundColor(color)

        #if os(iOS)
        NavigationLink(value: AppRoute.entityProfile(category: category, name: item)) {
            label
        }
        .buttonStyle(.plain)
        #else
        Button {
            pivotToEntity(item, category: category)
        } label: {
            label
        }
        .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
    private func pivotToEntity(_ item: String, category: String) {
        var pivotItem: SidebarItem
        switch category {
        case "actor": pivotItem = .actor(item)
        case "studio": pivotItem = .studio(item)
        default: pivotItem = .tag(item)
        }
        sidebarSelection = [pivotItem]
        selectedAssetBinding.removeAll()
        dismiss()
    }
    #endif

    /// The source's own synopsis, shown only when there is one.
    ///
    /// 🚨 Deliberately NOT tappable. `browseNotesSection` opens the editor
    /// because notes are the operator's to write; this text is not theirs and
    /// there is nothing here to edit. Making it look editable would invite
    /// exactly the confusion between the two that S1 exists to prevent.
    ///
    /// ⚠️ And no empty state. Notes offer "tap to add some" because the
    /// operator can act on it; a description arrives from a match or not at
    /// all, so a placeholder would report an absence nobody can do anything
    /// about.
    @ViewBuilder
    private var browseSourceDescriptionSection: some View {
        if let description = asset.sourceDescription, !description.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.subheadline).fontWeight(.bold)
                Text(description)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // ⭐ Attribution travels with the VALUE. `sourceDescriptionFrom`
                // is whoever supplied THIS text, which is not necessarily the
                // record's current `enrichmentSource` — a later match from a
                // different source that offered no description leaves the text
                // in place, and crediting it to that source would be a silent
                // lie. Showing the pair is what makes the drift visible.
                if let from = asset.sourceDescriptionFrom, !from.isEmpty {
                    Text(sourceDescriptionCredit(from: from, at: asset.sourceDescriptionAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sourceDescriptionCredit(from: String, at: Date?) -> String {
        guard let at else { return "from \(from)" }
        return "from \(from), \(at.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Read-only notes; tapping opens the Edit sheet.
    private var browseNotesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.subheadline).fontWeight(.bold)
            if let notes = asset.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundColor(.primary)
            } else {
                Text("No notes yet — tap to add some.")
                    .font(.caption)
                    .italic()
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isShowingEditSheet = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the metadata editor")
    }

    // MARK: - Edit sheet (all metadata curation in one place)

    private var editSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // This sheet OVERLAYS the details page, hiding the two
                    // things the operator is reading FROM while typing: the
                    // file name and the frames. Both are repeated here.
                    //
                    // The file name matters most — on an unreviewed video it
                    // carries the performers, tags and studio being entered,
                    // and it is encoded there for ~95% of files while the
                    // catalogue knows them for far fewer.
                    // The same context strip every editing and matching
                    // screen shows, in the same shape and closed by default —
                    // the question "what does this record already say" should
                    // not have a different answer depending on which screen
                    // asked it.
                    VideoContextPanel(asset: asset, libraryURL: libraryURL)

                    // The same escape the actor editor offers. A re-cut copy
                    // will never match a fingerprint however many times it is
                    // tried, so there has to be a way to say so and have it
                    // stick.
                    RuledOutOfLookupToggle(isRuledOut: Binding(
                        get: { asset.enrichmentState == .unmatchable },
                        set: { on in
                            // Routed through recordingOutcome rather than
                            // assigning the fields here, so ruling a video out
                            // also clears any source id from a previous match.
                            // Set directly, the id survived — leaving a video
                            // marked "not findable" while still carrying the
                            // identity of a record it was matched to, which a
                            // later run would read as evidence of a match.
                            var updated = asset
                            if on {
                                updated = VideoEnrichmentReview.recordingOutcome(
                                    updated, state: .unmatchable,
                                    source: asset.enrichmentSource)
                            } else {
                                updated.enrichmentState = nil
                                updated.enrichmentSource = nil
                                updated.enrichmentCheckedAt = nil
                                updated.enrichmentSourceId = nil
                                updated.enrichmentUrl = nil
                            }
                            if let url = libraryURL { updateAsset(updated, at: url) }
                        }
                    ), caption: "Stops this video appearing in the lookup queue.")
                    .font(.callout)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Series Name").font(.subheadline).foregroundColor(.secondary)
                        TextField("e.g. Movie Name or TV Show", text: $seriesNameDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitSeriesNameDraft() }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Season / Movie #").font(.subheadline).foregroundColor(.secondary)
                            TextField("e.g. 2", text: Binding(
                                get: { asset.seasonNumber.map(String.init) ?? "" },
                                set: { newValue in
                                    var updatedAsset = asset
                                    updatedAsset.seasonNumber = Int(newValue.trimmingCharacters(in: .whitespaces))
                                    if let url = LibrarySession.shared.url(for: asset.id) { updateAsset(updatedAsset, at: url) }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Episode #").font(.subheadline).foregroundColor(.secondary)
                            TextField("e.g. 12", text: Binding(
                                get: { asset.episodeNumber.map(String.init) ?? "" },
                                set: { newValue in
                                    var updatedAsset = asset
                                    updatedAsset.episodeNumber = Int(newValue.trimmingCharacters(in: .whitespaces))
                                    if let url = LibrarySession.shared.url(for: asset.id) { updateAsset(updatedAsset, at: url) }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Episode Title").font(.subheadline).foregroundColor(.secondary)
                        TextField("e.g. Valentine's Day (optional)", text: $episodeTitleDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitEpisodeTitleDraft() }
                    }

                    // 🚨 What this video IS, which decides whether its title may
                    // ever be sent anywhere (#59). Undeclared is a real state and
                    // is shown as such — never pre-filled, because a default kind
                    // is inference dressed as a declaration.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What is this?").font(.subheadline).foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { asset.contentKind },
                            set: { commitContentKind($0) }
                        )) {
                            Text("Not said yet").tag(ContentKind?.none)
                            ForEach(ContentKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(ContentKind?.some(kind))
                            }
                        }
                        .labelsHidden()
                        #if os(iOS)
                        .pickerStyle(.menu)
                        #endif

                        if let refusal = ProviderBoundary.refusal(for: asset.contentKind) {
                            Label(refusal.reason, systemImage: "lock.shield")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !asset.seriesTitleBlock.isEmpty {
                        Text("Sorts and files as: \(asset.seriesTitleBlock)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("External Link").font(.subheadline).foregroundColor(.secondary)
                        HStack {
                            TextField("https://...", text: Binding(
                                get: { asset.externalLink ?? "" },
                                set: { newValue in
                                    var updatedAsset = asset
                                    updatedAsset.externalLink = newValue.isEmpty ? nil : newValue
                                    if let url = LibrarySession.shared.url(for: asset.id) {
                                        updateAsset(updatedAsset, at: url)
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)

                            if let linkString = asset.externalLink, let url = URL(string: linkString) {
                                // ⚠️ In-app and private, like the actor links.
                                // This is the source's page for this scene —
                                // the single most identifying URL in the
                                // library — and handing it to the system
                                // browser writes it into a history the operator
                                // never chose to write to. "Open in Browser"
                                // is still one tap away inside.
                                Button {
                                    browsingLink = BrowsableURL(url: url)
                                } label: {
                                    Image(systemName: "safari")
                                }
                                .buttonStyle(.bordered)
                                .help("Open Link")
                                .accessibilityLabel("Open Link")
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.subheadline).foregroundColor(.secondary)
                        // Edits buffer into notesDraft and commit ~600ms after the
                        // last keystroke (plus a flush on disappear/Done).
                        TextEditor(text: $notesDraft)
                        .frame(minHeight: 80)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                        .onChange(of: notesDraft) { _, newValue in
                            guard newValue != (asset.notes ?? "") else { return }
                            notesSaveTask?.cancel()
                            notesSaveTask = Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                guard !Task.isCancelled else { return }
                                commitNotesDraft()
                            }
                        }
                    }

                    Divider()

                    tagSection(title: "Actors", items: asset.actors, category: "actor", color: .blue)
                    Divider()
                    tagSection(title: "Tags", items: asset.actions, category: "tag", color: .green)
                    Divider()
                    tagSection(title: "Studios", items: asset.studios, category: "studio", color: .purple)
                }
                .padding()
            }
            .navigationTitle("Edit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        notesSaveTask?.cancel()
                        commitNotesDraft()
                        commitSeriesNameDraft()
                        commitEpisodeTitleDraft()
                        isShowingEditSheet = false
                    }
                }
            }
            .popover(isPresented: $isShowingTagEntry) {
                tagEntryPopover
            }
            .sheet(item: $browsingLink) { target in
                PrivateBrowserView(url: target.url, title: "Source")
            }
            .alert("That tag describes a performer",
                   isPresented: Binding(get: { tagRejectionMessage != nil },
                                        set: { if !$0 { tagRejectionMessage = nil } })) {
                Button("OK", role: .cancel) { tagRejectionMessage = nil }
            } message: {
                Text(tagRejectionMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    private var sceneMarkersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Scene Markers").font(.subheadline).fontWeight(.bold)
                Spacer()
                Button {
                    // Capture the timestamp once, right now — not when the
                    // popover later renders or when Save is tapped — so the
                    // dialog's title and the saved marker always agree, even
                    // if playback continues while naming it.
                    pendingMarkerTimestamp = currentPlaybackSeconds()
                    isShowingAddMarkerPopover = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            if sceneMarkers.isEmpty {
                Text("No markers yet. Add one at the current position to jump straight back to it later.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(sceneMarkers) { marker in
                            SceneMarkerCard(
                                marker: marker,
                                libraryURL: libraryURL,
                                refreshToken: markerThumbnailRefreshID,
                                onTap: { jumpToMarker(marker) },
                                onEdit: { editingMarker = marker },
                                onDelete: { deleteMarker(marker) }
                            )
                        }
                    }
                }
            }
        }
        .popover(isPresented: $isShowingAddMarkerPopover) {
            MarkerLabelEntryView(title: "Add Marker at \(formattedTime(pendingMarkerTimestamp))", initialValue: "") { label in
                addMarker(label: label, at: pendingMarkerTimestamp)
            }
        }
        .popover(item: $editingMarker) { marker in
            MarkerLabelEntryView(title: "Rename Marker", initialValue: marker.label ?? "") { label in
                renameMarker(marker, to: label)
            }
        }
    }

    private func loadSceneMarkers() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        do {
            let store = try LibraryStore(at: url)
            sceneMarkers = try store.fetchSceneMarkers(for: asset.id)
        } catch {
            print("Failed to load scene markers: \(error)")
        }
    }

    private func addMarker(label: String, at timestampSeconds: Double) {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = SceneMarker(assetId: asset.id, timestampSeconds: timestampSeconds, label: trimmed.isEmpty ? nil : trimmed)
        do {
            let store = try LibraryStore(at: url)
            try store.saveSceneMarker(marker)
            sceneMarkers.append(marker)
            sceneMarkers.sort { $0.timestampSeconds < $1.timestampSeconds }
            Task {
                let service = ContactSheetService(store: store)
                try? await service.generateMarkerThumbnail(
                    for: asset,
                    markerId: marker.id,
                    timestampSeconds: marker.timestampSeconds,
                    libraryURL: url
                )
                await MainActor.run { markerThumbnailRefreshID = UUID() }
            }
        } catch {
            print("Failed to save scene marker: \(error)")
            AppErrorReporter.report("Couldn't save the scene marker: \(error.localizedDescription)")
        }
    }

    private func renameMarker(_ marker: SceneMarker, to label: String) {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        var updated = marker
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.label = trimmed.isEmpty ? nil : trimmed
        do {
            let store = try LibraryStore(at: url)
            try store.saveSceneMarker(updated)
            if let idx = sceneMarkers.firstIndex(where: { $0.id == updated.id }) {
                sceneMarkers[idx] = updated
            }
        } catch {
            print("Failed to rename scene marker: \(error)")
            AppErrorReporter.report("Couldn't rename the scene marker: \(error.localizedDescription)")
        }
    }

    private func deleteMarker(_ marker: SceneMarker) {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        do {
            let store = try LibraryStore(at: url)
            try store.deleteSceneMarker(id: marker.id)
            sceneMarkers.removeAll { $0.id == marker.id }
            ContactSheetService(store: store).deleteMarkerThumbnail(markerId: marker.id, libraryURL: url)
        } catch {
            print("Failed to delete scene marker: \(error)")
            AppErrorReporter.report("Couldn't delete the scene marker: \(error.localizedDescription)")
        }
    }

    private func jumpToMarker(_ marker: SceneMarker) {
        guard let url = videoURL(), !missingAssetIDs.contains(asset.id) else { return }
        scrubTime = marker.timestampSeconds
        isShowingPlayer = true
        recordPlayIfNeeded()
        playback.load(url: url, startSeconds: marker.timestampSeconds, autoplay: true)
    }

    // After a trim/flip replaced the video file in place: stop the (now stale)
    // player, reload markers, and refresh the grid so the regenerated thumbnail
    // + new duration are picked up. Cached thumbnails self-invalidate because
    // ThumbnailLoader keys on the file's modification date.
    private func handleVideoEdited() {
        playback.player.pause()
        loadSceneMarkers()
        gridRefreshID = UUID()
        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
    }

    // A direct-play quick action navigated straight to this video; start it from
    // the top. Consume the request once so it doesn't re-fire on re-appear.
    private func startAutoPlayIfRequested() {
        guard autoPlayAssetID == asset.id else { return }
        autoPlayAssetID = nil
        guard let url = videoURL(), !missingAssetIDs.contains(asset.id) else { return }
        scrubTime = 0
        isShowingPlayer = true
        recordPlayIfNeeded()
        playback.load(url: url, startSeconds: 0, autoplay: true)
    }

    // MARK: - macOS scrubber logic

    #if os(macOS)
    private func loadDuration() {
        guard let url = LibrarySession.shared.videoURL(for: asset) else { return }
        Task {
            let avAsset = AVURLAsset(url: url)
            if let dur = try? await avAsset.load(.duration) {
                let secs = CMTimeGetSeconds(dur)
                await MainActor.run {
                    self.duration = secs
                    // Default to 45s or middle of video if shorter
                    self.scrubTime = min(45.0, secs / 2.0)
                    generatePreview()
                }
            }
        }
    }

    private func generatePreview() {
        guard let url = LibrarySession.shared.videoURL(for: asset) else { return }
        Task {
            let avAsset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 480)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let time = CMTime(seconds: scrubTime, preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: time) {
                let nsImg = NSImage(cgImage: cg, size: .zero)
                await MainActor.run { self.previewFrame = nsImg }
            }
        }
    }

    private func saveNewThumbnailFromScrubTime() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        isSavingThumb = true
        Task {
            do {
                let store = try LibraryStore(at: url)
                let service = ContactSheetService(store: store)

                // If you still have a scrub-time overwrite API in your real core, use it here.
                // Otherwise, fall back to default thumbnail generation.
                if let _ = service as AnyObject? {
                    // Fallback MVP: just (re)generate the default thumbnail.
                    try await service.generateSingleThumbnail(for: asset, libraryURL: url)
                }

                await MainActor.run {
                    isSavingThumb = false
                    self.gridRefreshID = UUID()
                }
            } catch {
                print("Thumbnail save failed: \(error)")
                await MainActor.run { isSavingThumb = false }
            }
        }
    }
    #endif

    // MARK: - iOS/multi-platform generation actions

    private func regenerateDefaultThumbnail() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        isSavingThumb = true
        Task {
            do {
                let store = try LibraryStore(at: url)
                let service = ContactSheetService(store: store)
                try await service.generateSingleThumbnail(for: asset, libraryURL: url)

                await MainActor.run {
                    isSavingThumb = false
                    self.gridRefreshID = UUID()
                }
            } catch {
                print("Thumbnail generation failed: \(error)")
                await MainActor.run { isSavingThumb = false }
            }
        }
    }

    private func generateContactSheet() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        isGeneratingSheet = true
        Task {
            do {
                let store = try LibraryStore(at: url)
                let service = ContactSheetService(store: store)
                try await service.generateContactSheet(for: asset, libraryURL: url)

                await MainActor.run {
                    isGeneratingSheet = false
                    self.gridRefreshID = UUID()
                }
            } catch {
                print("Contact sheet generation failed: \(error)")
                await MainActor.run { isGeneratingSheet = false }
            }
        }
    }

    // MARK: - Tagging / metadata

    private func tagSection(title: String, items: [String], category: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.bold)
                Spacer()
                Button {
                    activeCategory = category
                    newTagValue = ""
                    editingTagValue = nil
                    isShowingTagEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(color)
                .accessibilityLabel("Add \(category)")
            }

            if items.isEmpty {
                Text("None").font(.caption).foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        #if os(iOS)
                        TagBubble(
                            label: item,
                            color: color,
                            onPivot: nil,
                            onEdit: {
                                activeCategory = category
                                newTagValue = item
                                editingTagValue = item
                                isShowingTagEntry = true
                            },
                            onDelete: {
                                deleteTag(category: category, value: item)
                            },
                            navRoute: AppRoute.entityProfile(category: category, name: item)
                        )
                        #else
                        TagBubble(label: item, color: color, onPivot: {
                            var pivotItem: SidebarItem
                            switch category {
                            case "actor": pivotItem = .actor(item)
                            case "studio": pivotItem = .studio(item)
                            default: pivotItem = .tag(item)
                            }
                            sidebarSelection = [pivotItem]
                            selectedAssetBinding.removeAll()
                            dismiss()
                        }, onEdit: {
                            activeCategory = category
                            newTagValue = item
                            editingTagValue = item
                            isShowingTagEntry = true
                        }) {
                            deleteTag(category: category, value: item)
                        }
                        #endif
                    }
                }
            }
        }
    }

    private var allLibraryTagValues: Set<String> {
        var tags = Set<String>()
        for a in assets {
            for t in a.tags {
                let parts = t.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    tags.insert(String(parts[1]))
                } else {
                    tags.insert(t)
                }
            }
        }
        return tags
    }

    private var autoExtractedTags: [String] {
        let baseSuggestions = TagSuggester.suggestions(for: asset.fileName)
        var expandedSuggestions = Set(baseSuggestions.map { TagNormalizer.normalize(tagValue: $0) })
        
        let libraryTags = allLibraryTagValues
        for suggestion in baseSuggestions {
            let capitalizedSuggestion = TagNormalizer.normalize(tagValue: suggestion)
            for existingTag in libraryTags {
                if existingTag.localizedCaseInsensitiveContains(capitalizedSuggestion) {
                    expandedSuggestions.insert(existingTag)
                }
            }
        }
        
        let appliedTagValues = Set(asset.tags.map {
            let parts = $0.split(separator: ":", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : $0
        })
        
        return expandedSuggestions.filter { !appliedTagValues.contains($0) }.sorted()
    }
    
    private var filteredLibrarySuggestions: [String] {
        guard !newTagValue.isEmpty else { return [] }
        let searchTerm = newTagValue.lowercased()
        
        var categoryTags = Set<String>()
        for a in assets {
            for t in a.tags {
                if t.hasPrefix("\(activeCategory):") {
                    let val = String(t.dropFirst(activeCategory.count + 1))
                    if val.lowercased().contains(searchTerm) && val.lowercased() != TagNormalizer.normalize(tagValue: newTagValue).lowercased() {
                        categoryTags.insert(val)
                    }
                }
            }
        }
        return categoryTags.sorted()
    }

    private var tagEntryPopover: some View {
        VStack(spacing: 12) {
            Text(editingTagValue == nil ? "Add \(activeCategory.capitalized)" : "Edit \(activeCategory.capitalized)")
                .font(.headline)
            TextField("Name...", text: $newTagValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTag() }
                
            let matchingTags = filteredLibrarySuggestions
            if !matchingTags.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matchingTags, id: \.self) { match in
                            Button {
                                newTagValue = match
                                saveTag()
                            } label: {
                                Text(match)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                .frame(maxHeight: 150)
            }

            Button("Save") { saveTag() }
                .buttonStyle(.borderedProminent)
                
            let suggestions = autoExtractedTags
            if !suggestions.isEmpty {
                Divider()
                Text("Suggestions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                newTagValue = suggestion
                                saveTag()
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 280, height: 350, alignment: .top)
        #else
        .frame(minWidth: 200, maxWidth: 300)
        #endif
    }
    

    private func toggleStatus() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        var updated = asset
        updated.status = (asset.status == .reviewed) ? .unreviewed : .reviewed
        updateAsset(updated, at: url)
    }

    private func saveTag() {
        guard !newTagValue.isEmpty, let url = LibrarySession.shared.url(for: asset.id) else { return }
        var updated = asset
        let normalizedValue = TagNormalizer.normalize(tagValue: newTagValue)
        let tagToSave = "\(activeCategory):\(normalizedValue)"
        
        if let editingTag = editingTagValue {
            let oldTag = "\(activeCategory):\(editingTag)"
            updated.tags.removeAll { $0 == oldTag }
            editingTagValue = nil
        }
        
        if !updated.tags.contains(tagToSave) {
            updated.tags.append(tagToSave)
        }

        // The write boundary. A tag the vocabulary says describes a PERFORMER
        // cannot be added to a video — "a video isn't a tall, an actor is."
        // A tag with no kind yet is allowed through: refusing it would mean no
        // new tag could ever be created, and there is nowhere yet to stage the
        // link. It surfaces in Settings → Classify Tags instead.
        if activeCategory == "tag" {
            let vocabulary = (try? LibraryStore(at: url).fetchTagVocabulary()) ?? []
            let check = TagVocabulary.check(adding: updated, against: asset,
                                            vocabulary: vocabulary)
            guard check.isAllowed else {
                tagRejectionMessage = "\"\(check.refused.joined(separator: ", "))\" describes a performer, not a video. Add it to the performer instead."
                return
            }
        }

        updateAsset(updated, at: url)
        newTagValue = ""
        isShowingTagEntry = false
    }

    private func deleteTag(category: String, value: String) {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        var updated = asset
        updated.tags.removeAll { $0 == "\(category):\(value)" }
        updateAsset(updated, at: url)
    }

    private var playCountSummary: String {
        let timesText = "Played \(asset.playCount) time\(asset.playCount == 1 ? "" : "s")"
        guard let lastPlayedAt = asset.lastPlayedAt else { return timesText }
        return "\(timesText), last on \(lastPlayedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func recordPlayIfNeeded() {
        guard !hasRecordedPlayThisSession, let url = LibrarySession.shared.url(for: asset.id) else { return }
        hasRecordedPlayThisSession = true
        var updated = asset
        updated.playCount += 1
        updated.lastPlayedAt = Date()
        updateAsset(updated, at: url)
    }

    private func commitNotesDraft() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        let newNotes = notesDraft.isEmpty ? nil : notesDraft
        guard newNotes != asset.notes else { return }
        var updated = asset
        updated.notes = newNotes
        updateAsset(updated, at: url)
    }

    private func commitSeriesNameDraft() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        let titleCased = TagNormalizer.titleCased(seriesNameDraft)
        // Reflect the normalized form back into the field so the user sees it.
        if seriesNameDraft != titleCased { seriesNameDraft = titleCased }
        let newName = titleCased.isEmpty ? nil : titleCased
        guard newName != asset.videoName else { return }
        var updated = asset
        updated.videoName = newName
        updateAsset(updated, at: url)
    }

    private func commitContentKind(_ kind: ContentKind?) {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        guard kind != asset.contentKind else { return }
        var updated = asset
        updated.contentKind = kind
        updateAsset(updated, at: url)
    }

    private func commitEpisodeTitleDraft() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        let titleCased = TagNormalizer.titleCased(episodeTitleDraft)
        // Reflect the normalized form back into the field so the user sees it.
        if episodeTitleDraft != titleCased { episodeTitleDraft = titleCased }
        let newEpisode = titleCased.isEmpty ? nil : titleCased
        guard newEpisode != asset.episode else { return }
        var updated = asset
        updated.episode = newEpisode
        updateAsset(updated, at: url)
    }

    /// The installed video source's own name, or nil when none is installed.
    private var videoMetadataSourceName: String? {
        PluginEnvironment.registry.installedVideoProviders().first?.displayName
    }

    /// Every plain tag already used anywhere in the open libraries.
    ///
    /// This is what decides which suggested tags arrive pre-ticked. Drawn from
    /// the whole library rather than this video: the question is whether the
    /// operator uses a term at all, not whether this particular video has it.
    private var knownTagVocabulary: Set<String> {
        Set(assets.flatMap { $0.actions })
    }

    private func updateAsset(_ updated: Asset, at url: URL) {
        do {
            let store = try LibraryStore(at: url)
            try store.updateAsset(updated)
            if let index = assets.firstIndex(where: { $0.id == updated.id }) {
                assets[index] = updated
            }
        } catch {
            print("Update failed: \(error)")
            AppErrorReporter.report("Couldn't save changes to \(updated.fileName): \(error.localizedDescription)")
        }
    }
    
    private func removeMissingAsset() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }
        do {
            let store = try LibraryStore(at: url)
            try store.deleteAsset(asset)
            assets.removeAll { $0.id == asset.id }
            selectedAssetBinding.remove(asset.id)
            missingAssetIDs.remove(asset.id)
        } catch {
            print("Failed to remove missing asset: \(error)")
            AppErrorReporter.report("Couldn't remove the missing file's entry: \(error.localizedDescription)")
        }
    }

    private func performRename() {
        guard let url = LibrarySession.shared.url(for: asset.id),
              let store = try? LibraryStore(at: url) else { return }
        let renamer = FileRenamerService(store: store)
        var updated = asset
        do {
            try renamer.rename(asset: &updated, newFileName: suggestedRenameValue, libraryURL: url)
            updateAsset(updated, at: url)
            isShowingRenameDialog = false
        } catch {
            print("Failed to rename: \(error)")
            AppErrorReporter.report("Couldn't rename the file: \(error.localizedDescription)")
        }
    }

    private func deleteVideo() {
        guard let url = LibrarySession.shared.url(for: asset.id) else { return }

        // One shared implementation of "delete a video" (DEFECT_INVENTORY M5):
        // this used to be a hand-rolled copy of VideoTransferService's logic
        // and the two had drifted. The service is the hardened path — video
        // file first (a throw aborts with the catalog intact), then sidecar,
        // marker previews, poster, contact sheet, and fingerprint entry, DB
        // row last.
        do {
            try VideoTransferService().deleteVideoAndArtifacts(asset, in: url, toTrash: true)

            // Clear selection and close inspector
            selectedAssetBinding.removeAll()

            // Remove from global assets list
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                assets.remove(at: index)
            }
        } catch {
            print("Failed to delete video: \(error)")
            AppErrorReporter.report("Couldn't delete the video, so it was NOT removed from the library: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func videoURL() -> URL? {
        LibrarySession.shared.videoURL(for: asset)
    }

    // macOS-only “open file”
    #if os(macOS)
    private func openFile() {
        if let url = LibrarySession.shared.videoURL(for: asset) {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}

// MARK: - Scene Marker Card

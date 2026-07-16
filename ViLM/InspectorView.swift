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
                contextAssetIDs: contextAssetIDs
            )
            .id(asset.id)
        } else {
            ContentUnavailableView("Selection Lost", systemImage: "questionmark")
        }
    }
}

struct SingleInspectorView: View {
    @Binding var sidebarSelection: Set<SidebarItem>
    let asset: Asset
    @Binding var assets: [Asset]
    @Binding var selectedAssetBinding: Set<Asset.ID>
    @Binding var gridRefreshID: UUID
    let libraryURL: URL?
    @Binding var missingAssetIDs: Set<Asset.ID>
    let contextAssetIDs: [Asset.ID]
    
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    @State private var activeCategory = "tag"
    @State private var editingTagValue: String? = nil
    @State private var isShowingRenameDialog = false
    @State private var suggestedRenameValue = ""
    @State private var showDeleteConfirmation = false
    @State private var isShowingHelp = false
    
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
    @State private var isShowingSuggestActors = false

    // Notes editing buffer (see annotationsSection for why edits are
    // debounced instead of bound directly to the asset).
    @State private var notesDraft: String = ""
    @State private var notesSaveTask: Task<Void, Never>?

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

                // High-Res Frame Grid (this is your iOS “scrub” replacement)
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

                Text(asset.fileName)
                    .font(.headline)
                    .lineLimit(nil)

                HStack {
                    Text("Metadata")
                        .font(.headline)
                        .padding(.vertical, 8)
                    
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
                        .padding(.trailing, 8)
                    }

                    if missingAssetIDs.contains(asset.id) {
                        Button("Remove Missing File") {
                            removeMissingAsset()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else if asset.suggestedFileNameFromTags != nil {
                        Button("Rename File") {
                            suggestedRenameValue = asset.suggestedFileNameFromTags ?? asset.fileName
                            isShowingRenameDialog = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)

                Divider()

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

                Divider()

                sceneMarkersSection

                Divider()

                // Thumbnail + Contact Sheet actions
                thumbnailAndContactSheetSection

                Divider()

                // Metadata & Status Toggle
                VStack(alignment: .leading, spacing: 12) {
                    Button(action: { toggleStatus() }) {
                        Label {
                            Text("Status: \(asset.status.rawValue.capitalized)")
                        } icon: {
                            Image(systemName: asset.status == .reviewed ? "checkmark.seal.fill" : "circle")
                                .foregroundColor(asset.status == .reviewed ? .green : .secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Label("Added: \(asset.createdAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if asset.playCount > 0 {
                        Label(playCountSummary, systemImage: "play.circle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Series Name").font(.subheadline).foregroundColor(.secondary)
                        TextField("e.g. Movie Name or TV Show", text: Binding(
                            get: { asset.videoName ?? "" },
                            set: { newValue in
                                var updatedAsset = asset
                                updatedAsset.videoName = newValue.isEmpty ? nil : newValue
                                if let url = libraryURL { updateAsset(updatedAsset, at: url) }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Season / Movie #").font(.subheadline).foregroundColor(.secondary)
                            TextField("e.g. 2", text: Binding(
                                get: { asset.seasonNumber.map(String.init) ?? "" },
                                set: { newValue in
                                    var updatedAsset = asset
                                    updatedAsset.seasonNumber = Int(newValue.trimmingCharacters(in: .whitespaces))
                                    if let url = libraryURL { updateAsset(updatedAsset, at: url) }
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
                                    if let url = libraryURL { updateAsset(updatedAsset, at: url) }
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
                        TextField("e.g. Valentine's Day (optional)", text: Binding(
                            get: { asset.episode ?? "" },
                            set: { newValue in
                                var updatedAsset = asset
                                updatedAsset.episode = newValue.isEmpty ? nil : newValue
                                if let url = libraryURL { updateAsset(updatedAsset, at: url) }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
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
                                    if let url = libraryURL {
                                        updateAsset(updatedAsset, at: url)
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)

                            if let linkString = asset.externalLink, let url = URL(string: linkString) {
                                Button {
                                    #if os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #else
                                    UIApplication.shared.open(url)
                                    #endif
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
                }

                annotationsSection
                Divider()

                tagSection(title: "Studios", items: asset.studios, category: "studio", color: .purple)
                Divider()
                tagSection(title: "Actors", items: asset.actors, category: "actor", color: .blue, showSuggestButton: true)
                Divider()
                tagSection(title: "Tags", items: asset.actions, category: "tag", color: .green)

                Color.clear.frame(height: 40)

                // Keep this button for macOS (scrubber semantics). On iOS, grid tap already does the job.
                #if os(macOS)
                HStack {
                    Button {
                        if let url = videoURL() {
                            isShowingPlayer = true
                            recordPlayIfNeeded()
                            playback.load(url: url, startSeconds: scrubTime, autoplay: true)
                        }
                    } label: {
                        Label("Play from Scrubber", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                #endif
                
                Divider()
                DisclosureGroup("Danger Zone") {
                    Button(role: .destructive, action: {
                        showDeleteConfirmation = true
                    }) {
                        Label("Delete Video", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.top, 4)
                }
                .tint(.red)
            }
            .padding()
        }
        .frame(minWidth: 300)
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
        .popover(isPresented: $isShowingTagEntry) {
            tagEntryPopover
        }
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
        .sheet(isPresented: $isShowingSuggestActors) {
            if let url = libraryURL {
                SuggestActorsView(asset: asset, libraryURL: url, onAddActor: addActorTag)
            }
        }
        .onAppear {
            #if os(macOS)
            loadDuration()
            #endif
            loadSceneMarkers()
            notesDraft = asset.notes ?? ""
        }
        .onDisappear {
            // Commit any un-debounced notes edit before the view goes away,
            // and stop audio — on iPhone, pushing deeper (e.g. tapping an
            // actor tag) keeps this view alive in the navigation stack, so
            // without this the video kept playing underneath the new screen.
            notesSaveTask?.cancel()
            commitNotesDraft()
            playback.player.pause()
        }
        .onChange(of: asset.id) { _, _ in
            #if os(macOS)
            loadDuration()
            #endif
            loadSceneMarkers()
            notesDraft = asset.notes ?? ""
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
        guard let url = libraryURL else { return }
        do {
            let store = try LibraryStore(at: url)
            sceneMarkers = try store.fetchSceneMarkers(for: asset.id)
        } catch {
            print("Failed to load scene markers: \(error)")
        }
    }

    private func addMarker(label: String, at timestampSeconds: Double) {
        guard let url = libraryURL else { return }
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
        guard let url = libraryURL else { return }
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
        guard let url = libraryURL else { return }
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

    // MARK: - Thumbnail + Contact sheet section

    @ViewBuilder
    private var thumbnailAndContactSheetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media Outputs")
                .font(.subheadline)
                .fontWeight(.bold)

            #if os(macOS)
            // --- THUMBNAIL SCRUBBER (macOS only) ---
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

            Button("Set as Main Thumbnail") {
                saveNewThumbnailFromScrubTime()
            }
            .disabled(isSavingThumb)
            .controlSize(.small)

            #else
            // iOS MVP: no scrubber. Just regenerate using default heuristic time.
            HStack {
                Button {
                    regenerateDefaultThumbnail()
                } label: {
                    Label(isSavingThumb ? "Generating…" : "Regenerate Thumbnail", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(isSavingThumb)

                Button {
                    generateContactSheet()
                } label: {
                    Label(isGeneratingSheet ? "Generating…" : "Generate Contact Sheet", systemImage: "square.grid.3x3")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGeneratingSheet)
            }
            #endif

            // Contact sheet is useful on macOS too; keep button for both
            #if os(macOS)
            Button {
                generateContactSheet()
            } label: {
                Label(isGeneratingSheet ? "Generating…" : "Generate Contact Sheet", systemImage: "square.grid.3x3")
            }
            .buttonStyle(.bordered)
            .disabled(isGeneratingSheet)
            #endif
        }
    }

    // MARK: - macOS scrubber logic

    #if os(macOS)
    private func loadDuration() {
        guard let url = libraryURL?.appendingPathComponent(asset.relativePath) else { return }
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
        guard let url = libraryURL?.appendingPathComponent(asset.relativePath) else { return }
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
        guard let url = libraryURL else { return }
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
        guard let url = libraryURL else { return }
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
        guard let url = libraryURL else { return }
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

    private func tagSection(title: String, items: [String], category: String, color: Color, showSuggestButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.bold)
                Spacer()
                if showSuggestButton {
                    Button {
                        isShowingSuggestActors = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(color)
                    .help("Suggest Actors From This Video's Faces")
                    .accessibilityLabel("Suggest Actors")
                }
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
    
    private var annotationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Annotations").font(.subheadline).fontWeight(.bold)
            
            HStack {
                Text("Rating:").font(.subheadline).foregroundColor(.secondary)
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
                            if let url = libraryURL { updateAsset(updated, at: url) }
                        }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.subheadline).foregroundColor(.secondary)
                // Edits buffer into notesDraft and commit ~600ms after the
                // last keystroke (plus a flush on disappear). Binding the
                // editor straight to the asset meant one SQLite UPDATE *and*
                // one mutation of the app-wide assets array per keystroke —
                // every keystroke re-triggered grid refiltering everywhere.
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
        }
    }

    private func toggleStatus() {
        guard let url = libraryURL else { return }
        var updated = asset
        updated.status = (asset.status == .reviewed) ? .unreviewed : .reviewed
        updateAsset(updated, at: url)
    }

    private func saveTag() {
        guard !newTagValue.isEmpty, let url = libraryURL else { return }
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
        
        updateAsset(updated, at: url)
        newTagValue = ""
        isShowingTagEntry = false
    }

    private func deleteTag(category: String, value: String) {
        guard let url = libraryURL else { return }
        var updated = asset
        updated.tags.removeAll { $0 == "\(category):\(value)" }
        updateAsset(updated, at: url)
    }

    private func addActorTag(_ name: String) {
        guard let url = libraryURL else { return }
        var updated = asset
        let tagToSave = "actor:\(name)"
        if !updated.tags.contains(tagToSave) {
            updated.tags.append(tagToSave)
        }
        updateAsset(updated, at: url)
    }

    private var playCountSummary: String {
        let timesText = "Played \(asset.playCount) time\(asset.playCount == 1 ? "" : "s")"
        guard let lastPlayedAt = asset.lastPlayedAt else { return timesText }
        return "\(timesText), last on \(lastPlayedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func recordPlayIfNeeded() {
        guard !hasRecordedPlayThisSession, let url = libraryURL else { return }
        hasRecordedPlayThisSession = true
        var updated = asset
        updated.playCount += 1
        updated.lastPlayedAt = Date()
        updateAsset(updated, at: url)
    }

    private func commitNotesDraft() {
        guard let url = libraryURL else { return }
        let newNotes = notesDraft.isEmpty ? nil : notesDraft
        guard newNotes != asset.notes else { return }
        var updated = asset
        updated.notes = newNotes
        updateAsset(updated, at: url)
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
        guard let url = libraryURL else { return }
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
        guard let url = libraryURL, let store = try? LibraryStore(at: url) else { return }
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
        guard let url = libraryURL else { return }
        
        let videoURL = url.appendingPathComponent(asset.relativePath)
        let sidecarURL = videoURL.deletingPathExtension().appendingPathExtension("json")
        let thumbnailURL = url.appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg")
        let contactSheetURL = url.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg")
        
        // Trash/Delete physical files
        do {
            try FileManager.default.trashItem(at: videoURL, resultingItemURL: nil)
        } catch {
            print("Failed to trash video: \(error)")
            AppErrorReporter.report("Couldn't move the video file to the Trash: \(error.localizedDescription)")
        }
        
        do {
            try FileManager.default.trashItem(at: sidecarURL, resultingItemURL: nil)
        } catch {
            print("Failed to trash sidecar: \(error)")
        }
        
        try? FileManager.default.removeItem(at: thumbnailURL)
        try? FileManager.default.removeItem(at: contactSheetURL)
        
        // Remove from DB and memory
        do {
            let store = try LibraryStore(at: url)
            try store.deleteAsset(asset)
            
            // Clear selection and close inspector
            selectedAssetBinding.removeAll()
            
            // Remove from global assets list
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                assets.remove(at: index)
            }
        } catch {
            print("Failed to delete asset from store: \(error)")
            AppErrorReporter.report("Couldn't remove the video from the library: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func videoURL() -> URL? {
        guard let libraryURL else { return nil }
        return libraryURL.appendingPathComponent(asset.relativePath)
    }

    // macOS-only “open file”
    #if os(macOS)
    private func openFile() {
        if let url = libraryURL?.appendingPathComponent(asset.relativePath) {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}

// MARK: - Scene Marker Card

private struct SceneMarkerCard: View {
    let marker: SceneMarker
    let libraryURL: URL?
    let refreshToken: UUID
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var cgImage: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let cgImage {
                        Image(decorative: cgImage, scale: 1.0, orientation: .up)
                            .resizable()
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay(ProgressView())
                    }
                }
                .frame(width: 140)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(marker.formattedTimestamp)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            #if os(macOS)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif

            HStack(spacing: 4) {
                Text(marker.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 108, alignment: .leading)

                Menu {
                    Button("Rename", action: onEdit)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .task(id: "\(marker.id)|\(refreshToken)") {
            guard let libraryURL else { return }
            let url = libraryURL.appendingPathComponent(".catalog/markers/\(marker.id.uuidString).jpg")
            cgImage = await ThumbnailLoader.image(from: url, maxPixelSize: 400)
        }
    }
}

// MARK: - Marker Label Entry Popover

private struct MarkerLabelEntryView: View {
    let title: String
    let initialValue: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Marker name (optional)", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(minWidth: 240)
        .onAppear { text = initialValue }
    }

    private func save() {
        onSave(text)
        dismiss()
    }
}

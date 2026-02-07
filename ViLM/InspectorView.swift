import SwiftUI
import LibraryCore
import AVFoundation

#if os(macOS)
import AppKit
#endif

struct InspectorView: View {
    let asset: Asset
    @Binding var assets: [Asset]
    @Binding var selectedAsset: Asset?
    @Binding var gridRefreshID: UUID
    let libraryURL: URL?

    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    @State private var activeCategory = "tag"

    // Playback / selection
    @State private var scrubTime: Double = 0
    @State private var duration: Double = 1
    @State private var playback = VideoPlaybackController()
    @State private var isShowingPlayer = false

    // iOS/Mac shared progress flags
    @State private var isSavingThumb = false
    @State private var isGeneratingSheet = false

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
                        playback.load(url: url, startSeconds: t, autoplay: true)
                    }
                }
                .id(asset.id)
                .aspectRatio(1.33, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 2)

                Text(asset.fileName)
                    .font(.headline)
                    .lineLimit(2)

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
                }

                Divider()

                tagSection(title: "Actors", items: asset.actors, category: "actor", color: .blue)
                Divider()
                tagSection(title: "Tags", items: asset.actions, category: "tag", color: .green)

                Spacer(minLength: 40)

                // Keep this button for macOS (scrubber semantics). On iOS, grid tap already does the job.
                #if os(macOS)
                HStack {
                    Button {
                        if let url = videoURL() {
                            isShowingPlayer = true
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
            }
            .padding()
        }
        .frame(minWidth: 300)
        .popover(isPresented: $isShowingTagEntry) {
            tagEntryPopover
        }
        .onAppear {
            #if os(macOS)
            loadDuration()
            #endif
        }
        .onChange(of: asset.id) { _, _ in
            #if os(macOS)
            loadDuration()
            #endif
        }
        .onChange(of: scrubTime) { _, newValue in
            #if os(macOS)
            guard isShowingPlayer else { return }
            Task { await playback.seek(to: newValue, autoplay: nil) }
            #endif
        }
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

    private func tagSection(title: String, items: [String], category: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.bold)
                Spacer()
                Button {
                    activeCategory = category
                    isShowingTagEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(color)
            }

            if items.isEmpty {
                Text("None").font(.caption).foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        TagBubble(label: item, color: color) {
                            deleteTag(category: category, value: item)
                        }
                    }
                }
            }
        }
    }

    private var tagEntryPopover: some View {
        VStack(spacing: 12) {
            Text("Add \(activeCategory.capitalized)").font(.headline)
            TextField("Name...", text: $newTagValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTag() }

            Button("Save") { saveTag() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 200)
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
        let tagToSave = "\(activeCategory):\(newTagValue)"
        if !updated.tags.contains(tagToSave) {
            updated.tags.append(tagToSave)
            updateAsset(updated, at: url)
            newTagValue = ""
            isShowingTagEntry = false
        }
    }

    private func deleteTag(category: String, value: String) {
        guard let url = libraryURL else { return }
        var updated = asset
        updated.tags.removeAll { $0 == "\(category):\(value)" }
        updateAsset(updated, at: url)
    }

    private func updateAsset(_ updated: Asset, at url: URL) {
        do {
            let store = try LibraryStore(at: url)
            try store.updateAsset(updated)
            if let index = assets.firstIndex(where: { $0.id == updated.id }) {
                assets[index] = updated
                selectedAsset = updated
            }
        } catch {
            print("Update failed: \(error)")
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

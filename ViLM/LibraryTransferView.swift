// LibraryTransferView.swift
// Settings tool: move videos between the open library and a second one you
// pick, a few at a time, with destination free-space gating; and reconcile
// videos that exist in both libraries (content-hash confirmed) by choosing
// which copy to keep. All heavy work (hashing, copying) runs off the main
// thread; every move copies-and-verifies before deleting the source.

import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

struct LibraryTransferView: View {
    @Environment(\.dismiss) private var dismiss

    /// The library currently open in the app.
    let openLibraryURL: URL
    let onRefresh: () -> Void

    enum Mode: String, CaseIterable { case move = "Move Videos", duplicates = "Duplicates" }

    @State private var otherLibraryURL: URL?
    @State private var otherIsScoped = false
    @State private var isShowingPicker = false
    // Move direction: the open library is the source when true.
    @State private var sourceIsOpen = false
    @State private var mode: Mode = .move
    @State private var errorMessage: String?

    // Move state
    @State private var moveRows: [MoveRow] = []
    @State private var selectedForMove: Set<UUID> = []
    @State private var isLoadingMoveList = false
    @State private var isMoving = false
    @State private var moveProgress: String = ""
    @State private var moveSummary: String?
    @State private var moveAlphaFilter: Character? = nil

    // Advanced filter, shared verbatim with the All Assets grid (same criteria
    // model, same builder UI, same LibraryCore matching) so a user can move
    // just the highly-rated / unreviewed / specific-actor subset. The source
    // library's profiles + AKA map power the actor-metadata filters.
    @State private var filterCriteria = AssetFilterCriteria()
    @State private var sourceEntityProfiles: EntityProfileIndex = .empty
    @State private var sourceAkaMap: [String: String] = [:]
    @State private var isShowingFilter = false

    private var filteredMoveRows: [MoveRow] {
        moveRows.filter { row in
            if let letter = moveAlphaFilter,
               !(row.asset.videoName ?? row.asset.fileName).uppercased().hasPrefix(String(letter)) {
                return false
            }
            if !filterCriteria.isEmpty {
                let mapped = AssetFilterCriteria.mappedActors(for: row.asset, akaMap: sourceAkaMap)
                if !filterCriteria.matches(row.asset, mappedActors: mapped, entityProfiles: sourceEntityProfiles) {
                    return false
                }
            }
            return true
        }
    }

    // Duplicate state
    @State private var dupMatches: [DupMatch] = []
    @State private var isScanningDups = false
    @State private var dupScanProgress: String = ""
    @State private var didScanDups = false
    @State private var isApplyingDups = false
    @State private var dupSummary: String?
    @State private var dupApplyNote: String?

    // These value types are built on a background task (the scan/list load)
    // and read on the main actor, so they're `nonisolated` + `Sendable` to
    // cross the boundary cleanly under the project's default main-actor
    // isolation.
    nonisolated struct MoveRow: Identifiable, Sendable {
        let asset: Asset
        let sizeBytes: Int64
        var id: UUID { asset.id }
    }

    // Per-duplicate decision. Defaults to `.skip` so nothing is deleted
    // unless the user actively chooses a copy to keep — a duplicate can be
    // left undecided and revisited later.
    nonisolated enum KeepSide: Sendable { case open, other, skip }
    nonisolated struct DupMatch: Identifiable, Sendable {
        let id = UUID()
        let openAsset: Asset
        let otherAsset: Asset
        let sizeBytes: Int64
        var keep: KeepSide = .skip
    }

    // MARK: - Derived

    private var sourceURL: URL { sourceIsOpen ? openLibraryURL : (otherLibraryURL ?? openLibraryURL) }
    private var destinationURL: URL { sourceIsOpen ? (otherLibraryURL ?? openLibraryURL) : openLibraryURL }
    private var selectedSize: Int64 { moveRows.filter { selectedForMove.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes } }
    private var destinationFreeSpace: Int64? { Self.freeSpace(at: destinationURL) }
    private var fitsInDestination: Bool {
        guard let free = destinationFreeSpace else { return true }
        return selectedSize <= free
    }

    var body: some View {
        NavigationStack {
            Group {
                if otherLibraryURL == nil {
                    chooseLibraryPrompt
                } else {
                    loadedContent
                }
            }
            .navigationTitle("Move Videos Between Libraries")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
            .fileImporter(
                isPresented: $isShowingPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handlePickedLibrary(result)
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage ?? "") }
        }
        // Size the window on macOS only. On iPhone a fixed minWidth forces the
        // content wider than the (compact) screen, clipping the left/right
        // edges; the sheet should just fill the available width instead.
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .onDisappear { stopOtherScope() }
        // A swipe-dismiss mid-operation shouldn't be possible; and if the view
        // is torn down anyway, each batch operation holds its own security-
        // scope claims (ScopedOperation), so stopOtherScope above can't cut
        // off in-flight file access (DEFECT_INVENTORY H5).
        .interactiveDismissDisabled(isMoving || isScanningDups || isApplyingDups)
    }

    // MARK: - Choose library

    private var chooseLibraryPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Pick the other library folder")
                .font(.headline)
            Text("Choose the second ViLM library folder to move videos to or from. Videos are copied and verified before the original is removed, so nothing is lost mid-transfer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Choose Other Library…") { isShowingPicker = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.top, 40)
    }

    // MARK: - Loaded content

    private var loadedContent: some View {
        VStack(spacing: 0) {
            directionHeader
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .move: moveSection
            case .duplicates: duplicatesSection
            }
        }
    }

    private var directionHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                libraryChip(title: "Source", url: sourceURL)
                Button {
                    withAnimation { sourceIsOpen.toggle() }
                    resetTransientState()
                    // Source changed, so the movable-videos list must be
                    // rebuilt from the new source library.
                    loadMoveList()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .help("Swap source and destination")
                .accessibilityLabel("Swap source and destination")
                libraryChip(title: "Destination", url: destinationURL)
            }
            Text("Destination free space: \(destinationFreeSpace.map(Self.byteString) ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func libraryChip(title: String, url: URL) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Move section

    @ViewBuilder
    private var moveSection: some View {
        if isLoadingMoveList {
            Spacer(); ProgressView("Reading source library…"); Spacer()
        } else if let summary = moveSummary {
            resultView(icon: "checkmark.circle.fill", tint: .green, title: "Move Complete", message: summary) {
                moveSummary = nil
                loadMoveList()
            }
        } else if moveRows.isEmpty {
            Spacer()
            ContentUnavailableView("No Videos to Move", systemImage: "film",
                description: Text("The source library has no videos, or none whose files are present on disk."))
            Spacer()
        } else {
            VStack(spacing: 0) {
                moveFilterBar
                AlphaPickerView(filter: $moveAlphaFilter)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                ScrollView {
                    if filteredMoveRows.isEmpty {
                        ContentUnavailableView(
                            "No Matching Videos",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("No video in the source library matches the current filter. Clear it to see everything.")
                        )
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                            ForEach(filteredMoveRows) { row in
                                moveCard(row)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }
                }
                moveFooter
            }
            .sheet(isPresented: $isShowingFilter) {
                FilterBuilderView(
                    assets: moveRows.map(\.asset),
                    criteria: $filterCriteria,
                    actorProfiles: sourceEntityProfiles
                )
            }
        }
    }

    // Filter control bar for the move list, mirroring the All Assets grid's
    // advanced filter (same builder, same criteria) plus a live match count.
    private var moveFilterBar: some View {
        HStack(spacing: 12) {
            Button {
                isShowingFilter = true
            } label: {
                Label("Filter", systemImage: filterCriteria.isEmpty
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            if !filterCriteria.isEmpty {
                Button("Clear") { filterCriteria = AssetFilterCriteria() }
                    .font(.callout)
            }
            Spacer()
            Text("\(filteredMoveRows.count) of \(moveRows.count)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("\(filteredMoveRows.count) of \(moveRows.count) videos shown")
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // A poster-card version of the row, matching the All Assets grid: thumbnail
    // (from the source library's cache) with a selection check, the series/file
    // name, and the file size.
    private func moveCard(_ row: MoveRow) -> some View {
        let selected = selectedForMove.contains(row.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                VideoThumbnailView(asset: row.asset, libraryURL: sourceURL)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .padding(4)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .padding(6)
            }
            Text(row.asset.videoName ?? row.asset.fileName)
                .font(.caption).lineLimit(2)
            Text(Self.byteString(row.sizeBytes))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selected { selectedForMove.remove(row.id) } else { selectedForMove.insert(row.id) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.asset.videoName ?? row.asset.fileName), \(Self.byteString(row.sizeBytes))")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var moveFooter: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(selectedForMove.count) selected · \(Self.byteString(selectedSize))")
                    .font(.caption)
                Spacer()
                if !fitsInDestination {
                    Label("Won't fit", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Button {
                Task { await runMove() }
            } label: {
                Text(isMoving ? moveProgress : "Move \(selectedForMove.count) to \(destinationURL.lastPathComponent)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedForMove.isEmpty || !fitsInDestination || isMoving)
        }
        .padding()
    }

    // MARK: - Duplicates section

    @ViewBuilder
    private var duplicatesSection: some View {
        if isScanningDups {
            Spacer()
            VStack(spacing: 10) {
                ProgressView()
                Text(dupScanProgress.isEmpty ? "Scanning…" : dupScanProgress)
                    .font(.callout).foregroundStyle(.secondary)
                Text("Confirming matches by reading each candidate's full contents — this can take a while for large videos.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()
        } else if let summary = dupSummary {
            resultView(icon: "checkmark.circle.fill", tint: .green, title: "Done", message: summary) {
                dupSummary = nil
                dupApplyNote = nil
                didScanDups = false
                dupMatches = []
            }
        } else if !didScanDups {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "square.on.square.dashed").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Find videos that exist in both libraries. Candidates are matched by size and duration, then confirmed byte-for-byte before anything can be deleted.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Scan for Duplicates") { Task { await scanDuplicates() } }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        } else if dupMatches.isEmpty {
            Spacer()
            ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.seal",
                description: Text("No video in this library is byte-for-byte identical to one in the other library."))
            Spacer()
        } else {
            let decidedCount = dupMatches.filter { $0.keep != .skip }.count
            List {
                Section {
                    Text("These \(dupMatches.count) video\(dupMatches.count == 1 ? " exists" : "s exist") in both libraries. For each, choose which copy to keep (the other is deleted to the Trash) — or leave it on Skip to decide later.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = dupApplyNote {
                        Label(note, systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                ForEach($dupMatches) { $match in
                    dupRow($match)
                }
            }
            Button {
                Task { await applyDuplicateChoices() }
            } label: {
                Text(isApplyingDups ? "Deleting…" : "Delete \(decidedCount) unwanted cop\(decidedCount == 1 ? "y" : "ies")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isApplyingDups || decidedCount == 0)
            .padding()
        }
    }

    private func dupRow(_ match: Binding<DupMatch>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Both copies are byte-identical, so one thumbnail identifies
                // the video; prefer the open library's, fall back to the other.
                DuplicateThumbnail(url: thumbnailURL(for: match.wrappedValue))
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.wrappedValue.openAsset.videoName ?? match.wrappedValue.openAsset.fileName)
                        .font(.callout).fontWeight(.medium).lineLimit(2)
                    Text(match.wrappedValue.openAsset.relativePath)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(Self.byteString(match.wrappedValue.sizeBytes))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Picker("Keep", selection: match.keep) {
                Text(openLibraryURL.lastPathComponent).tag(KeepSide.open)
                Text(otherLibraryURL?.lastPathComponent ?? "Other").tag(KeepSide.other)
                Text("Skip").tag(KeepSide.skip)
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared result view

    private func resultView(icon: String, tint: Color, title: String, message: String, onContinue: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("Continue") { onContinue() }.buttonStyle(.bordered)
            Spacer()
        }
    }

    // MARK: - Actions

    private func handlePickedLibrary(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = "Couldn't open that folder: \(error.localizedDescription)"
        case .success(let urls):
            guard let picked = urls.first else { return }
            if picked.standardizedFileURL == openLibraryURL.standardizedFileURL {
                errorMessage = "That's the library that's already open. Pick a different folder."
                return
            }
            stopOtherScope()
            otherIsScoped = picked.startAccessingSecurityScopedResource()
            otherLibraryURL = picked
            resetTransientState()
            loadMoveList()
        }
    }

    private func stopOtherScope() {
        if otherIsScoped, let url = otherLibraryURL {
            url.stopAccessingSecurityScopedResource()
        }
        otherIsScoped = false
    }

    private func finish() {
        stopOtherScope()
        onRefresh()
        dismiss()
    }

    private func resetTransientState() {
        selectedForMove = []
        moveSummary = nil
        // The selected actors/tags/studios belong to the previous source
        // library, so clear the advanced filter when the source changes.
        filterCriteria = AssetFilterCriteria()
        moveAlphaFilter = nil
        dupMatches = []
        didScanDups = false
        dupSummary = nil
        dupApplyNote = nil
    }

    private func loadMoveList() {
        let src = sourceURL
        isLoadingMoveList = true
        selectedForMove = []
        moveAlphaFilter = nil
        Task.detached(priority: .userInitiated) {
            var rows: [MoveRow] = []
            var profileList: [EntityProfile] = []
            var akaMap: [String: String] = [:]
            do {
                // A read failure must be REPORTED, not rendered as "No Videos
                // to Move" — `try?` here made the two indistinguishable
                // (DEFECT_INVENTORY L5).
                let store = try LibraryStore(at: src)
                for asset in try store.fetchAllAssets() {
                    let fileURL = src.appendingPathComponent(asset.relativePath)
                    guard let size = VideoTransferService.fileSize(fileURL), size > 0 else { continue }
                    rows.append(MoveRow(asset: asset, sizeBytes: size))
                }
                // Profiles + AKA map (from the source library) power the
                // actor-metadata filters and alias resolution, mirroring how
                // ContentView builds them for the All Assets grid.
                profileList = try store.fetchAllEntityProfiles()
                // ⭐ Grouped and named by the columns rather than by picking the
                // id apart. After the re-key the prefix matches nothing, so
                // every alias would silently stop resolving — and this map is
                // what makes an AKA searchable at all.
                for profile in EntityProfileIndex(profileList).actors {
                    for aka in profile.akas { akaMap[aka] = profile.name }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingMoveList = false
                    self.errorMessage = "Couldn't read that library's catalog: \(error.localizedDescription)"
                }
                return
            }
            rows.sort { ($0.asset.videoName ?? $0.asset.fileName).localizedStandardCompare($1.asset.videoName ?? $1.asset.fileName) == .orderedAscending }
            let finalRows = rows
            let finalProfiles = EntityProfileIndex(profileList)
            let finalAkaMap = akaMap
            await MainActor.run {
                self.moveRows = finalRows
                self.sourceEntityProfiles = finalProfiles
                self.sourceAkaMap = finalAkaMap
                self.isLoadingMoveList = false
            }
        }
    }

    private func runMove() async {
        let src = sourceURL
        let dst = destinationURL
        let toMove = moveRows.filter { selectedForMove.contains($0.id) }.map(\.asset)
        isMoving = true
        let service = VideoTransferService()
        var moved = 0
        var actorsTransferred = 0
        var actorPhotos = 0
        var warnings: [String] = []
        var failures: [String] = []
        await ScopedOperation.run(holding: [src, dst]) {
            for (index, asset) in toMove.enumerated() {
                await MainActor.run { moveProgress = "Moving \(index + 1) of \(toMove.count)…" }
                do {
                    let outcome = try await service.moveVideo(asset, from: src, to: dst)
                    moved += 1
                    actorsTransferred += outcome.actorsTransferred
                    actorPhotos += outcome.actorPhotosTransferred
                    if let w = outcome.warning { warnings.append(w) }
                } catch {
                    failures.append("\(asset.fileName): \(error.localizedDescription)")
                }
            }
        }
        let summary = Self.moveSummaryText(
            moved: moved, total: toMove.count,
            actorsTransferred: actorsTransferred, actorPhotos: actorPhotos,
            warnings: warnings, failures: failures
        )
        await MainActor.run {
            isMoving = false
            moveProgress = ""
            moveSummary = summary
            onRefresh()
        }
    }

    private func scanDuplicates() async {
        guard let otherURL = otherLibraryURL else { return }
        isScanningDups = true
        didScanDups = true
        dupApplyNote = nil
        await MainActor.run { dupScanProgress = "Reading both libraries…" }

        let openURL = openLibraryURL
        let service = VideoTransferService()

        let result: [DupMatch] = await ScopedOperation.run(holding: [openURL, otherURL]) {
            await Task.detached(priority: .userInitiated) {
            guard let openStore = try? LibraryStore(at: openURL),
                  let otherStore = try? LibraryStore(at: otherURL),
                  let openAssets = try? openStore.fetchAllAssets(),
                  let otherAssets = try? otherStore.fetchAllAssets() else { return [] }

            // Size-group both sides (cheap) and only look closer at sizes that
            // appear on both — so durations/hashes aren't computed for the
            // whole library, only genuine collision candidates.
            func sized(_ assets: [Asset], _ base: URL) -> [(asset: Asset, url: URL, size: Int64)] {
                assets.compactMap { a in
                    let u = base.appendingPathComponent(a.relativePath)
                    guard let s = VideoTransferService.fileSize(u), s > 0 else { return nil }
                    return (a, u, s)
                }
            }
            let openSized = sized(openAssets, openURL)
            let otherSized = sized(otherAssets, otherURL)
            let openSizes = Set(openSized.map(\.size))
            let otherSizes = Set(otherSized.map(\.size))
            let collidingSizes = openSizes.intersection(otherSizes)
            guard !collidingSizes.isEmpty else { return [] }

            let openCandidates = openSized.filter { collidingSizes.contains($0.size) }
            let otherCandidates = otherSized.filter { collidingSizes.contains($0.size) }

            // Fingerprints (with durations) only for the colliding subset.
            var openFP: [VideoFingerprint] = []
            for c in openCandidates {
                let d = await VideoTransferService.videoDurationSeconds(c.url)
                openFP.append(VideoFingerprint(assetId: c.asset.id, sizeBytes: c.size, durationSeconds: d))
            }
            var otherFP: [VideoFingerprint] = []
            for c in otherCandidates {
                let d = await VideoTransferService.videoDurationSeconds(c.url)
                otherFP.append(VideoFingerprint(assetId: c.asset.id, sizeBytes: c.size, durationSeconds: d))
            }

            let pairs = VideoTransferService.duplicateCandidates(sideA: openFP, sideB: otherFP)
            let openByID = Dictionary(uniqueKeysWithValues: openCandidates.map { ($0.asset.id, $0) })
            let otherByID = Dictionary(uniqueKeysWithValues: otherCandidates.map { ($0.asset.id, $0) })

            var matches: [DupMatch] = []
            var seenOther = Set<UUID>()
            for (index, pair) in pairs.enumerated() {
                await MainActor.run { self.dupScanProgress = "Confirming match \(index + 1) of \(pairs.count)…" }
                guard let o = openByID[pair.sideAAssetId], let x = otherByID[pair.sideBAssetId] else { continue }
                // Confirm byte-for-byte before offering deletion.
                guard let oh = try? service.contentHash(of: o.url),
                      let xh = try? service.contentHash(of: x.url),
                      oh == xh else { continue }
                // Don't pair the same other-side file twice.
                if seenOther.contains(x.asset.id) { continue }
                seenOther.insert(x.asset.id)
                matches.append(DupMatch(openAsset: o.asset, otherAsset: x.asset, sizeBytes: o.size))
            }
            matches.sort { ($0.openAsset.videoName ?? $0.openAsset.fileName).localizedStandardCompare($1.openAsset.videoName ?? $1.openAsset.fileName) == .orderedAscending }
            return matches
            }.value
        }

        await MainActor.run {
            dupMatches = result
            isScanningDups = false
        }
    }

    private func applyDuplicateChoices() async {
        guard let otherURL = otherLibraryURL else { return }
        let openURL = openLibraryURL
        // Act only on decided duplicates; skipped ones are kept for later.
        let decided = dupMatches.filter { $0.keep != .skip }
        let skipped = dupMatches.filter { $0.keep == .skip }
        guard !decided.isEmpty else { return }
        isApplyingDups = true

        let (deleted, failures): (Int, [String]) = await ScopedOperation.run(holding: [openURL, otherURL]) {
            await Task.detached(priority: .userInitiated) {
                let service = VideoTransferService()
                var deleted = 0
                var failures: [String] = []
                for match in decided {
                    // Delete the copy the user did NOT choose to keep.
                    let (asset, lib): (Asset, URL) = match.keep == .open
                        ? (match.otherAsset, otherURL)
                        : (match.openAsset, openURL)
                    do {
                        try service.deleteVideoAndArtifacts(asset, in: lib, toTrash: true)
                        deleted += 1
                    } catch {
                        failures.append("\(asset.fileName): \(error.localizedDescription)")
                    }
                }
                return (deleted, failures)
            }.value
        }

        await MainActor.run {
            isApplyingDups = false
            // Keep the still-undecided (skipped) duplicates in the list so
            // they can be resolved later; only switch to the summary screen
            // once nothing is left to decide.
            dupMatches = skipped
            if skipped.isEmpty {
                var lines = ["Removed \(deleted) duplicate cop\(deleted == 1 ? "y" : "ies")."]
                if !failures.isEmpty { lines.append("\(failures.count) failed:"); lines.append(contentsOf: failures.prefix(5)) }
                dupSummary = lines.joined(separator: "\n")
            } else {
                dupApplyNote = "Removed \(deleted); \(skipped.count) still skipped."
                if !failures.isEmpty {
                    errorMessage = "\(failures.count) couldn't be removed:\n" + failures.prefix(5).joined(separator: "\n")
                }
            }
            onRefresh()
        }
    }

    // MARK: - Helpers

    /// The thumbnail file for a duplicate. The two copies are byte-identical,
    /// so either library's cached thumbnail shows the same frame; prefer the
    /// open library's, fall back to the other's.
    private func thumbnailURL(for match: DupMatch) -> URL {
        let openThumb = openLibraryURL
            .appendingPathComponent(".catalog/thumbnails/\(match.openAsset.id.uuidString).jpg")
        if FileManager.default.fileExists(atPath: openThumb.path) { return openThumb }
        return (otherLibraryURL ?? openLibraryURL)
            .appendingPathComponent(".catalog/thumbnails/\(match.otherAsset.id.uuidString).jpg")
    }

    nonisolated private static func moveSummaryText(moved: Int, total: Int, actorsTransferred: Int, actorPhotos: Int, warnings: [String], failures: [String]) -> String {
        var lines = ["Moved \(moved) of \(total) video\(total == 1 ? "" : "s")."]
        if actorsTransferred > 0 {
            lines.append("Brought \(actorsTransferred) actor profile\(actorsTransferred == 1 ? "" : "s") across" + (actorPhotos > 0 ? " with \(actorPhotos) new photo\(actorPhotos == 1 ? "" : "s")." : "."))
        }
        if !warnings.isEmpty {
            lines.append("\(warnings.count) copied but left a source copy behind — remove those by hand.")
        }
        if !failures.isEmpty {
            lines.append("\(failures.count) failed (sources left untouched):")
            lines.append(contentsOf: failures.prefix(5))
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func freeSpace(at url: URL) -> Int64? {
        // External / USB-OTG volumes on iOS frequently report nothing for the
        // "important usage" key (it's an iOS-internal, purgeable-aware figure
        // that only applies to the internal store), which made the tool think
        // the drive was full. Fall back to the plain available-capacity key,
        // then to the classic filesystem attributes, and treat a still-unknown
        // result as nil (unknown) rather than 0 so the move isn't blocked.
        if let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let plain = values.volumeAvailableCapacity, plain > 0 {
                return Int64(plain)
            }
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? Int64, free > 0 {
            return free
        }
        return nil
    }

    nonisolated private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A small poster thumbnail for a duplicate row, loaded lazily from a
/// library's cached `.catalog/thumbnails/<id>.jpg` (downsampled via the shared
/// ThumbnailLoader). Falls back to a film icon when no thumbnail exists yet.
private struct DuplicateThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 72, height: 48)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: url) {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                image = await ThumbnailLoader.image(from: url, maxPixelSize: 160)
            }
    }
}

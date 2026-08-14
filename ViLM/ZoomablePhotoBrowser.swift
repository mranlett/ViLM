// ZoomablePhotoBrowser.swift
// Full-screen photo viewing: pinch-to-zoom, and an endlessly wrapping pager.
//
// ⚠️ Extracted from `ProfileGraphHeaderView`, where both of these were private
// nested types. The match screen needed the same behaviour over a candidate's
// images, and a second implementation of pinch-to-zoom is two implementations
// to keep in step — the first one already carries two hard-won fixes (the
// pager's centring, and the deliberate gap between the edge tap zones) that a
// re-write would not have known to reproduce.
//
// `ZoomablePhoto` and `WrappingPhotoPager` are generic over their content, so
// they work equally for a profile photo loaded from disk and a candidate image
// fetched from a URL. `RemotePhotoBrowser` is the URL-backed screen built from
// them.

import SwiftUI
import AVFoundation
// `FullScreenPhotoBrowser` resolves on-disk photo names through
// `ProfileImageNaming`, which is domain logic.
import LibraryCore

/// Pinch-to-zoom for a single full-screen photo. Deliberately scoped to
/// zoom-in-place (no panning): the pager's own swipe-to-advance uses a
/// plain one-finger `DragGesture`, and a competing one-finger pan gesture
/// here would fight it for recognition. Pinch (two fingers) and
/// double-tap don't overlap with that at all, so they're safe to attach
/// with `.simultaneousGesture` without touching the pager's gesture.
struct ZoomablePhoto<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        content()
            .scaleEffect(scale)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value, minScale), maxScale)
                    }
                    .onEnded { _ in
                        lastScale = scale
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = 1
                        lastScale = 1
                    }
                }
            )
    }
}

/// A three-page carousel that wraps endlessly with genuinely seamless
/// transitions.
///
/// Rather than fighting `TabView`'s page style (which animates the large
/// index jump when snapping past a sentinel), this renders exactly three
/// pages — previous, current, next — and drives a manual drag offset.
/// After a swipe animates the neighbour to center, `index` is updated and
/// the offset reset in the animation's completion handler. Because the
/// newly-centered page shows the identical photo at the identical screen
/// position, the recenter is invisible.
struct WrappingPhotoPager<Content: View>: View {
    let count: Int
    @Binding var index: Int
    @ViewBuilder let content: (Int) -> Content

    @State private var dragOffset: CGFloat = 0
    @State private var isSettling = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            Group {
                if count <= 1 {
                    content(wrapped(index))
                        .frame(width: w, height: geo.size.height)
                } else {
                    HStack(spacing: 0) {
                        content(wrapped(index - 1)).frame(width: w, height: geo.size.height)
                        content(wrapped(index)).frame(width: w, height: geo.size.height)
                        content(wrapped(index + 1)).frame(width: w, height: geo.size.height)
                    }
                    // No -w here. The HStack is 3w wide and the enclosing
                    // .frame(width: w) CENTRES it, which already places the
                    // middle page -- wrapped(index) -- in the visible
                    // window. Subtracting another w shifted one page
                    // further, so tapping a thumbnail opened the NEXT photo.
                    //
                    // This restores the invariant settle() already documents:
                    // at dragOffset == 0 the visible page is wrapped(index).
                    .offset(x: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isSettling else { return }
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                guard !isSettling else { return }
                                let threshold = w * 0.25
                                if value.translation.width <= -threshold {
                                    settle(step: 1, width: w)
                                } else if value.translation.width >= threshold {
                                    settle(step: -1, width: w)
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                                }
                            }
                    )
                }
            }
            .frame(width: w, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            // Kindle-style edge taps, in addition to swiping.
            //
            // Each zone is a quarter of the width, which leaves the middle
            // half clear. That gap is deliberate: the photo under this
            // overlay takes a double-tap to reset zoom, and people pinch
            // and double-tap toward the centre. Full-width zones would
            // turn every stray double-tap into two page turns.
            //
            // Reuses settle(), so a tap and a swipe animate identically.
            .overlay {
                if count > 1 {
                    HStack(spacing: 0) {
                        tapZone(step: -1, width: w, label: "Previous photo")
                        Spacer(minLength: 0)
                        tapZone(step: 1, width: w, label: "Next photo")
                    }
                }
            }
        }
    }

    private func tapZone(step: Int, width w: CGFloat, label: String) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: w * 0.25)
            .onTapGesture {
                guard !isSettling else { return }
                settle(step: step, width: w)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }

    private func wrapped(_ i: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((i % count) + count) % count
    }

    private func settle(step: Int, width w: CGFloat) {
        isSettling = true
        withAnimation(.easeOut(duration: 0.25)) {
            // step +1 slides content left to reveal the next page; -1 right.
            dragOffset = -CGFloat(step) * w
        } completion: {
            // Recenter onto the now-visible page with no animation. Same
            // pixels at the same position, so nothing appears to move.
            index = wrapped(index + step)
            dragOffset = 0
            isSettling = false
        }
    }
}

/// Full-screen viewing for images that live at a URL rather than on disk.
///
/// The profile browser's counterpart, for a match candidate's images. This is
/// the screen where the operator decides whether two videos are the same work,
/// and that decision is frequently made on a detail — a logo, a room, a face in
/// the background — which is why zoom matters here rather than being a
/// flourish.
struct RemotePhotoBrowser: View {
    let urls: [URL]
    let title: String
    /// Which image was tapped. The browser opens on it rather than at the
    /// start, because the operator has already chosen what to look at.
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0

    var body: some View {
        NavigationStack {
            WrappingPhotoPager(count: urls.count, index: $index) { i in
                ZoomablePhoto {
                    AsyncImage(url: urls[i]) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } placeholder: {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // Fresh zoom state per photo — the pager's three fixed slots
                // would otherwise carry a stale scale over as `index` changes
                // which image occupies a given slot.
                .id(urls[i])
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(urls.count > 1 ? "\(index + 1) of \(urls.count)" : title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { index = min(max(initialIndex, 0), max(urls.count - 1, 0)) }
        }
        // Larger than the shared default for the same reason the profile
        // browser is: this sheet exists to look at a picture, and sizing it
        // like a settings pane would defeat opening it.
        .macSheet(minWidth: 900, minHeight: 700)
    }
}

/// Full-screen viewing for a video's own preview frames.
///
/// ⚠️ The counterpart to `RemotePhotoBrowser` on the match screen. Comparing
/// your video against a candidate means comparing two pictures, and until now
/// only one of them could be enlarged — `DetailGridView` was explicitly
/// non-interactive because "a tap would have nowhere to go". It does now.
///
/// Reuses `FrameExtractView`, so a frame already decoded for the grid is served
/// from the same cache rather than decoded a second time at size.
struct VideoFrameBrowser: View {
    let videoAsset: AVAsset
    let assetKey: String
    /// The grid's resolved timestamps, in order.
    let times: [Double]
    let aspectRatio: CGFloat
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0

    var body: some View {
        NavigationStack {
            WrappingPhotoPager(count: times.count, index: $index) { i in
                ZoomablePhoto {
                    FrameExtractView(videoAsset: videoAsset,
                                     assetKey: assetKey,
                                     timeSeconds: times.indices.contains(i) ? times[i] : nil,
                                     aspectRatio: aspectRatio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Fresh zoom state per frame — the pager's three fixed slots
                // would otherwise carry a stale scale across a page change.
                .id(i)
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(timeLabel)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { index = min(max(initialIndex, 0), max(times.count - 1, 0)) }
        }
        .macSheet(minWidth: 900, minHeight: 700)
    }

    /// The timestamp, not "3 of 16" — on a video the useful thing about a frame
    /// is where in the running time it came from.
    private var timeLabel: String {
        guard times.indices.contains(index) else { return "" }
        let total = Int(times[index].rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Full-screen photo viewer for an entity's own photos, with endless
/// wrap-around swiping and pinch-zoom.
///
/// ⚠️ Lived as a private type inside `ProfileGraphHeaderView` until Head to
/// Head needed it too (#38 follow-on: expand a contender's picture to full
/// screen). Moved here rather than copied — it belongs beside
/// `RemotePhotoBrowser` and `VideoFrameBrowser`, which answer the same question
/// for a candidate's photos and for a video's frames.
struct FullScreenPhotoBrowser: View {
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

/// A video's own stills, full screen: the poster frame plus every
/// contact-sheet cell, swipeable and pinch-zoomable.
///
/// 🚨 Slices the contact sheet rather than re-extracting frames. A contact
/// sheet is a single composite JPEG already on disk; pulling twelve frames out
/// of the video again would mean an AVFoundation pass every time someone
/// glanced at a contender, on a screen whose whole point is speed.
///
/// ⭐ `frames` is passed in when the caller already has them — Head to Head
/// slices them once for the card and hands the same array over, so expanding a
/// contender is instant and decodes nothing twice. Callers with no frames
/// (the actor game's video strip) leave it empty and it loads its own.
///
/// ⚠️ Zoom and paging come from `ZoomablePhoto` and `WrappingPhotoPager`, the
/// same two the photo browsers use. This screen previously advanced on a plain
/// tap and could not zoom at all, which was fine while it was a glance and is
/// not fine now that the operator judges videos here.
struct StillBrowser: View {
    let asset: Asset
    var frames: [CGImage] = []
    var initialIndex: Int = 0
    let onClose: () -> Void

    @State private var loaded: [CGImage] = []
    @State private var index = 0
    @State private var isLoading = true

    private var shown: [CGImage] { frames.isEmpty ? loaded : frames }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && shown.isEmpty {
                    ProgressView()
                } else if shown.isEmpty {
                    // ⚠️ Says why rather than showing an empty black screen. A
                    // video with no contact sheet yet is the common case for
                    // anything added recently.
                    ContentUnavailableView("No stills yet",
                                           systemImage: "photo.on.rectangle",
                                           description: Text("This video has no contact sheet. Generate one from the video's own page and its frames will appear here."))
                } else {
                    WrappingPhotoPager(count: shown.count, index: $index) { i in
                        ZoomablePhoto {
                            Image(decorative: shown[i], scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        // Fresh zoom state per frame — the pager's three fixed
                        // slots would otherwise carry a stale scale across a
                        // page change.
                        .id(i)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(shown.count > 1 ? "\(index + 1) of \(shown.count)" : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(ActorKnownFor.displayTitle(asset))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal).padding(.bottom, 8)
            }
        }
        .macSheet(minWidth: 900, minHeight: 600)
        .onAppear { index = min(max(initialIndex, 0), max(shown.count - 1, 0)) }
        .task {
            guard frames.isEmpty else { isLoading = false; return }
            loaded = await ContactSheetFrames.load(for: asset.id)
            isLoading = false
        }
    }
}

// AppComponents.swift
// Shared building blocks used across screens: the usesStackNavigation
// environment key, AppErrorReporter (error toast plumbing), the 4x4 clickable
// frame grid (DetailGridView/FrameExtractView), the downsampling thumbnail
// loader and grid-cell thumbnail views, TagBubble, and FlowLayout.

import SwiftUI
// @preconcurrency because AVFoundation is not Sendable-audited: AVAsset and
// friends predate strict concurrency and carry no annotations, so Swift 6 warns
// on every capture of one in a @Sendable closure.
//
// The capture in question (FrameExtractView.loadFrame) is genuinely safe:
// AVURLAsset is documented as supporting concurrent reading, and
// AVAssetImageGenerator is designed to be driven from a background queue —
// which is exactly what FrameCache's decode gate does. The asset is read-only
// once constructed and nothing mutates it.
//
// The alternative — passing the URL and building an AVURLAsset inside the
// closure — would silence the warning without an annotation, but it would build
// one asset per frame instead of reusing the cached one, re-loading track info
// sixteen times per contact sheet. That caching is part of a measured 24.6%
// load-time win, so it stays.
@preconcurrency import AVFoundation
import AVKit
import LibraryCore
import CoreGraphics
import ImageIO

// MARK: - Navigation Mode Environment
//
// True when the view hierarchy lives inside the compact single-stack layout
// (iPhone), where taps should push NavigationLinks. False in the split-view
// layout, where taps should select into the detail pane.
//
// Views must NOT infer this from horizontalSizeClass: NavigationSplitView
// columns report their own (compact) size class even when the window is
// regular width, which sends taps down the wrong path.
private struct UsesStackNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesStackNavigation: Bool {
        get { self[UsesStackNavigationKey.self] }
        set { self[UsesStackNavigationKey.self] = newValue }
    }
}

// MARK: - Error surfacing
//
// The app's write paths used to swallow failures with a print() — a save
// that didn't persist (disk full, unplugged volume, permissions) looked
// exactly like success. Any code that fails a user-initiated write calls
// AppErrorReporter.report(_:); ContentView listens and shows a transient
// toast. Deliberately fire-and-forget: reporting must never be able to make
// the failing operation worse.
enum AppErrorReporter {
    nonisolated static let notificationName = NSNotification.Name("AppErrorToast")

    // Callable from any thread/task — the body hops to main itself.
    nonisolated static func report(_ message: String) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: notificationName, object: message)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: notificationName, object: message)
            }
        }
    }
}

// MARK: - Detail High-Res Grid (4x4 clickable frames)
struct DetailGridView: View {
    let asset: Asset
    let libraryURL: URL?
    var isInteractive: Bool = true
    var onSelectTime: ((Double) -> Void)? = nil

    // Empty until computeTimes resolves the real timestamps. It used to start as
    // sixteen ZEROS, so all 16 cells decoded frame 0 — identical, discarded —
    // and then decoded again when the real times arrived: 32 decodes per load,
    // half of them waste, plus the black flash as every cell reset (#4 / F1).
    @State private var times: [Double] = []
    @State private var computedAspectRatio: CGFloat = 16.0 / 9.0
    // One AVURLAsset per video, held across renders. `body` used to build a
    // fresh instance on every render and hand it to all 16 cells; the cell
    // count made that per-render cost real. Set from the .task below (state
    // can't be mutated during a view update).
    @State private var cachedVideoAsset: AVURLAsset?

    private func videoAsset(for url: URL) -> AVURLAsset {
        if let cachedVideoAsset, cachedVideoAsset.url == url {
            return cachedVideoAsset
        }
        return AVURLAsset(url: url)
    }

    var body: some View {
        Group {
            if let url = LibrarySession.shared.videoURL(for: asset) {
                let videoAsset = videoAsset(for: url)

                VStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { col in
                                let index = row * 4 + col
                                let start: Double? = times.indices.contains(index) ? times[index] : nil

                                FrameExtractView(
                                    videoAsset: videoAsset,
                                    assetKey: url.path,
                                    timeSeconds: start,
                                    aspectRatio: computedAspectRatio
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard isInteractive, let start else { return }
                                    onSelectTime?(start)
                                }
                            }
                        }
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .task(id: asset.id) {
                    let avAsset = self.videoAsset(for: url)
                    cachedVideoAsset = avAsset
                    await computeTimes(for: avAsset)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func computeTimes(for avAsset: AVURLAsset) async {
        // Geometry and timing live in LibraryCore (FrameGrid) as pure functions so
        // they can be unit-tested without a video fixture. This view only supplies
        // the values loaded from AVFoundation.
        if let track = try? await avAsset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform),
           let ratio = FrameGrid.aspectRatio(naturalSize: size, transform: transform) {
            await MainActor.run {
                self.computedAspectRatio = ratio
            }
        }

        guard let dur = try? await avAsset.load(.duration) else { return }

        let newTimes = FrameGrid.frameTimes(duration: dur.seconds)
        guard !newTimes.isEmpty else { return }

        times = newTimes
    }
}

// MARK: - Individual Frame Extractor (image at an explicit timestamp)
struct FrameExtractView: View {
    let videoAsset: AVAsset
    /// Identifies the video for cache purposes (its file path).
    let assetKey: String
    /// `nil` until the grid has resolved real timestamps — decoding before then
    /// produced 16 throwaway frames per load. See DetailGridView.times.
    let timeSeconds: Double?
    var aspectRatio: CGFloat = 16.0 / 9.0

    @State private var frame: CGImage?

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                Color.black
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        // Runs once the timestamp resolves. Deliberately does NOT clear `frame`
        // first: blanking on every id change is what made the grid flash black.
        .task(id: timeSeconds) {
            await loadFrame()
        }
    }

    private func loadFrame() async {
        guard let timeSeconds else { return }
        let key = FrameCache.key(assetKey: assetKey, timeSeconds: timeSeconds)
        let asset = videoAsset

        // A cache hit skips both the decode and the concurrency gate, so
        // re-opening a video costs nothing.
        let image = await FrameCache.shared.image(for: key) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 600)
            let time = CMTime(seconds: max(0, timeSeconds), preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
            return cgImage
        }

        // Navigating away mid-load cancels the task; don't publish a stale frame.
        guard !Task.isCancelled, let image else { return }
        frame = image
    }
}

// MARK: - Thumbnail Loader
//
// Loads grid thumbnails off the main thread, downsampled at decode time to
// roughly their display size, and memory-cached. Grid cells re-render often
// (search keystrokes, selection changes); decoding full-size JPEGs on the
// main thread per render does not scale to large libraries.
enum ThumbnailLoader {
    // NSCache is internally thread-safe; opt out of Swift 6 global-state isolation.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        // Bound by decoded pixel bytes (cost passed at setObject) so a large
        // grid can't accumulate unlimited bitmaps before the system's memory
        // pressure — which on iOS often arrives as a jetsam kill — steps in.
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// Cache key includes the file's modification date so regenerated
    /// thumbnails (e.g. "Set as Main Thumbnail") are picked up.
    static func image(from url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = "\(url.path)|\(modified)|\(maxPixelSize)" as NSString

            if let cached = cache.object(forKey: key) { return cached }

            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }.value
    }
}

// MARK: - Async Thumbnail Image (shared cell body)
// Fills the available width and takes its height from the image's own aspect
// ratio, so it scales cleanly as the column width changes (more/fewer columns,
// resized panes) with no fixed-height letterbox bars.
private struct AsyncThumbnailImage: View {
    let imageURL: URL
    let maxPixelSize: Int
    // Bump to re-check for a file that didn't exist yet (during generation)
    var refreshToken: UUID? = nil

    @State private var cgImage: CGImage?
    @State private var aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        Group {
            if let cgImage {
                Image(decorative: cgImage, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(ProgressView())
            }
        }
        .task(id: "\(imageURL.path)|\(refreshToken?.uuidString ?? "")") {
            if let image = await ThumbnailLoader.image(from: imageURL, maxPixelSize: maxPixelSize) {
                cgImage = image
                aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            }
        }
    }
}

// MARK: - Single Frame Thumbnail View (local file thumbnail)
// Renders only the poster image. Callers supply their own title/overlays; an
// internal title here would duplicate that and, when long, widen the card and
// push corner overlays off the image.
struct VideoThumbnailView: View {
    let asset: Asset
    let libraryURL: URL?
    var refreshToken: UUID? = nil

    var body: some View {
        Group {
            // Resolved per asset: in a federated session the thumbnail lives
            // in whichever library owns the video.
            if let imageURL = LibrarySession.shared.thumbnailURL(for: asset.id) {
                AsyncThumbnailImage(
                    imageURL: imageURL,
                    maxPixelSize: 700,
                    refreshToken: refreshToken
                )
            }
        }
    }
}

// MARK: - Grid Thumbnail View (local file contact sheet)
struct ContactSheetThumbnailView: View {
    let asset: Asset
    let libraryURL: URL?
    var refreshToken: UUID? = nil

    var body: some View {
        if let imageURL = LibrarySession.shared.contactSheetURL(for: asset.id) {
            AsyncThumbnailImage(
                imageURL: imageURL,
                maxPixelSize: 1100,
                refreshToken: refreshToken
            )
        }
    }
}

// MARK: - Tag Bubble
struct TagBubble: View {
    let label: String
    let color: Color
    var onPivot: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var navRoute: AppRoute? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let route = navRoute {
                NavigationLink(value: route) {
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    if let pivot = onPivot {
                        pivot()
                    } else if let edit = onEdit {
                        edit() // Fallback if no pivot provided
                    }
                }) {
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { isHovered in
                    if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                #endif
            }
            
            if onPivot != nil && onEdit != nil {
                Button(action: { onEdit?() }) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .opacity(0.6)
                }
                .buttonStyle(.plain)
            }
            
            if let deleteAction = onDelete {
                Button(action: deleteAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .opacity(0.6)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .foregroundColor(color)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Flow Layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Use replacingUnspecifiedDimensions to handle infinity or nil safely
        let width = proposal.replacingUnspecifiedDimensions().width
        let result = FlowResult(in: width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(
                at: CGPoint(x: point.x + bounds.minX, y: point.y + bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var points: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: LayoutSubviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            var totalWidth: CGFloat = 0

            for subview in subviews {
                let proposed = maxWidth > 0 ? ProposedViewSize(width: maxWidth, height: nil) : .unspecified
                let size = subview.sizeThatFits(proposed)
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                points.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
                totalWidth = max(totalWidth, currentX)
            }

            // Prevent ScrollView bounce loops by returning maxWidth if available
            let finalWidth = maxWidth > 0 ? maxWidth : totalWidth
            self.size = CGSize(width: finalWidth, height: currentY + lineHeight)
        }
    }
}


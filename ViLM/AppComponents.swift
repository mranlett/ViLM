import SwiftUI
import AVFoundation
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

    @State private var times: [Double] = Array(repeating: 0, count: 16)
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
            if let url = libraryURL?.appendingPathComponent(asset.relativePath) {
                let videoAsset = videoAsset(for: url)

                VStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { col in
                                let index = row * 4 + col
                                let start = times.indices.contains(index) ? times[index] : 0

                                FrameExtractView(
                                    videoAsset: videoAsset,
                                    timeSeconds: start,
                                    aspectRatio: computedAspectRatio
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard isInteractive else { return }
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
        if let track = try? await avAsset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformedSize = size.applying(transform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            if height > 0 {
                await MainActor.run {
                    self.computedAspectRatio = width / height
                }
            }
        }
        
        guard let dur = try? await avAsset.load(.duration) else { return }

        let total = dur.seconds
        guard total.isFinite, total > 0 else { return }

        let count = 16
        let newTimes = (0..<count).map { i -> Double in
            let t = (Double(i) + 1) / Double(count + 1) * total
            return min(max(0, t), max(0, total - 0.25))
        }

        times = newTimes
    }
}

// MARK: - Individual Frame Extractor (image at an explicit timestamp)
struct FrameExtractView: View {
    let videoAsset: AVAsset
    let timeSeconds: Double
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
        // Critical: rerun when the timestamp changes (times[] initially 0 then updates)
        .task(id: timeSeconds) {
            frame = nil
            await generateFrame()
        }
    }

    private func generateFrame() async {
        let generator = AVAssetImageGenerator(asset: videoAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 600)

        let time = CMTime(seconds: max(0, timeSeconds), preferredTimescale: 600)
        if let (cgImage, _) = try? await generator.image(at: time) {
            frame = cgImage
        }
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
            if let libraryURL {
                // POINT TO THE SINGLE THUMBNAIL FOLDER
                AsyncThumbnailImage(
                    imageURL: libraryURL.appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg"),
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
        if let libraryURL {
            // IMPORTANT: aligns with ContactSheetService output folder
            AsyncThumbnailImage(
                imageURL: libraryURL.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg"),
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


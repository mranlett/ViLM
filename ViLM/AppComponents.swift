import SwiftUI
import AVFoundation
import AVKit
import LibraryCore
import CoreGraphics
import ImageIO

// MARK: - Detail High-Res Grid (4x4 clickable frames)
struct DetailGridView: View {
    let asset: Asset
    let libraryURL: URL?
    var isInteractive: Bool = true
    var onSelectTime: ((Double) -> Void)? = nil

    @State private var times: [Double] = Array(repeating: 0, count: 16)

    var body: some View {
        Group {
            if let url = libraryURL?.appendingPathComponent(asset.relativePath) {
                let videoAsset = AVURLAsset(url: url)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                    ForEach(0..<16, id: \.self) { index in
                        let start = times.indices.contains(index) ? times[index] : 0

                        FrameExtractView(
                            videoAsset: videoAsset,
                            timeSeconds: start
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard isInteractive else { return }
                            onSelectTime?(start)
                        }
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .task(id: asset.id) {
                    await computeTimes(for: url)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func computeTimes(for url: URL) async {
        let avAsset = AVURLAsset(url: url)
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

    @State private var frame: CGImage?

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black
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

// MARK: - Single Frame Thumbnail View (local file thumbnail)
struct VideoThumbnailView: View {
    let asset: Asset
    let libraryURL: URL?

    var body: some View {
        VStack(alignment: .leading) {
            if let libraryURL {
                // POINT TO THE SINGLE THUMBNAIL FOLDER
                let imageURL = libraryURL
                    .appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg")

                if let cgImage = loadCGImage(from: imageURL) {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 180)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 180)
                        .overlay(ProgressView())
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Text(asset.fileName)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

// MARK: - Grid Thumbnail View (local file contact sheet)
struct ContactSheetThumbnailView: View {
    let asset: Asset
    let libraryURL: URL?

    var body: some View {
        if let libraryURL {
            // IMPORTANT: aligns with ContactSheetService output folder
            let imageURL = libraryURL
                .appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg")

            if let cgImage = loadCGImage(from: imageURL) {
                Image(decorative: cgImage, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 180)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 180)
                    .overlay(ProgressView())
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - Tag Bubble
struct TagBubble: View {
    let label: String
    let color: Color
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .opacity(0.6)
            }
            .buttonStyle(.plain)
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
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(
                at: CGPoint(x: point.x + bounds.minX, y: point.y + bounds.minY),
                proposal: .unspecified
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
                let size = subview.sizeThatFits(.unspecified)
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

            self.size = CGSize(width: totalWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: - Cross-platform image loader (ImageIO)
private func loadCGImage(from url: URL) -> CGImage? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

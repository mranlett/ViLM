// DashboardComponents.swift
// Card and row views used by DashboardView: hero stat cards, the
// recently-added / unreviewed video carousels' cards, actor circle cards, the
// "Actors Needing Attention" row, and ProfileAvatarLoader (the shared
// downsampled-avatar cache backing the actor cards).

import SwiftUI
import LibraryCore
import ImageIO

struct StatCardView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.title3)
                .bold()
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(PlatformSystemBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title)")
    }
}

struct VideoThumbnailCard: View {
    let asset: Asset
    let libraryURL: URL?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                .frame(width: 160, height: 90)
                .cornerRadius(12)
            
            Text(asset.fileName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
    }
}

struct UnreviewedVideoCard: View {
    let asset: Asset
    let libraryURL: URL?
    var openRoute: AppRoute? = nil
    var onOpen: (() -> Void)? = nil
    let onMarkReviewed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The thumbnail navigates; "Mark Reviewed" stays outside the
            // link so both tap targets keep working.
            if let route = openRoute {
                NavigationLink(value: route) {
                    thumbnailAndTitle
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { onOpen?() })
            } else {
                thumbnailAndTitle
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
            }

            HStack {
                Spacer()
                Button(action: onMarkReviewed) {
                    Text("Mark Reviewed")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .frame(width: 160)
        }
    }

    private var thumbnailAndTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                    .frame(width: 160, height: 90)
                    .cornerRadius(12)

                Text("NEW")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .cornerRadius(8)
                    .padding([.top, .leading], 6)
            }

            Text(asset.fileName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
    }
}

struct ActorCircleCard: View {
    let actorName: String
    let profile: EntityProfile?
    let profileImageFileNames: Set<String>
    let libraryURL: URL?

    @State private var loadedImage: PlatformImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = loadedImage {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        Text(actorName.prefix(1).uppercased())
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            Text(actorName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: 78)

            if let date = profile?.createdAt {
                Text(timeAgo(since: date))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .task(id: actorName) {
            loadedImage = await ProfileAvatarLoader.image(
                actorName: actorName,
                fileNames: profileImageFileNames,
                libraryURL: libraryURL,
                maxPixelSize: 150
            )
        }
    }

    private func timeAgo(since date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Profile Avatar Loader
//
// Resolves and decodes an actor's local profile image off the main thread,
// downsampled to display size and cached. Used by the dashboard's actor
// carousels/rows where sync decoding in `body` stalled scrolling.
enum ProfileAvatarLoader {
    // NSCache is internally thread-safe; opt out of Swift 6 global-state isolation.
    nonisolated(unsafe) private static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        // Avatars are decoded at ≤100px, so pixel cost is tiny — a count
        // limit keeps the cache bounded without cost bookkeeping.
        c.countLimit = 500
        return c
    }()

    static func image(actorName: String, fileNames: Set<String>, libraryURL: URL?, maxPixelSize: Int) async -> PlatformImage? {
        guard let url = libraryURL else { return nil }
        let entityId = "actor:\(actorName)"
        let exactMatch = ProfileImageNaming.primaryFileName(for: entityId)
        let prefixMatch = ProfileImageNaming.galleryFilePrefix(for: entityId)

        let targetFile: String?
        if fileNames.contains(exactMatch) {
            targetFile = exactMatch
        } else if let match = fileNames.first(where: { $0.hasPrefix(prefixMatch) }) {
            targetFile = match
        } else {
            targetFile = nil
        }
        guard let target = targetFile else { return nil }

        let fileURL = url.appendingPathComponent(".catalog/profiles").appendingPathComponent(target)
        return await Task.detached(priority: .userInitiated) {
            let key = "\(fileURL.path)|\(maxPixelSize)" as NSString
            if let cached = cache.object(forKey: key) { return cached }

            guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
#if os(iOS)
            let image = UIImage(cgImage: cg)
#else
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
#endif
            cache.setObject(image, forKey: key)
            return image
        }.value
    }
}

struct ActorAttentionRow: View {
    let actorName: String
    let profile: EntityProfile?
    let profileImageFileNames: Set<String>
    let libraryURL: URL?

    @State private var loadedImage: PlatformImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = loadedImage {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        Text(actorName.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 2) {
                Text(actorName)
                    .font(.system(size: 14, weight: .semibold))
                Text(missingLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(actionLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(14)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(PlatformSystemBackground))
        .task(id: actorName) {
            loadedImage = await ProfileAvatarLoader.image(
                actorName: actorName,
                fileNames: profileImageFileNames,
                libraryURL: libraryURL,
                maxPixelSize: 100
            )
        }
    }

    private var missingLabel: String {
        return "No profile photo"
    }

    private var actionLabel: String {
        return "Add Photo"
    }
}

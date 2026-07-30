// SceneMarkerViews.swift
// The Scene Markers strip in Video Details: SceneMarkerCard (thumbnail +
// timestamp badge + label + rename/delete menu) and MarkerLabelEntryView (the
// popover for naming a marker when it's created or renamed). The marker data
// model and CRUD live in LibraryCore (SceneMarker.swift / LibraryStore).

import SwiftUI
import LibraryCore

struct SceneMarkerCard: View {
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
            // A marker's preview lives in the library that owns its asset.
            guard let url = LibrarySession.shared.markerThumbnailURL(
                markerId: marker.id, ownerAssetID: marker.assetId) else { return }
            cgImage = await ThumbnailLoader.image(from: url, maxPixelSize: 400)
        }
    }
}

// MARK: - Marker Label Entry Popover

struct MarkerLabelEntryView: View {
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

// EntityLinksView.swift
// Renders an entity's reference links as tappable chips.
//
// These links are stored and displayed, never fetched. Nothing here opens a
// connection — the chip hands the URL to the system browser when the user asks
// for it, which is what keeps this compatible with the app's rule against
// background network access.
//
// Deliberately generic: a link is a URL plus whatever the user or an importer
// called it. There is no per-site special-casing, so any source can contribute
// links without this file needing to know the site exists.

import SwiftUI
import LibraryCore

struct EntityLinksView: View {
    let links: [EntityLink]
    var title: String? = "Links"
    var color: Color = .teal
    /// Supplied by the editor; absent on read-only surfaces.
    var onDelete: ((EntityLink) -> Void)? = nil

    /// Valid, de-duplicated, in stored order.
    ///
    /// Dedupe is by URL rather than by label because the same address can
    /// arrive twice under different names — once typed by hand into the home
    /// page field and once imported with a site name attached.
    private var usable: [EntityLink] {
        var seen = Set<String>()
        return links.filter {
            $0.isValid && seen.insert($0.url.lowercased()).inserted
        }
    }

    var body: some View {
        if !usable.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fontWeight(.medium)
                }
                FlowLayout(spacing: 6) {
                    ForEach(usable) { link in
                        chip(for: link)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chip(for link: EntityLink) -> some View {
        HStack(spacing: 6) {
            if let url = URL(string: link.url) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                        Text(link.displayLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                #endif
            }

            if let onDelete {
                Button {
                    onDelete(link)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .opacity(0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(link.displayLabel) link")
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
        // The full address is worth seeing before following it, and the chip
        // shows only a short label.
        .help(link.url)
        .accessibilityLabel("\(link.displayLabel) link")
        .accessibilityHint(link.url)
    }
}

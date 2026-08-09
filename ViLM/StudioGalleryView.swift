// StudioGalleryView.swift
// The Studios Gallery: every studio as a card with its video count; selecting
// one opens its filtered asset grid.
//
// Mirrors the Series Gallery — a studio clusters like videos the same way a
// series does — with one addition the series gallery has no use for: whether
// the studio has been CONFIRMED against an external source.
//
// That matters because a confirmed studio is the one thing allowed to drive a
// folder name, so "which studios are still unconfirmed" is a real question with
// real consequences, and this is the only place it can be seen at a glance.

import SwiftUI
import LibraryCore

struct StudioGalleryView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    let entityProfiles: EntityProfileIndex
    var onPullToRefresh: () async -> Void = {}

    @Environment(\.usesStackNavigation) private var usesStackNavigation

    @State private var alphaFilter: Character? = nil
    @State private var isShowingHelp = false

    // Cached once per change rather than re-derived every render.
    @State private var allStudios: [String] = []
    @State private var studioCounts: [String: Int] = [:]

    private func recompute() {
        var counts = [String: Int]()
        for asset in assets {
            // Counted per ASSET: a video credited to one studio counts once,
            // however its tag list is spelled.
            for studio in Set(asset.studios) where !studio.isEmpty {
                counts[studio, default: 0] += 1
            }
        }
        allStudios = counts.keys.sorted()
        studioCounts = counts
    }

    private var filteredStudios: [String] {
        guard let letter = alphaFilter else { return allStudios }
        return allStudios.filter { $0.uppercased().hasPrefix(String(letter)) }
    }

    private var unconfirmedCount: Int {
        allStudios.filter { entityProfiles[studio: $0]?.enrichmentState != .matched }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AlphaPickerView(filter: $alphaFilter)
                    .padding(.horizontal)
                    .padding(.bottom)

                if allStudios.isEmpty {
                    ContentUnavailableView(
                        "No Studios",
                        systemImage: "building.2",
                        description: Text("Add a Studio to videos (in the video's metadata) to group them here.")
                    )
                    .padding(.top, 60)
                } else {
                    if unconfirmedCount > 0 {
                        Text("\(unconfirmedCount) of \(allStudios.count) not yet confirmed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                        ForEach(filteredStudios, id: \.self) { studio in
                            studioItem(for: studio)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .refreshable { await onPullToRefresh() }
        #endif
        .navigationTitle("Studios Gallery")
        // The unconfirmed count sits above the grid rather than in the toolbar.
        //
        // It was briefly a `ToolbarItem(placement: .status)` — the only use of
        // that placement in the app — and was suspected of causing a toolbar
        // crash. It was NOT the cause: that was a duplicate `.searchable`
        // toolbar item, fixed in ContentView. The count stayed here anyway,
        // because a number is more visible above the grid than tucked into a
        // toolbar, and because a conditional item in a placement nothing else
        // uses is not worth the risk it never quite justified.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { isShowingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.studioGallery.id)
        }
        .onAppear { recompute() }
        .onChange(of: assets) { _, _ in recompute() }
    }

    // Mirrors the series gallery: on the compact single-stack layout push the
    // studio's page; in the split layout select it so the content pane shows
    // its filtered grid.
    @ViewBuilder
    private func studioItem(for studio: String) -> some View {
        let card = StudioGalleryItemView(
            name: studio,
            count: studioCounts[studio] ?? 0,
            isConfirmed: entityProfiles[studio: studio]?.enrichmentState == .matched)

        if usesStackNavigation {
            NavigationLink(value: AppRoute.entityProfile(category: "studio", name: studio)) {
                card
            }
            .buttonStyle(.plain)
        } else {
            Button(action: { sidebarSelection = [.studio(studio)] }) {
                card
            }
            .buttonStyle(.plain)
        }
    }
}

struct StudioGalleryItemView: View {
    let name: String
    let count: Int
    let isConfirmed: Bool

    // Text-first, for the same reason the tag card is: a studio name is the
    // content, and an icon competing for width buys nothing a label does not
    // already say. Measured, studio names run well past what a leading icon
    // and a chevron leave room for.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text("\(count) video\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Only the unconfirmed state is called out. Marking every
                // confirmed studio would put a badge on almost everything and
                // make the exceptions harder to see, not easier.
                if !isConfirmed {
                    Text("unconfirmed")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count) video\(count == 1 ? "" : "s")\(isConfirmed ? "" : ", not yet confirmed")")
        #if os(macOS)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}

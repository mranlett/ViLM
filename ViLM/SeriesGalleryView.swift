// SeriesGalleryView.swift
// The Series Gallery: every series (video name) as a card with its video
// count; selecting one opens its filtered asset grid.

import SwiftUI
import LibraryCore

struct SeriesGalleryView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    var onPullToRefresh: () async -> Void = {}

    @Environment(\.usesStackNavigation) private var usesStackNavigation

    @State private var alphaFilter: Character? = nil
    @State private var isShowingCleanup = false
    @State private var isShowingRemoval = false
    @State private var isShowingHelp = false

    // Cached once per assets change rather than re-derived every render.
    @State private var allSeries: [String] = []
    @State private var seriesCounts: [String: Int] = [:]

    private func recompute() {
        var counts = [String: Int]()
        for asset in assets {
            if let name = asset.videoName, !name.isEmpty {
                counts[name, default: 0] += 1
            }
        }
        allSeries = counts.keys.sorted()
        seriesCounts = counts
    }

    var filteredSeries: [String] {
        guard let letter = alphaFilter else { return allSeries }
        return allSeries.filter { $0.uppercased().hasPrefix(String(letter)) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AlphaPickerView(filter: $alphaFilter)
                    .padding(.horizontal)
                    .padding(.bottom)

                if allSeries.isEmpty {
                    ContentUnavailableView(
                        "No Series",
                        systemImage: "rectangle.stack",
                        description: Text("Assign a Series to videos (in the video's metadata) to group them here.")
                    )
                    .padding(.top, 60)
                } else {
                    // Series names are freeform titles that are often long, so
                    // give each card a wide, full-width-friendly column and let
                    // the title wrap rather than truncate to nothing.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(filteredSeries, id: \.self) { series in
                            seriesItem(for: series)
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
        .navigationTitle("Series Gallery")
        .toolbar {
            if !allSeries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    // A menu rather than two buttons: these are the two things
                    // you can do to a series name, and they are opposites —
                    // one keeps a name and tidies it, the other takes it off.
                    Menu {
                        Button {
                            isShowingCleanup = true
                        } label: {
                            Label("Standardize Names", systemImage: "wand.and.stars")
                        }
                        Button(role: .destructive) {
                            isShowingRemoval = true
                        } label: {
                            Label("Remove Names…", systemImage: "eraser")
                        }
                    } label: {
                        Label("Clean Up", systemImage: "wand.and.stars")
                    }
                    // Single-library tools: both write primary rows only, which
                    // would half-change a series spanning attached libraries.
                    .disabled(LibrarySession.shared.isFederated)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { isShowingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $isShowingCleanup) {
            if let url = libraryURL {
                SeriesCleanupView(libraryURL: url, assets: assets)
            }
        }
        .sheet(isPresented: $isShowingRemoval) {
            if let url = libraryURL {
                SeriesRemovalView(libraryURL: url, assets: assets) { recompute() }
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.seriesGallery.id)
        }
        .onAppear { recompute() }
        .onChange(of: assets) { _, _ in recompute() }
    }

    // Mirrors the actor gallery: on the compact single-stack layout push the
    // series' page via a NavigationLink; in the split layout select it so the
    // content pane shows its filtered grid.
    @ViewBuilder
    private func seriesItem(for series: String) -> some View {
        let card = SeriesGalleryItemView(name: series, count: seriesCounts[series] ?? 0)
        if usesStackNavigation {
            NavigationLink(value: AppRoute.entityProfile(category: "series", name: series)) {
                card
            }
            .buttonStyle(.plain)
        } else {
            Button(action: { sidebarSelection = [.series(series)] }) {
                card
            }
            .buttonStyle(.plain)
        }
    }
}

struct SeriesGalleryItemView: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundColor(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(count) Video\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .imageScale(.small)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
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

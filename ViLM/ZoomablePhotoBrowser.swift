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

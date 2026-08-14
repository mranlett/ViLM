// ContenderVideoSurface.swift
// Head to Head — a video contender you can actually watch (#38 follow-on).
//
// TRACKED and PUBLIC. Names no source.
//
// 🚨 THIS REVERSES HALF OF D1, at the operator's direction, and the half it
// reverses is worth stating precisely. D1 said *"a video never autoplays
// here"*, and that stands: nothing on this screen starts playing by itself.
// What changed is that DELIBERATE playback is now possible — the operator
// asked to scrub through the action rather than judge from twelve stills, and
// a still cannot show motion.
//
// ⭐ Stills remain the default and the resting state. They are already decoded,
// they cost nothing, and flicking through them is faster than any player can
// start. A player is created only when the play button is pressed, for the one
// side pressed, and is thrown away the moment the pair advances.
//
// 🚨 SILENT, ALWAYS. Chosen by the operator over an unmute control: two
// contenders can play at once, and two soundtracks at once is not a comparison
// of anything. `isMuted` is set on the player this file owns and nowhere else —
// see the warning on `makePlayer()`, because the app's OTHER player persists
// its mute setting and must not be touched from here.

import SwiftUI
import AVKit
import LibraryCore

struct ContenderVideoSurface: View {
    let asset: Asset
    /// Which still is showing, owned by the session model so that browsing
    /// survives everything except the pair changing.
    let stillIndex: Int
    /// Tapping the picture advances the stills, exactly as before.
    let onBrowse: () -> Void

    /// ⭐ Stills or video, per side. Not a global mode: comparing a video
    /// against a still is a perfectly reasonable thing to want, and forcing
    /// both sides into the same mode would take that away.
    ///
    /// 🚨 The player, the stills and any failure live in `ContenderPlayback`
    /// rather than in `@State` here, and that is the fix for the defect that
    /// shipped on 2026-08-14 — not a tidy-up. State held in a REUSED view
    /// outlives the input that produced it, and the rule that says otherwise
    /// has to live somewhere a test can reach it.
    @StateObject private var playback = ContenderPlayback()

    /// Purely presentational, so it stays here: nothing about being expanded
    /// survives a contender change, and `reset()` closes it.
    @State private var isExpanded = false

    private var isPlaying: Bool { playback.player != nil }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            controls
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // 🚨 A new contender arrives by REPLACING `asset` on this same view, not
        // by destroying it. Both sides keep their position in the board's
        // HStack, so SwiftUI reuses this node and every `@State` in it — the
        // player included.
        //
        // ⚠️ `.id(asset.id)` sat here in the belief that it prevented exactly
        // that, and it does not. Applied inside a view's OWN body it
        // re-identifies the content; a view's own state belongs to its position
        // in the PARENT's body, which never changes here. The result was a card
        // that took the incoming contender's name and stills while the outgoing
        // contender's video carried on playing underneath it.
        //
        // So the reset is explicit, it lives in the component rather than in a
        // rule every caller has to remember — remembering is what failed — and
        // it lives in a TESTED object rather than in this body.
        //
        // ⚠️ `retarget` is idempotent for the same contender. This runs on the
        // view's update path, which fires for reasons that have nothing to do
        // with the pair changing; an unconditional reset here would tear the
        // player down on every redraw.
        .onChange(of: asset.id) { _, _ in reset() }
        .task(id: asset.id) {
            playback.retarget(to: asset.id)
            // ⚠️ Handed back WITH the id it was loaded for. The pair can
            // advance mid-slice, and stills that arrive late must not land on
            // whoever is on screen by then.
            playback.adopt(frames: await ContactSheetFrames.load(for: asset.id),
                           for: asset.id)
        }
        // ⚠️ Decoding does not stop when a view scrolls out of existence on its
        // own schedule. The pair advances every few seconds in this game, and a
        // player left running is a video decoding behind a screen nobody is
        // looking at — the battery cost the iOS epic exists to avoid.
        .onDisappear(perform: stop)
        .fullScreenCoverOnPhone(isPresented: $isExpanded) { expanded }
    }

    // MARK: - The picture

    @ViewBuilder
    private var content: some View {
        if let player = playback.player, !isExpanded {
            // Native transport controls: scrubbing, frame stepping and (on
            // iOS) the system full-screen button come with them. Rebuilding a
            // scrubber by hand would be a worse scrubber.
            PlayerView(player: player)
        } else if isPlaying {
            // 🚨 ONE player surface per player, ever. The expanded sheet shows
            // the same `AVPlayer`, and AVKit does not tolerate two player views
            // bound to one player — the inline one is left holding a frozen
            // frame, or steals playback back when the sheet closes. So while
            // expanded, this card deliberately renders no player at all.
            Color.black
                .overlay(Image(systemName: "rectangle.on.rectangle")
                    .font(.title3).foregroundStyle(.secondary))
        } else if let failure = playback.failure {
            // ⚠️ Says which video is unavailable rather than showing black.
            // A library on a drive that is not attached is the common case,
            // and it is not an error worth interrupting a session for.
            VStack(spacing: 6) {
                Image(systemName: "film.slash").font(.title2)
                Text(failure).font(.caption2).multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .foregroundStyle(.secondary)
        } else if let still = currentStill {
            Image(decorative: still, scale: 1)
                .resizable()
                .scaledToFill()
                .contentShape(Rectangle())
                .onTapGesture(perform: onBrowse)
        } else {
            VideoThumbnailView(asset: asset,
                               libraryURL: LibrarySession.shared.url(for: asset.id))
                .contentShape(Rectangle())
                .onTapGesture(perform: onBrowse)
        }
    }

    private var currentStill: CGImage? {
        playback.frames.isEmpty ? nil : playback.frames[stillIndex % playback.frames.count]
    }

    // MARK: - The controls

    /// ⚠️ Small, translucent and in one corner. This sits on top of the thing
    /// being judged, and a control strip that covers the picture defeats the
    /// screen it is on.
    private var controls: some View {
        HStack(spacing: 6) {
            if !isPlaying, playback.frames.count > 1 {
                Label("\(stillIndex % playback.frames.count + 1)/\(playback.frames.count)",
                      systemImage: "photo.on.rectangle")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Button {
                isPlaying ? stop() : play()
            } label: {
                Image(systemName: isPlaying ? "photo.on.rectangle.angled" : "play.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Back to stills" : "Play")

            Button {
                isExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Full screen")
        }
        .padding(8)
    }

    // MARK: - Full screen

    /// ⭐ Whichever mode the card is in expands to match: a player expands to a
    /// player, stills expand to the still browser. Expanding a playing video
    /// into a gallery of frames would lose your place in it.
    ///
    /// 🚨 The SAME `AVPlayer` instance, so the position and play state carry
    /// across in both directions. A second player seeded to the same time would
    /// decode the file twice and drift.
    @ViewBuilder
    private var expanded: some View {
        if let player = playback.player {
            FullScreenPlayer(player: player,
                             title: ActorKnownFor.displayTitle(asset)) { isExpanded = false }
        } else {
            StillBrowser(asset: asset, frames: playback.frames,
                         initialIndex: playback.frames.isEmpty ? 0 : stillIndex % playback.frames.count) {
                isExpanded = false
            }
        }
    }

    // MARK: - Lifecycle
    //
    // ⭐ All of it delegates to `ContenderPlayback`. What used to be four
    // pieces of `@State` and three private functions in this body is now one
    // object with tests against it — see `ContenderPlaybackTests`.

    private func play() {
        playback.play(url: LibrarySession.shared.videoURL(for: asset))
    }

    private func stop() { playback.stop() }

    /// Everything this card remembers about the contender that just left.
    private func reset() {
        playback.retarget(to: asset.id)
        isExpanded = false
    }
}

/// The expanded player. Chrome only — the player is owned by the card.
private struct FullScreenPlayer: View {
    let player: AVPlayer
    let title: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            PlayerView(player: player)
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                    }
                }
        }
        .macSheet(minWidth: 900, minHeight: 600)
    }
}

extension View {
    /// Full screen on a phone, an ordinary sheet everywhere else.
    ///
    /// ⚠️ `fullScreenCover` does not exist on macOS, and on iPad a sheet is the
    /// better shape anyway. The operator asked for full screen **on iOS**, so
    /// that is exactly where it is used rather than everywhere.
    @ViewBuilder
    func fullScreenCoverOnPhone<C: View>(isPresented: Binding<Bool>,
                                         @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

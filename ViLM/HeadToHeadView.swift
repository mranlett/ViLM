// HeadToHeadView.swift
// Head to Head — two contenders, and one question (#34).
//
// TRACKED and PUBLIC. Names no source.
//
// ⭐ The design constraints here are from the spec and are not decoration:
//
//   • The next pair is PREFETCHED. A wait between taps ends a session faster
//     than anything else, so the model chooses the following pair before it is
//     needed.
//   • No score is shown mid-game. The moment it feels like a test it stops
//     being a game. The session tally is a count of taps, not a judgement.
//   • Endless and stoppable (D5). There is no run length and nothing pending,
//     so leaving at any point loses nothing.
//
// ⚠️ Gesture split, at the operator's direction: tapping a PHOTO browses that
// contender's gallery; an explicit Choose button commits. It costs one tap per
// comparison against tap-to-choose, and buys an answer that can never be given
// by accident while looking through pictures.
//
// ⚠️ Names are SHOWN, also at the operator's direction. The judgement being
// elicited is "which performer", not "which photograph" — which is what the
// downstream recommendation work needs, and it means a poor photo of someone
// well-liked no longer drags them down.

import SwiftUI
import LibraryCore

struct HeadToHeadView: View {
    let entityProfiles: EntityProfileIndex
    let libraryURL: URL?

    @StateObject private var model = HeadToHeadModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Head to Head")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    await model.load(profiles: entityProfiles, fallbackLibrary: libraryURL)
                }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            centred { ProgressView("Gathering contenders…") }

        case .unplayable(let reason):
            // T12 — a refusal that says why, rather than an empty board.
            centred {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Nothing to compare").font(.title3.bold())
                Text(reason)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

        case .failed(let message):
            centred {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text(message).font(.callout).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

        case .playing(let left, let right):
            VStack(spacing: 12) {
                // ⚠️ Horizontal on both platforms. Two contenders stacked
                // vertically on a phone cannot be compared without scrolling,
                // and a comparison you have to scroll to make is not a rapid
                // visual judgement.
                HStack(alignment: .top, spacing: 12) {
                    contender(left, choosing: .left)
                    contender(right, choosing: .right)
                }
                .padding(.horizontal, 12)

                secondaryAnswers
                footer
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - One contender

    private func contender(_ side: HeadToHeadModel.Side,
                           choosing outcome: PreferenceOutcome) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ProfileImageView(libraryURL: side.libraryURL,
                                 entityId: side.id,
                                 photoUrl: side.currentImage,
                                 isGallery: side.galleryIndex > 0) { image in
                    Color.clear.overlay(image.resizable().scaledToFill(), alignment: .top)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "person.fill")
                            .font(.system(size: 44)).foregroundStyle(.secondary))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture { model.browse(side) }

                // ⭐ Only when there IS more to see. A control that does
                // nothing teaches the operator to ignore the control.
                if side.hasMoreThanOneImage {
                    Label("\(side.galleryIndex % side.images.count + 1)/\(side.images.count)",
                          systemImage: "photo.on.rectangle")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }

            // Names shown — the judgement is about the performer.
            Text(side.name)
                .font(.headline)
                .lineLimit(2).minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                model.choose(outcome)
            } label: {
                Text("Choose").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // ⚠️ Large and reachable. This is the control pressed on every
            // single comparison, and it is the one the whole session's pace
            // depends on.
            .controlSize(.large)
        }
    }

    // MARK: - The other two answers

    private var secondaryAnswers: some View {
        HStack(spacing: 16) {
            // D6 — a draw is an ANSWER. Forcing a choice between two
            // contenders rated equally injects noise into every score they
            // touch.
            Button("Too close to call") { model.choose(.draw) }
                .buttonStyle(.bordered)

            // D6 — and "neither" means something different: neither belongs in
            // the ranking. No confirmation; undo is the safety net.
            Button("Neither", role: .destructive) { model.retireBoth() }
                .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Button {
                model.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canUndo && !model.canUndoRetirement)

            Spacer()

            // D5 — a tally, not a target. "14 of 20" would make stopping at
            // seven feel like waste, which is the opposite of what a
            // low-friction elicitation tool wants.
            Text(model.comparedThisSession == 1
                 ? "1 compared this session"
                 : "\(model.comparedThisSession) compared this session")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func centred<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(spacing: 10) { body() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// HeadToHeadBoard.swift
// Head to Head — the parts of the screen that are the same whatever is being
// ranked (#34, #38).
//
// TRACKED and PUBLIC. Names no source.
//
// ⭐ D1 says one mechanic, two subjects. The two contender CARDS differ — a
// performer shows a photo and a filmography, a video shows a frame and its cast
// — and everything around them does not: the refusal, the two secondary
// answers, the undo, the tally, the pool banner. They live here once so the
// game cannot come to feel like two games.
//
// ⚠️ The design constraints below are from the spec and are not decoration:
//
//   • The next pair is PREFETCHED by the model. A wait between taps ends a
//     session faster than anything else.
//   • No score is shown mid-game. The moment it feels like a test it stops
//     being a game. The session tally is a count of taps, not a judgement.
//   • Endless and stoppable (D5). There is no run length and nothing pending,
//     so leaving at any point loses nothing.

import SwiftUI
import LibraryCore

struct HeadToHeadBoard<Card: View>: View {
    @ObservedObject var model: HeadToHeadModel

    /// Whether a pool is narrowing the field, and what to say about it.
    let poolIsFiltered: Bool
    let poolBannerText: String
    let poolBannerSymbol: String
    /// Shown when there is nothing to compare — a subject-appropriate absence.
    let emptySymbol: String
    let onOpenPool: () -> Void

    @ViewBuilder let card: (HeadToHeadModel.Side, PreferenceOutcome) -> Card

    var body: some View {
        switch model.state {
        case .loading:
            centred { ProgressView("Gathering contenders…") }

        case .unplayable(let reason):
            // T12 — a refusal that says why, rather than an empty board.
            centred {
                Image(systemName: emptySymbol)
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
                poolBanner
                // ⚠️ Horizontal on both platforms. Two contenders stacked
                // vertically on a phone cannot be compared without scrolling,
                // and a comparison you have to scroll to make is not a rapid
                // visual judgement.
                HStack(alignment: .top, spacing: 12) {
                    card(left, .left)
                    card(right, .right)
                }
                .padding(.horizontal, 12)

                secondaryAnswers
                footer
            }
            .padding(.vertical, 12)
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

    /// ⚠️ Always visible when a pool is set. D1b's warning is that a filtered
    /// session quietly produces a ladder that cannot be compared with an
    /// unfiltered one; the mitigation the spec asks for is to SAY SO rather
    /// than to prevent it.
    @ViewBuilder
    private var poolBanner: some View {
        if poolIsFiltered {
            Button(action: onOpenPool) {
                Label(poolBannerText, systemImage: poolBannerSymbol)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
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

/// The "Choose" control, which is the same on every card.
///
/// ⚠️ Large and reachable. This is the control pressed on every single
/// comparison, and it is the one the whole session's pace depends on.
struct HeadToHeadChooseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Choose").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

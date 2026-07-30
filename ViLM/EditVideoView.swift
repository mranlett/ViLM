// EditVideoView.swift
// The "Edit Video" sheet on Video Details: Trim (set new start/end with a live
// range preview, copy-then-approve) and Flip (horizontal mirror, applied
// immediately). Both re-encode and replace the original file in place via
// LibraryCore's VideoEditingService; trim also rebases/drops scene markers.

import SwiftUI
import AVKit
import LibraryCore

struct EditVideoView: View {
    @Environment(\.dismiss) private var dismiss

    let asset: Asset
    let libraryURL: URL
    let sceneMarkers: [SceneMarker]
    let onCompleted: () -> Void

    enum Mode: String, CaseIterable { case trim = "Trim", flip = "Flip" }
    @State private var mode: Mode = .trim

    @State private var duration: Double = 0
    @State private var keepStart: Double = 0
    @State private var keepEnd: Double = 0
    @State private var player: AVPlayer?

    // Fine trim controls: which handle's timecode field is being edited, the
    // fields' text, and scrub bookkeeping (don't seek during initial load;
    // skip redundant seeks while a slider is dragged fast).
    enum TrimHandle: Hashable { case start, end }
    @FocusState private var focusedTimecode: TrimHandle?
    @State private var startText = ""
    @State private var endText = ""
    @State private var didLoad = false
    @State private var lastScrubTarget: Double = -1

    @State private var isWorking = false
    @State private var workingLabel = ""
    @State private var didComplete = false
    @State private var errorMessage: String?
    @State private var showTrimConfirm = false

    /// The library that owns this asset (falls back to the passed-in URL —
    /// identical in a single-library session).
    private var owningLibraryURL: URL { LibrarySession.shared.url(for: asset.id) ?? libraryURL }
    private var videoURL: URL { owningLibraryURL.appendingPathComponent(asset.relativePath) }

    private var droppedMarkerCount: Int {
        VideoEditingService.adjustMarkersForTrim(sceneMarkers, keepStart: keepStart, keepEnd: keepEnd).dropped.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if isWorking {
                    centered { ProgressView(workingLabel.isEmpty ? "Working…" : workingLabel)
                        Text("Re-encoding and replacing the video. This can take a while for long clips.")
                            .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32) }
                } else if didComplete {
                    centered {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundColor(.green)
                        Text("Done").font(.title3.bold())
                        Button("Close") { dismiss() }.buttonStyle(.bordered)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).padding()
                        switch mode {
                        case .trim: trimSection
                        case .flip: flipSection
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .navigationTitle("Edit Video")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { player?.pause(); dismiss() } } }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog("Apply trim?", isPresented: $showTrimConfirm, titleVisibility: .visible) {
                Button(droppedMarkerCount > 0 ? "Delete \(droppedMarkerCount) marker\(droppedMarkerCount == 1 ? "" : "s") & Trim" : "Trim",
                       role: .destructive) { Task { await applyTrim() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(droppedMarkerCount > 0
                     ? "\(droppedMarkerCount) scene marker\(droppedMarkerCount == 1 ? "" : "s") fall in the removed section and will be deleted. This re-encodes and replaces the original file."
                     : "This re-encodes and replaces the original file. It can't be undone.")
            }
            .task { await loadDuration() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 540)
        #endif
    }

    // MARK: - Trim

    @ViewBuilder
    private var trimSection: some View {
        VStack(spacing: 16) {
            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 200)
                    .cornerRadius(10)
            }
            VStack(spacing: 10) {
                handleRow(title: "Start", value: $keepStart, handle: .start, text: $startText)
                handleRow(title: "End", value: $keepEnd, handle: .end, text: $endText)
                Text("Keeping \(timeString(keepStart)) – \(timeString(keepEnd))  (\(timeString(max(0, keepEnd - keepStart))))")
                    .font(.caption).foregroundColor(.secondary)
            }
            // Keep the handles at least 0.5s apart and in order; mirror the
            // values into the timecode fields (unless being typed in); and
            // scrub the preview to the moved handle so the user sees the
            // exact frame they're cutting at.
            .onChange(of: keepStart) { _, v in
                if v > keepEnd - 0.5 { keepStart = max(0, keepEnd - 0.5); return }
                if focusedTimecode != .start { startText = timecodeString(v) }
                scrubPreview(to: v)
            }
            .onChange(of: keepEnd) { _, v in
                if v < keepStart + 0.5 { keepEnd = min(duration, keepStart + 0.5); return }
                if focusedTimecode != .end { endText = timecodeString(v) }
                scrubPreview(to: v)
            }
            HStack {
                Button("Preview Selection") { previewSelection() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Apply Trim") { showTrimConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(duration <= 0 || keepEnd - keepStart < 0.5)
            }
        }
        .padding(.horizontal)
    }

    // One trim handle: a coarse slider for big movements, plus fine controls —
    // ±1s nudge buttons and a directly editable timecode field (h:mm:ss, with
    // optional tenths like "1:23.5") for exact positioning.
    private func handleRow(title: String, value: Binding<Double>, handle: TrimHandle, text: Binding<String>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).frame(width: 44, alignment: .leading)
                Slider(value: value, in: 0...max(0.1, duration))
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 44)
                Button("−1s") { value.wrappedValue = max(0, value.wrappedValue - 1) }
                Button("+1s") { value.wrappedValue = min(duration, value.wrappedValue + 1) }
                TextField("0:00", text: text)
                    .font(.callout.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .multilineTextAlignment(.center)
                    .focused($focusedTimecode, equals: handle)
                    .onSubmit { commitTimecode(handle) }
#if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
#endif
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
        }
    }

    /// Parses and applies a typed timecode; on gibberish, snaps the field back
    /// to the current value. Range/order clamping is handled by the onChange
    /// observers like every other input path.
    private func commitTimecode(_ handle: TrimHandle) {
        let text = handle == .start ? startText : endText
        if let seconds = Self.parseTimecode(text) {
            let clamped = min(max(0, seconds), duration)
            switch handle {
            case .start: keepStart = clamped
            case .end: keepEnd = clamped
            }
        }
        // Re-canonicalize the field either way.
        switch handle {
        case .start: startText = timecodeString(keepStart)
        case .end: endText = timecodeString(keepEnd)
        }
        focusedTimecode = nil
    }

    /// Show the exact frame at a moved handle (paused, frame-accurate).
    /// AVPlayer cancels an in-flight seek when a new one arrives, so rapid
    /// slider drags coalesce naturally; the epsilon skips no-op churn.
    private func scrubPreview(to seconds: Double) {
        guard didLoad, let player else { return }
        guard abs(seconds - lastScrubTarget) > 0.03 else { return }
        lastScrubTarget = seconds
        player.pause()
        // Clear any end-cap left by a previous "Preview Selection" run so
        // scrubbing past it isn't blocked.
        player.currentItem?.forwardPlaybackEndTime = .invalid
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func previewSelection() {
        guard let player else { return }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: keepEnd, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: keepStart, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in player.play() }
    }

    private func applyTrim() async {
        player?.pause()
        isWorking = true; workingLabel = "Trimming…"
        do {
            try await VideoEditingService().trim(asset, in: owningLibraryURL, keepStart: keepStart, keepEnd: keepEnd)
            await MainActor.run { isWorking = false; didComplete = true; onCompleted() }
        } catch {
            await MainActor.run { isWorking = false; errorMessage = "Trim failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Flip

    private var flipSection: some View {
        centered {
            Image(systemName: "arrow.left.and.right.square").font(.system(size: 44)).foregroundColor(.accentColor)
            Text("Horizontal Flip").font(.title3.bold())
            Text("Mirrors the video left-to-right — the fix for backwards-rendering text (common with front-camera captures). Re-encodes and replaces the original; flip again to reverse.")
                .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Apply Horizontal Flip") { Task { await applyFlip() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func applyFlip() async {
        player?.pause()
        isWorking = true; workingLabel = "Flipping…"
        do {
            try await VideoEditingService().flip(asset, in: owningLibraryURL)
            await MainActor.run { isWorking = false; didComplete = true; onCompleted() }
        } catch {
            await MainActor.run { isWorking = false; errorMessage = "Flip failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Helpers

    private func loadDuration() async {
        let avAsset = AVURLAsset(url: videoURL)
        let seconds = (try? await avAsset.load(.duration).seconds) ?? 0
        await MainActor.run {
            duration = seconds
            keepStart = 0
            keepEnd = seconds
            startText = timecodeString(0)
            endText = timecodeString(seconds)
            player = AVPlayer(url: videoURL)
            didLoad = true // scrubbing only reacts to user changes from here on
        }
    }

    /// "m:ss" / "h:mm:ss", with tenths appended when fractional ("1:23.5").
    private func timecodeString(_ seconds: Double) -> String {
        let totalTenths = Int((max(0, seconds) * 10).rounded())
        let tenths = totalTenths % 10
        let total = totalTenths / 10
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return tenths > 0 ? "\(base).\(tenths)" : base
    }

    /// Accepts "90", "1:30", "1:23.5", or "1:02:03" → seconds. Nil on gibberish.
    nonisolated private static func parseTimecode(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count >= 1, parts.count <= 3, let last = parts.last,
              let seconds = Double(last), seconds >= 0 else { return nil }
        var total = seconds
        if parts.count >= 2 {
            guard let minutes = Int(parts[parts.count - 2]), minutes >= 0 else { return nil }
            total += Double(minutes * 60)
        }
        if parts.count == 3 {
            guard let hours = Int(parts[0]), hours >= 0 else { return nil }
            total += Double(hours * 3600)
        }
        return total
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

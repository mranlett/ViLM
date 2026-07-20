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

    @State private var isWorking = false
    @State private var workingLabel = ""
    @State private var didComplete = false
    @State private var errorMessage: String?
    @State private var showTrimConfirm = false

    private var videoURL: URL { libraryURL.appendingPathComponent(asset.relativePath) }

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
                handleRow(title: "Start", value: $keepStart)
                handleRow(title: "End", value: $keepEnd)
                Text("Keeping \(timeString(keepStart)) – \(timeString(keepEnd))  (\(timeString(max(0, keepEnd - keepStart))))")
                    .font(.caption).foregroundColor(.secondary)
            }
            // Keep the handles at least 0.5s apart, in order.
            .onChange(of: keepStart) { _, v in if v > keepEnd - 0.5 { keepStart = max(0, keepEnd - 0.5) } }
            .onChange(of: keepEnd) { _, v in if v < keepStart + 0.5 { keepEnd = min(duration, keepStart + 0.5) } }
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

    private func handleRow(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 44, alignment: .leading)
            Slider(value: value, in: 0...max(0.1, duration))
            Text(timeString(value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
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
            try await VideoEditingService().trim(asset, in: libraryURL, keepStart: keepStart, keepEnd: keepEnd)
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
            try await VideoEditingService().flip(asset, in: libraryURL)
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
            player = AVPlayer(url: videoURL)
        }
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

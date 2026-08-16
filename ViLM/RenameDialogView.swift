// RenameDialogView.swift
// Confirmation dialog for renaming a video file to its metadata-suggested
// name, showing old and new names side by side.

import SwiftUI
import LibraryCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RenameDialogView: View {
    let oldFileName: String
    @Binding var newFileName: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// Why the naming rules could not propose a name, when they could not.
    ///
    /// 🚨 Shown rather than worked around. The proposal used to come from
    /// `suggestedFileNameFromTags` — the old grammar — which always produced
    /// something, so a video the current rules deliberately refuse to file
    /// still got a confident suggestion built to a scheme nothing else uses.
    var namingSkip: NamingSkip?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Video File").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Old File Name:").font(.subheadline).foregroundColor(.secondary)
                HStack {
                    Text(oldFileName)
                    Spacer()
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(oldFileName, forType: .string)
                        #else
                        UIPasteboard.general.string = oldFileName
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("New File Name:").font(.subheadline).foregroundColor(.secondary)
                TextField("New name...", text: $newFileName, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                if let namingSkip {
                    Label(namingSkip.reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // ⚠️ Says what this does NOT do. The name comes from the
                    // same rules the plan uses, but this renames the file where
                    // it sits — filing it under its studio folder is the plan's
                    // job, and a dialog that quietly did only half of a
                    // two-part operation would read as the plan being broken.
                    Text("Suggested by the same naming rules as the Relocation Plan. This renames the file where it is; the plan is what also moves it into its folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Rename", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

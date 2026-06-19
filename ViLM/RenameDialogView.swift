import SwiftUI
import LibraryCore
import AppKit

struct RenameDialogView: View {
    let oldFileName: String
    @Binding var newFileName: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Video File").font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Old File Name:").font(.subheadline).foregroundColor(.secondary)
                HStack {
                    Text(oldFileName).lineLimit(1)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(oldFileName, forType: .string)
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
                TextField("New name...", text: $newFileName)
                    .textFieldStyle(.roundedBorder)
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

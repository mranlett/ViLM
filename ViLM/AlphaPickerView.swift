import SwiftUI

struct AlphaPickerView: View {
    @Binding var filter: Character?
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: {
                    filter = nil
                }) {
                    Text("All")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(filter == nil ? Color.accentColor : Color.secondary.opacity(0.2))
                        .foregroundColor(filter == nil ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                ForEach("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { $0 }, id: \.self) { letter in
                    Button(action: {
                        if filter == letter {
                            filter = nil
                        } else {
                            filter = letter
                        }
                    }) {
                        Text(String(letter))
                            .font(.caption2)
                            .frame(width: 24, height: 24)
                            .background(filter == letter ? Color.accentColor : Color.secondary.opacity(0.2))
                            .foregroundColor(filter == letter ? .white : .primary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

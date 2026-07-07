import SwiftUI

/// A single browsable help document, organized by screen. Present with
/// `initialTopicID` set to jump straight to the relevant section (used by the
/// "?" button on individual screens); leave it nil to open at the table of
/// contents (used by the standalone "Help" entry in Settings).
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var initialTopicID: String? = nil

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section("Contents") {
                        ForEach(HelpContent.topics) { topic in
                            Button(topic.title) {
                                withAnimation { proxy.scrollTo(topic.id, anchor: .top) }
                            }
                        }
                    }

                    ForEach(HelpContent.topics) { topic in
                        Section {
                            Text(topic.summary)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)

                            ForEach(topic.items) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.label)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(item.description)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            Text(topic.title)
                        }
                        .id(topic.id)
                    }
                }
                .onAppear {
                    if let initialTopicID {
                        // Defer slightly so the List has laid out before we scroll.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(initialTopicID, anchor: .top)
                        }
                    }
                }
            }
            .navigationTitle("Help")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

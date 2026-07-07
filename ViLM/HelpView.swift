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
                ScrollView {
                    // Plain ScrollView + LazyVStack rather than List: a List's
                    // internal representation doesn't reliably expose a
                    // `Section` as one identifiable view, so `ScrollViewReader`
                    // can't resolve `.id()` scroll targets attached to a
                    // Section — jump-to-section silently no-ops. Attaching the
                    // id directly to a plain VStack here works reliably.
                    LazyVStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Contents")
                                .font(.headline)
                            ForEach(HelpContent.topics) { topic in
                                Button(topic.title) {
                                    withAnimation { proxy.scrollTo(topic.id, anchor: .top) }
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(.horizontal)

                        Divider()

                        ForEach(HelpContent.topics) { topic in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(topic.title)
                                    .font(.title3.bold())
                                Text(topic.summary)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

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
                            }
                            .padding(.horizontal)
                            .id(topic.id)

                            Divider()
                        }
                    }
                    .padding(.vertical)
                }
                .onAppear {
                    if let initialTopicID {
                        // Defer until after the sheet's presentation animation
                        // and initial layout pass complete.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation { proxy.scrollTo(initialTopicID, anchor: .top) }
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

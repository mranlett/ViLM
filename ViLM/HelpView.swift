// HelpView.swift
// The browsable Help screen: table of contents plus every topic's controls,
// with declarative jump-to-section scrolling.

import SwiftUI

/// A single browsable help document, organized by screen. Present with
/// `initialTopicID` set to jump straight to the relevant section (used by the
/// "?" button on individual screens); leave it nil to open at the table of
/// contents (used by the standalone "Help" entry in Settings).
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var initialTopicID: String? = nil

    // Drives scrolling declaratively via .scrollPosition(id:) — assigning a
    // topic id scrolls to it, including the initial jump on appear, with no
    // timing assumptions. (This replaced a ScrollViewReader whose initial
    // scrollTo had to be delayed by a hardcoded 0.35s to outlast the sheet
    // presentation animation and first lazy-layout pass.)
    @State private var scrolledTopicID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                // Plain ScrollView + LazyVStack rather than List: a List's
                // internal representation doesn't reliably expose a `Section`
                // as one identifiable view, so scroll targets attached to a
                // Section silently no-op. Each topic renders as ONE child of
                // the lazy stack (divider included) so its ForEach identity
                // is the scroll target.
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Contents")
                            .font(.headline)
                        ForEach(HelpContent.topics) { topic in
                            Button(topic.title) {
                                withAnimation { scrolledTopicID = topic.id }
                            }
                            .font(.subheadline)
                        }

                        Divider()
                            .padding(.top, 14)
                    }
                    .padding(.horizontal)

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

                            Divider()
                                .padding(.top, 10)
                        }
                        .padding(.horizontal)
                        .id(topic.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical)
            }
            .scrollPosition(id: $scrolledTopicID, anchor: .top)
            .onAppear {
                if let initialTopicID {
                    scrolledTopicID = initialTopicID
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
        .macSheet(minWidth: 420, minHeight: 480)
    }
}

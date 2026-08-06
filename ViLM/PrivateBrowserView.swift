// PrivateBrowserView.swift
// Opens a link inside the app, leaving no trace.
//
// ⚠️ There is NO public API on either platform to force Safari into private
// browsing from an app — `SFSafariViewController` has no private mode and
// `NSWorkspace.open` cannot request one. Handing the URL to the system browser
// therefore writes it into that browser's history, which for a library of this
// kind is the one thing a "private tab" was meant to avoid.
//
// So the private tab is built here instead. `WKWebsiteDataStore.nonPersistent()`
// keeps cookies, cache, local storage and history in memory for the lifetime of
// this view and discards all of it on dismissal. Nothing is written to disk and
// nothing reaches Safari at all.
//
// Opening in the real browser stays available and is deliberately one tap away
// rather than the default — some links genuinely want a signed-in session, and
// that is a choice worth making knowingly rather than by accident.

import SwiftUI
import WebKit

struct PrivateBrowserView: View {
    let url: URL
    var title: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isLoading = true
    @State private var pageTitle: String?

    var body: some View {
        NavigationStack {
            PrivateWebView(url: url, isLoading: $isLoading, pageTitle: $pageTitle)
                .overlay(alignment: .top) {
                    if isLoading {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .navigationTitle(pageTitle ?? title ?? url.host() ?? "Link")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // The escape hatch. Named for what it does rather than
                        // "Safari", because the system browser may not be.
                        Button {
                            openURL(url)
                            dismiss()
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        .help("Opens in your normal browser, where it WILL appear in history.")
                    }
                }
        }
        .macSheet(minWidth: 900, minHeight: 700)
    }
}

/// The web view itself, sharing one non-persistent data store per presentation.
private struct PrivateWebView {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var pageTitle: String?

    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // ⚠️ This single line is what makes the whole screen private. A default
        // configuration writes cookies and history to the app's own persistent
        // store, which would be no better than the browser — worse, because
        // nothing would be visible to clear.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, pageTitle: $pageTitle)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let isLoading: Binding<Bool>
        private let pageTitle: Binding<String?>

        init(isLoading: Binding<Bool>, pageTitle: Binding<String?>) {
            self.isLoading = isLoading
            self.pageTitle = pageTitle
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
            pageTitle.wrappedValue = webView.title?.isEmpty == false ? webView.title : nil
        }

        // Failures stop the spinner rather than leaving it turning forever —
        // an unreachable host is an answer, not a pending state.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            isLoading.wrappedValue = false
        }
    }
}

#if os(macOS)
extension PrivateWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension PrivateWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

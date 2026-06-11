import SwiftUI
import WebKit
import AppKit
import Security
import Foundation
import MarcryptCore

/// Simple model for identifying a report to view.
struct ReportViewerItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var anchorFileID: String? = nil // For deep-linking to a specific file section
}

// MARK: - Report Viewer

struct ReportViewer: View {
    let report: ReportViewerItem
    @StateObject private var webViewState = ReportWebViewState()
    @State private var showBurnConfirm = false
    @State private var burnErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text(report.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    navigateBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(width: 100, height: 32)
                .disabled(!webViewState.canGoBack)

                Button {
                    printReport()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(width: 100, height: 32)

                SharePickerButton(url: report.url)
                    .frame(width: 100, height: 32)

                Button {
                    showBurnConfirm = true
                } label: {
                    Label("Burn", systemImage: "flame")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(width: 100, height: 32)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            // WebView content
            if FileManager.default.fileExists(atPath: report.url.path) {
                ReportWebView(
                    url: report.url,
                    state: webViewState,
                    anchorID: report.anchorFileID,
                    onPrintRequest: { printReport() },
                    onShareRequest: { shareReport() },
                    onBurnRequest: { showBurnConfirm = true }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.orange)
                    Text("Report file not found.")
                        .font(.system(size: 14, weight: .medium))
                    Text(report.url.path)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(ReportWindowKeyHandler(windowURL: report.url))
        .alert("Burn Report?", isPresented: $showBurnConfirm) {
            Button("Burn", role: .destructive) {
                burnReport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the report file.")
        }
        .alert("Burn Failed", isPresented: Binding(
            get: { burnErrorMessage != nil },
            set: { if !$0 { burnErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(burnErrorMessage ?? "Unable to securely erase the report.")
        }
    }

    private func printReport() {
        guard let webView = webViewState.webView else { return }
        let printInfo = NSPrintInfo.shared
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private func navigateBack() {
        guard let webView = webViewState.webView, webView.canGoBack else { return }
        webView.goBack()
    }

    private func shareReport() {
        let picker = NSSharingServicePicker(items: [report.url])
        if let window = reportWindow(), let contentView = window.contentView {
            picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        } else {
            picker.show(relativeTo: .zero, of: NSView(), preferredEdge: .minY)
        }
    }

    private func burnReport() {
        do {
            let fm = FileManager.default
            guard fm.fileExists(atPath: report.url.path) else { return }

            // Use SecureDeletionService for secure overwrite
            try SecureDeletionService.shared.shredFile(at: report.url)
            closeReportWindow()
        } catch {
            burnErrorMessage = error.localizedDescription
        }
    }

    private func closeReportWindow() {
        if let window = reportWindow() {
            window.performClose(nil)
        }
    }

    private func reportWindow() -> NSWindow? {
        let targetURL = report.url.standardizedFileURL
        if let window = NSApp.windows.first(where: { window in
            guard let representedURL = window.representedURL?.standardizedFileURL else {
                return false
            }
            return representedURL == targetURL
        }) {
            return window
        }
        return NSApp.windows.first { $0.title == report.title }
    }
}

// MARK: - WebView State

final class ReportWebViewState: ObservableObject {
    weak var webView: WKWebView?
    var lastLoadedURL: URL?
    @Published var canGoBack = false
}

// MARK: - WebView Wrapper

struct ReportWebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var state: ReportWebViewState
    var anchorID: String? = nil
    let onPrintRequest: () -> Void
    let onShareRequest: () -> Void
    let onBurnRequest: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: state,
            anchorID: anchorID,
            onPrintRequest: onPrintRequest,
            onShareRequest: onShareRequest,
            onBurnRequest: onBurnRequest
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: Coordinator.handlerName)
        let scriptSource = """
        if (!window.__marcryptPrintHook) {
            window.__marcryptPrintHook = true;
            window.__marcryptOriginalPrint = window.print;
            window.print = function() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.reportAction) {
                    window.webkit.messageHandlers.reportAction.postMessage({action: 'print'});
                } else if (window.__marcryptOriginalPrint) {
                    window.__marcryptOriginalPrint();
                }
            };
        }
        """
        let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        state.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let accessRoot = url.deletingLastPathComponent()
        let normalizedURL = url.standardizedFileURL
        let currentURL = nsView.url?.standardizedFileURL
        if state.lastLoadedURL != normalizedURL || currentURL != normalizedURL {
            nsView.loadFileURL(url, allowingReadAccessTo: accessRoot)
            state.lastLoadedURL = normalizedURL
        }
        state.webView = nsView
    }

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler, WKNavigationDelegate {
        static let handlerName = "reportAction"
        private let state: ReportWebViewState
        private let anchorID: String?
        private let onPrintRequest: () -> Void
        private let onShareRequest: () -> Void
        private let onBurnRequest: () -> Void

        init(state: ReportWebViewState, anchorID: String?, onPrintRequest: @escaping () -> Void, onShareRequest: @escaping () -> Void, onBurnRequest: @escaping () -> Void) {
            self.state = state
            self.anchorID = anchorID
            self.onPrintRequest = onPrintRequest
            self.onShareRequest = onShareRequest
            self.onBurnRequest = onBurnRequest
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Coordinator.handlerName else { return }
            if let body = message.body as? [String: Any],
               let action = body["action"] as? String {
                switch action {
                case "print": onPrintRequest()
                case "share": onShareRequest()
                case "burn": onBurnRequest()
                default: break
                }
            }
            if let action = message.body as? String, action == "print" {
                onPrintRequest()
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.canGoBack = webView.canGoBack
            // Deep-link to specific file section after page loads
            if let anchorID = anchorID {
                webView.evaluateJavaScript("document.getElementById('\(anchorID)')?.scrollIntoView({behavior:'smooth', block:'start'});")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.canGoBack = webView.canGoBack
        }
    }
}

// MARK: - Window Key Handler (Escape to close)

struct ReportWindowKeyHandler: NSViewRepresentable {
    let windowURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(windowURL: windowURL)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53,
                   NSApp.keyWindow?.representedURL?.standardizedFileURL == context.coordinator.windowURL.standardizedFileURL {
                    NSApp.keyWindow?.performClose(nil)
                    return nil
                }
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.windowURL = windowURL
    }

    final class Coordinator {
        var monitor: Any?
        var windowURL: URL

        init(windowURL: URL) {
            self.windowURL = windowURL
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Share Picker Button

struct SharePickerButton: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32),
            button.widthAnchor.constraint(equalToConstant: 100),
        ])
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.url = url
    }

    final class Coordinator: NSObject {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

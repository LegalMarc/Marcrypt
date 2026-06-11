import SwiftUI
import AppKit

// MARK: - Notification names

extension Notification.Name {
    static let marcryptHelpScrollToAnchor = Notification.Name("com.marclaw.marcrypt.helpScrollToAnchor")
}

// MARK: - LifecycleUtils

enum LifecycleUtils {
    /// Opens the singleton "Marcrypt Help" window (640×640).
    /// If already open, focuses it and scrolls to the requested anchor.
    @MainActor
    static func openHelpWindow(anchor: String? = nil) {
        if let window = NSApp.windows.first(where: { $0.title == "Marcrypt Help" }) {
            window.makeKeyAndOrderFront(nil)
            if let anchor {
                NotificationCenter.default.post(
                    name: .marcryptHelpScrollToAnchor,
                    object: nil,
                    userInfo: ["anchor": anchor]
                )
            }
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Marcrypt Help"
        window.center()
        window.contentView = NSHostingView(rootView: HelpView(initialAnchor: anchor))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - HelpView

struct HelpView: View {
    @State private var htmlContent: String = ""
    @State private var pendingAnchor: String?
    let initialAnchor: String?

    init(initialAnchor: String? = nil) {
        self.initialAnchor = initialAnchor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if htmlContent.isEmpty {
                ProgressView("Loading help…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HelpHTMLView(htmlContent: htmlContent, scrollToAnchor: $pendingAnchor)
            }

            HStack {
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("help.close")
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            loadHelpContent()
            if let anchor = initialAnchor {
                pendingAnchor = anchor
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .marcryptHelpScrollToAnchor)) { notification in
            if let anchor = notification.userInfo?["anchor"] as? String {
                pendingAnchor = anchor
            }
        }
    }

    // MARK: Resource loading

    private func loadHelpContent() {
        if let content = findHelpHTML() {
            htmlContent = content
        } else {
            htmlContent = """
            <!DOCTYPE html><html><body style="font-family:system-ui;padding:24px">
            <h2>Help content could not be loaded.</h2>
            <p>Please reinstall Marcrypt.</p>
            </body></html>
            """
        }
    }

    private func findHelpHTML() -> String? {
        // Build a prioritised list of bundles to search.
        // Under SwiftPM (swift run / swift test) Bundle.module is synthesised
        // and contains the resource bundle; under the Xcode-built .app,
        // SWIFT_PACKAGE is not defined so we skip it and fall through to
        // Bundle.main and its resource URL.
        var bundles: [Bundle] = []

        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif

        bundles.append(Bundle.main)

        // Also probe the SwiftPM-generated resource bundle that may sit next
        // to the executable when running via `swift run`.
        if let resourceBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("Marcrypt_Marcrypt.bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL) {
            bundles.append(resourceBundle)
        }

        for bundle in bundles {
            // Standard lookup (works for both .copy and .process resources)
            if let url = bundle.url(forResource: "help", withExtension: "html"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
            // Subdirectory variant (SwiftPM .copy preserves "Resources/" prefix)
            if let url = bundle.url(forResource: "help", withExtension: "html", subdirectory: "Resources"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        // Last-resort: check for the file directly relative to the resource URL
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("help.html"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/help.html"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        return nil
    }
}

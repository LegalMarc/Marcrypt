import SwiftUI
import MarcryptCore
import AppKit

struct WindowBackgroundView: NSViewRepresentable {
    @Environment(\.colorScheme) var colorScheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.backgroundColor = NSColor(CustomColors.appBackground(for: colorScheme))
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            window.backgroundColor = NSColor(CustomColors.appBackground(for: colorScheme))
        }
    }
}

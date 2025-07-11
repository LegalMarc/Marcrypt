import SwiftUI

@main
struct MarcryptApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Marcrypt") {
                    // This opens the custom AboutView in a new window.
                    openWindow(id: "about")
                }
            }
        }
        
        // Define the window for the About view.
        Window("About Marcrypt", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize) // Makes the window non-resizable
    }
} 
import SwiftUI
import PDFKit
import MarcryptCore
import Darwin // For fflush

@main
struct MarcryptApp: App {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("AppTheme") private var appThemeRaw = AppTheme.system.rawValue

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .system
    }

    // Removed init() to avoid blocking Main Thread before App Launch

    static func runHeadlessEncryption() {
        // Usage: --headless-encrypt <input_path> <output_folder> --password-stdin
        let args = CommandLine.arguments
        if args.contains("--headless-smoke") {
            runHeadlessSmoke()
            return
        }

        guard let index = args.firstIndex(of: "--headless-encrypt"),
              args.count > index + 3,
              args[index + 3] == "--password-stdin" else {
            print("Error: Missing arguments. Usage: --headless-encrypt <input> <output> --password-stdin or --headless-smoke --password-stdin")
            fflush(stdout)
            exit(1)
        }

        let inputPath = args[index + 1]
        let outputPath = args[index + 2]
        let password: String
        do {
            password = try readHeadlessPassword()
        } catch {
            print("Error: Password was not provided on standard input.")
            fflush(stdout)
            exit(1)
        }

        print("Running Headless Encryption...")
        print("Input: \(URL(fileURLWithPath: inputPath).lastPathComponent)")
        fflush(stdout)

        Task {
            let inputURL = URL(fileURLWithPath: inputPath)
            let outputURL = URL(fileURLWithPath: outputPath)

            // Ensure input exists
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print("Error: Input file NOT found: \(inputURL.lastPathComponent)")
                fflush(stdout)
                exit(1)
            }

            print("File loaded. Starting encryption of 1 item...")
            fflush(stdout)

            do {
                try await encryptHeadless(inputURL: inputURL, outputDirectory: outputURL, password: password)
                print("SUCCESS: Encrypted 1/1 files.")
                fflush(stdout)
                exit(0)
            } catch {
                print("FAILURE: \(redactedHeadlessError(error))")
                fflush(stdout)
                exit(1)
            }
        }
    }

    private static func runHeadlessSmoke() {
        guard CommandLine.arguments.contains("--password-stdin") else {
            print("Error: Missing arguments. Usage: --headless-smoke --password-stdin")
            fflush(stdout)
            exit(1)
        }

        let password: String
        do {
            password = try readHeadlessPassword()
        } catch {
            print("Error: Password was not provided on standard input.")
            fflush(stdout)
            exit(1)
        }

        print("Running Headless Smoke...")
        fflush(stdout)

        Task {
            do {
                let root = try TempFileManager.shared.createTempDirectory()
                defer { TempFileManager.shared.release(url: root) }

                let source = root.appendingPathComponent("source")
                let output = root.appendingPathComponent("output")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try "signed app smoke\n".write(
                    to: source.appendingPathComponent("sample.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                try await encryptHeadless(inputURL: source, outputDirectory: output, password: password)
                let encryptedOutput = output.appendingPathComponent("source.zip")
                guard FileManager.default.fileExists(atPath: encryptedOutput.path) else {
                    throw MarcryptError.internalError("Headless smoke did not produce encrypted output.")
                }

                print("SUCCESS: Headless smoke encrypted 1/1 files.")
                fflush(stdout)
                exit(0)
            } catch {
                print("FAILURE: \(redactedHeadlessError(error))")
                fflush(stdout)
                exit(1)
            }
        }
    }

    private static func encryptHeadless(inputURL: URL, outputDirectory: URL, password: String) async throws {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw MarcryptError.internalError("Input file was not found.")
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        if isDirectory.boolValue {
            let outputURL = outputDirectory
                .appendingPathComponent(inputURL.lastPathComponent)
                .appendingPathExtension("zip")
            try await ArchiveService.shared.zipFolder(at: inputURL, to: outputURL, password: password)
            return
        }

        let outputURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
        switch inputURL.pathExtension.lowercased() {
        case "docx":
            try await DocxEncryptionService.shared.encrypt(docxFile: inputURL, to: outputURL, password: password)
        case "pdf":
            guard let document = PDFDocument(url: inputURL) else {
                throw MarcryptError.internalError("Could not read PDF document.")
            }
            _ = try PdfProcessingService.shared.writeEncryptedPDF(document: document, to: outputURL, password: password)
        default:
            throw MarcryptError.internalError("Unsupported input type for headless encryption.")
        }
    }

    private static func redactedHeadlessError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Encryption failed."
    }

    private static func readHeadlessPassword() throws -> String {
        var oldTerm = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &oldTerm) == 0
        if hasTerminal {
            var newTerm = oldTerm
            newTerm.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &newTerm)
        }
        defer {
            if hasTerminal {
                tcsetattr(STDIN_FILENO, TCSANOW, &oldTerm)
            }
        }

        guard let line = readLine(), !line.isEmpty else {
            throw MarcryptError.internalError("Missing headless password")
        }
        return line
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
// ... existing body content ...
            ZStack {
                if CommandLine.arguments.contains("--headless-encrypt") || CommandLine.arguments.contains("--headless-smoke") {
                    ProgressView("Process Mode...")
                    // Logic moved to AppDelegate
                } else {
                    ContentView()
                        .preferredColorScheme(appTheme.colorScheme)
                        .onAppear {
                            NSApp.appearance = appTheme.appearance
                        }
                        .onChange(of: appThemeRaw) { _, _ in
                            NSApp.appearance = appTheme.appearance
                        }
                }
            }
        }
// ... existing body modifiers ...
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Marcrypt") {
                    openWindow(id: "about")
                }
            }

            CommandGroup(replacing: .help) {
                Button("Marcrypt Help") {
                    LifecycleUtils.openHelpWindow()
                }
                .keyboardShortcut("?", modifiers: .command)
                .accessibilityIdentifier("menu.help")

                Divider()

                Link("About the author", destination: URL(string: "https://www.linkedin.com/in/marcmandel/")!)
                Link("Visit Website", destination: URL(string: "https://github.com/LegalMarc/Marcrypt")!)
            }
        }

        Window("About Marcrypt", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .preferredColorScheme(appTheme.colorScheme)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--headless-encrypt") || CommandLine.arguments.contains("--headless-smoke") {
            // Activate app to ensure runloop processes events immediately
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)

            MarcryptApp.runHeadlessEncryption()
        }
    }
}

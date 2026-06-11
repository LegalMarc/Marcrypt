import Foundation
import ArgumentParser
import MarcryptCore
import PDFKit
import Darwin

private func displayPath(_ url: URL) -> String {
    url.lastPathComponent
}

@main
struct MarcryptCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marcrypt",
        abstract: "A utility for testing Marcrypt features.",
        subcommands: [
            EncryptCommand.self,
            DecryptCommand.self,
            WatermarkCommand.self,
            BatesCommand.self,
            PreflightCommand.self,
            ClearHistoryCommand.self
        ]
    )
}

struct EncryptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "encrypt", abstract: "Encrypt a PDF, DOCX, or archive a folder as a ZIP.")

    @Argument(help: "The input file or folder path.")
    var input: String

    @Argument(help: "The output file path.")
    var output: String

    @Flag(help: "Read the encryption password from standard input.")
    var passwordStdin = false

    @Flag(help: "Use a unique output path if the requested output already exists.")
    var keepBoth = false

    @Flag(help: "Replace an existing file output. Non-empty directories are never replaced.")
    var replace = false

    @Flag(
        name: [.customLong("remove-originals"), .customLong("shred-originals")],
        help: "After successful encryption, overwrite then remove the original. Best-effort only on SSD/APFS."
    )
    var removeOriginals = false

    mutating func run() async throws {
        try validateCollisionFlags(keepBoth: keepBoth, replace: replace)
        let sourceURL = URL(fileURLWithPath: input)
        let requestedDestURL = URL(fileURLWithPath: output)
        let password = try readCLISecret(prompt: "Encryption password: ", fromStdin: passwordStdin)
        let inputHash = await BatchReportService.sha256(of: sourceURL)

        if requestedDestURL.pathExtension.lowercased() == "pdf" || sourceURL.pathExtension.lowercased() == "pdf" {
            try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: requestedDestURL)
            let output = try resolveOutputURL(requestedDestURL, keepBoth: keepBoth, replace: replace, outputKind: .file)
            guard let pdf = PDFDocument(url: sourceURL) else {
                print("Failed to read PDF document.")
                throw ExitCode.failure
            }
            do {
                _ = try PdfProcessingService.shared.writeEncryptedPDF(document: pdf, to: output.workingURL, password: password)
                try finalizeOutput(output)
                logCLISuccess(operation: .encrypt, input: sourceURL, inputHash: inputHash, output: output.finalURL, parameters: ["type": "PDF"])
                print("Successfully encrypted PDF to \(displayPath(output.finalURL))")
            } catch {
                cleanupWorkingOutput(output)
                throw error
            }
        } else if requestedDestURL.pathExtension.lowercased() == "docx" || sourceURL.pathExtension.lowercased() == "docx" {
            try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: requestedDestURL)
            let output = try resolveOutputURL(requestedDestURL, keepBoth: keepBoth, replace: replace, outputKind: .file)
            do {
                try await DocxEncryptionService.shared.encrypt(docxFile: sourceURL, to: output.workingURL, password: password)
                try finalizeOutput(output)
                logCLISuccess(operation: .encrypt, input: sourceURL, inputHash: inputHash, output: output.finalURL, parameters: ["type": "DOCX"])
                print("Successfully encrypted DOCX to \(displayPath(output.finalURL))")
            } catch {
                cleanupWorkingOutput(output)
                throw error
            }
        } else {
            try validateArchiveSource(sourceURL)
            try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: requestedDestURL)
            try validateOutputOutsideSourceTree(sourceURL: sourceURL, requestedURL: requestedDestURL)
            let output = try resolveOutputURL(requestedDestURL, keepBoth: keepBoth, replace: replace, outputKind: .file)
            // Assume Zip
            do {
                try await ArchiveService.shared.zipFolder(at: sourceURL, to: output.workingURL, password: password)
                try finalizeOutput(output)
                logCLISuccess(operation: .encrypt, input: sourceURL, inputHash: inputHash, output: output.finalURL, parameters: ["type": "ZIP"])
                print("Successfully zipped folder to \(displayPath(output.finalURL))")
            } catch {
                cleanupWorkingOutput(output)
                throw error
            }
        }

        if removeOriginals {
            try SecureDeletionService.shared.shredItem(at: sourceURL)
            print("Original overwritten then removed. Note: overwrite-based removal is best-effort on SSD/APFS storage.")
        }
    }
}

struct DecryptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "decrypt", abstract: "Decrypt a DOCX or unzip an archive.")

    @Argument(help: "The input file path.")
    var input: String

    @Argument(help: "The output file or folder path.")
    var output: String

    @Flag(help: "Read the decryption password from standard input.")
    var passwordStdin = false

    @Flag(help: "Use a unique output path if the requested output already exists.")
    var keepBoth = false

    @Flag(help: "Replace an existing file output. Non-empty directories are never replaced.")
    var replace = false

    mutating func run() async throws {
        try validateCollisionFlags(keepBoth: keepBoth, replace: replace)
        let sourceURL = URL(fileURLWithPath: input)
        let requestedDestURL = URL(fileURLWithPath: output)
        let password = try readCLISecret(prompt: "Decryption password: ", fromStdin: passwordStdin)
        let inputHash = await BatchReportService.sha256(of: sourceURL)

        if sourceURL.pathExtension.lowercased() == "pdf" {
             print("Decryption is not supported yet entirely safely via CLI for PDF - requires specific implementation beyond current services scope.")
             throw ExitCode.failure
        } else if sourceURL.pathExtension.lowercased() == "zip" {
            try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: requestedDestURL)
            let output = try resolveOutputURL(requestedDestURL, keepBoth: keepBoth, replace: replace, outputKind: .directory)
            do {
                try await ArchiveService.shared.unzip(archiveAt: sourceURL, to: output.workingURL, password: password)
                try finalizeOutput(output)
                logCLISuccess(operation: .decrypt, input: sourceURL, inputHash: inputHash, output: output.finalURL, parameters: ["type": "ZIP"])
                print("Successfully unzipped archive to \(displayPath(output.finalURL))")
            } catch {
                cleanupWorkingOutput(output)
                throw error
            }
        } else if sourceURL.pathExtension.lowercased() == "docx" {
            try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: requestedDestURL)
            let output = try resolveOutputURL(requestedDestURL, keepBoth: keepBoth, replace: replace, outputKind: .file)
            let decryptedData = try await DocxEncryptionService.shared.decrypt(docxFile: sourceURL, password: password)
            do {
                try decryptedData.write(to: output.workingURL, options: .atomic)
                try finalizeOutput(output)
                logCLISuccess(operation: .decrypt, input: sourceURL, inputHash: inputHash, output: output.finalURL, parameters: ["type": "DOCX"])
                print("Successfully decrypted DOCX to \(displayPath(output.finalURL))")
            } catch {
                cleanupWorkingOutput(output)
                throw error
            }
        } else {
             print("Decryption is only supported for DOCX files and ZIP archives.")
             throw ExitCode.failure
        }
    }
}

private func readCLISecret(prompt: String, fromStdin: Bool) throws -> String {
    if fromStdin {
        guard let line = readLine(), !line.isEmpty else {
            print("Password was not provided on standard input.")
            throw ExitCode.failure
        }
        return line
    }

    fputs(prompt, stderr)
    fflush(stderr)

    var oldTerm = termios()
    guard tcgetattr(STDIN_FILENO, &oldTerm) == 0 else {
        guard let line = readLine(), !line.isEmpty else { throw ExitCode.failure }
        return line
    }

    var newTerm = oldTerm
    newTerm.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTerm)
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &oldTerm)
        fputs("\n", stderr)
    }

    guard let line = readLine(), !line.isEmpty else {
        print("Password was not provided.")
        throw ExitCode.failure
    }
    return line
}

private enum CLIOutputKind {
    case file
    case directory
}

private struct CLIOutputResolution {
    let finalURL: URL
    let workingURL: URL
    let outputKind: CLIOutputKind

    var usesStaging: Bool {
        finalURL.standardizedFileURL.path != workingURL.standardizedFileURL.path
    }
}

private func validateCollisionFlags(keepBoth: Bool, replace: Bool) throws {
    guard !(keepBoth && replace) else {
        throw ValidationError("Use either --keep-both or --replace, not both.")
    }
}

private func validateArchiveSource(_ sourceURL: URL) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ValidationError("Archive encryption requires an existing folder input: \(displayPath(sourceURL))")
    }
    guard fileManager.isReadableFile(atPath: sourceURL.path) else {
        throw ValidationError("Archive input is not readable: \(displayPath(sourceURL))")
    }
}

private func validateDistinctSourceAndOutput(sourceURL: URL, requestedURL: URL) throws {
    guard sourceURL.standardizedFileURL.path != requestedURL.standardizedFileURL.path else {
        throw ValidationError("Input and output paths must be different: \(displayPath(requestedURL))")
    }
}

private func validateOutputOutsideSourceTree(sourceURL: URL, requestedURL: URL) throws {
    let sourcePath = sourceURL.standardizedFileURL.path
    let outputPath = requestedURL.standardizedFileURL.path
    guard !outputPath.hasPrefix(sourcePath + "/") else {
        throw ValidationError("Output path must not be inside the source folder: \(displayPath(requestedURL))")
    }
}

private func resolveOutputURL(_ requestedURL: URL, keepBoth: Bool, replace: Bool, outputKind: CLIOutputKind) throws -> CLIOutputResolution {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory) else {
        return CLIOutputResolution(finalURL: requestedURL, workingURL: requestedURL, outputKind: outputKind)
    }

    if keepBoth {
        let unique = uniqueURL(for: requestedURL)
        return CLIOutputResolution(finalURL: unique, workingURL: unique, outputKind: outputKind)
    }

    guard replace else {
        throw ValidationError("Output already exists: \(displayPath(requestedURL)). Use --keep-both or --replace.")
    }

    switch outputKind {
    case .file:
        guard !isDirectory.boolValue else {
            throw ValidationError("Refusing to replace directory with file output: \(displayPath(requestedURL))")
        }
        return CLIOutputResolution(finalURL: requestedURL, workingURL: stagingURL(for: requestedURL), outputKind: outputKind)
    case .directory:
        if isDirectory.boolValue {
            let contents = try fileManager.contentsOfDirectory(at: requestedURL, includingPropertiesForKeys: nil)
            guard contents.isEmpty else {
                throw ValidationError("Refusing to replace non-empty directory: \(displayPath(requestedURL))")
            }
        }
        return CLIOutputResolution(finalURL: requestedURL, workingURL: stagingURL(for: requestedURL), outputKind: outputKind)
    }
}

private func uniqueURL(for requestedURL: URL) -> URL {
    let fileManager = FileManager.default
    let directory = requestedURL.deletingLastPathComponent()
    let ext = requestedURL.pathExtension
    let baseName = ext.isEmpty
        ? requestedURL.lastPathComponent
        : requestedURL.deletingPathExtension().lastPathComponent

    var index = 2
    while index < 2000 {
        let candidateName = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
        let candidate = directory.appendingPathComponent(candidateName)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        index += 1
    }

    let fallbackName = ext.isEmpty
        ? "\(baseName)-\(UUID().uuidString)"
        : "\(baseName)-\(UUID().uuidString).\(ext)"
    return directory.appendingPathComponent(fallbackName)
}

private func stagingURL(for finalURL: URL) -> URL {
    let directory = finalURL.deletingLastPathComponent()
    return directory.appendingPathComponent(".marcrypt-\(UUID().uuidString)-\(finalURL.lastPathComponent)")
}

private func cleanupWorkingOutput(_ output: CLIOutputResolution) {
    guard output.usesStaging else { return }
    try? SecureDeletionService.shared.shredItem(at: output.workingURL)
}

private func finalizeOutput(_ output: CLIOutputResolution) throws {
    guard output.usesStaging else { return }

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: output.workingURL.path) else {
        throw ValidationError("Expected output was not created: \(displayPath(output.workingURL))")
    }

    var finalIsDirectory: ObjCBool = false
    let finalExists = fileManager.fileExists(atPath: output.finalURL.path, isDirectory: &finalIsDirectory)

    switch output.outputKind {
    case .file:
        guard !finalExists || !finalIsDirectory.boolValue else {
            throw ValidationError("Refusing to replace directory with file output: \(displayPath(output.finalURL))")
        }
        if finalExists {
            _ = try fileManager.replaceItemAt(output.finalURL, withItemAt: output.workingURL)
        } else {
            try fileManager.moveItem(at: output.workingURL, to: output.finalURL)
        }
    case .directory:
        if finalExists {
            if finalIsDirectory.boolValue {
                let contents = try fileManager.contentsOfDirectory(at: output.finalURL, includingPropertiesForKeys: nil)
                guard contents.isEmpty else {
                    throw ValidationError("Refusing to replace non-empty directory: \(displayPath(output.finalURL))")
                }
            }
            try fileManager.removeItem(at: output.finalURL)
        }
        try fileManager.moveItem(at: output.workingURL, to: output.finalURL)
    }
}

private func logCLISuccess(
    operation: AuditService.AuditOperation,
    input: URL,
    inputHash: String?,
    output: URL,
    parameters: [String: String] = [:]
) {
    AuditService.shared.logSuccess(
        operation: operation,
        inputFile: input.lastPathComponent,
        inputHash: inputHash == "N/A" ? nil : inputHash,
        outputFile: output.lastPathComponent,
        outputHash: try? IntegrityService.shared.sha256(of: output),
        parameters: parameters
    )
}

private func validateWatermarkOptions(size: Int, opacity: Double, location: Int, colorHex: String) throws {
    guard size > 0 else { throw ValidationError("--size must be greater than 0.") }
    guard (0.0...1.0).contains(opacity) else { throw ValidationError("--opacity must be between 0 and 1.") }
    guard (0...9).contains(location) else { throw ValidationError("--location must be between 0 and 9.") }
    guard isValidHexColor(colorHex) else { throw ValidationError("--color must be a 6-digit hex color like #FF0000.") }
}

private func validateBatesOptions(startNumber: Int, digitCount: Int, location: Int, fontFamily: Int, fontSize: Int, colorHex: String) throws {
    guard startNumber > 0 else { throw ValidationError("<start-number> must be greater than 0.") }
    guard digitCount > 0 else { throw ValidationError("--digit-count must be greater than 0.") }
    guard (0...9).contains(location) else { throw ValidationError("--location must be between 0 and 9.") }
    guard (0...2).contains(fontFamily) else { throw ValidationError("--font-family must be 0, 1, or 2.") }
    guard fontSize > 0 else { throw ValidationError("--font-size must be greater than 0.") }
    guard isValidHexColor(colorHex) else { throw ValidationError("--color must be a 6-digit hex color like #000000.") }
}

private func isValidHexColor(_ value: String) -> Bool {
    let trimmed = value.hasPrefix("#") ? String(value.dropFirst()) : value
    return trimmed.count == 6 && UInt64(trimmed, radix: 16) != nil
}

struct WatermarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watermark", abstract: "Add a watermark to a PDF or DOCX.")

    @Argument(help: "The input file path.")
    var input: String

    @Argument(help: "The output file path.")
    var output: String

    @Argument(help: "The watermark text.")
    var text: String

    @Option(help: "Watermark font size in points.")
    var size = 24

    @Option(help: "Watermark opacity from 0 to 1.")
    var opacity = 0.5

    @Option(help: "Watermark location code, 0...9.")
    var location = 0

    @Option(help: "Watermark color as a 6-digit hex value.")
    var color = "#FF0000"

    @Flag(help: "Use a unique output path if the requested output already exists.")
    var keepBoth = false

    @Flag(help: "Replace an existing file output.")
    var replace = false

    mutating func run() async throws {
        try validateCollisionFlags(keepBoth: keepBoth, replace: replace)
        try validateWatermarkOptions(size: size, opacity: opacity, location: location, colorHex: color)
        let sourceURL = URL(fileURLWithPath: input)
        let inputHash = await BatchReportService.sha256(of: sourceURL)
        try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: URL(fileURLWithPath: output))
        let outputURL = try resolveOutputURL(
            URL(fileURLWithPath: output),
            keepBoth: keepBoth,
            replace: replace,
            outputKind: .file
        )

        let config = PdfProcessingService.WatermarkConfig(
            text: text,
            size: size,
            opacity: opacity,
            location: location,
            colorHex: color,
            batesEnabled: false
        )

        if sourceURL.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: sourceURL) else {
                print("Failed to read PDF document.")
                throw ExitCode.failure
            }
            do {
                _ = try PdfProcessingService.shared.writeWatermarkedPDF(document: pdf, to: outputURL.workingURL, watermark: config, startBates: 1)
                try finalizeOutput(outputURL)
                logCLISuccess(operation: .watermark, input: sourceURL, inputHash: inputHash, output: outputURL.finalURL)
                print("Successfully watermarked PDF to \(displayPath(outputURL.finalURL))")
            } catch {
                cleanupWorkingOutput(outputURL)
                throw error
            }
        } else if sourceURL.pathExtension.lowercased() == "docx" {
            let options = DocxService.Options(openPassword: "", modifyPassword: "", restriction: .none, markAsFinal: false, watermark: config)
            do {
                _ = try await DocxService.shared.protect(docxAt: sourceURL, to: outputURL.workingURL, options: options)
                try finalizeOutput(outputURL)
                logCLISuccess(operation: .watermark, input: sourceURL, inputHash: inputHash, output: outputURL.finalURL)
                print("Successfully watermarked DOCX to \(displayPath(outputURL.finalURL))")
            } catch {
                cleanupWorkingOutput(outputURL)
                throw error
            }
        } else {
             print("Watermarking is only supported for PDFs and DOCXs.")
             throw ExitCode.failure
        }
    }
}

struct BatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bates", abstract: "Add Bates numbering to a PDF or DOCX.")

    @Argument(help: "The input file path.")
    var input: String

    @Argument(help: "The output file path.")
    var output: String

    @Argument(help: "The Bates prefix.")
    var prefix: String

    @Argument(help: "The starting Bates number.")
    var startNumber: Int

    @Option(help: "Bates digit count for zero-padding.")
    var digitCount = 6

    @Option(help: "Bates location code, 0...9.")
    var location = 2

    @Option(help: "Bates font family: 0=sans, 1=serif, 2=mono.")
    var fontFamily = 2

    @Option(help: "Bates font size in points.")
    var fontSize = 10

    @Option(help: "Bates color as a 6-digit hex value.")
    var color = "#000000"

    @Flag(help: "Append an ISO-8601 timestamp to each Bates stamp.")
    var includeTimestamp = false

    @Flag(help: "Use a unique output path if the requested output already exists.")
    var keepBoth = false

    @Flag(help: "Replace an existing file output.")
    var replace = false

    mutating func run() async throws {
        try validateCollisionFlags(keepBoth: keepBoth, replace: replace)
        try validateBatesOptions(
            startNumber: startNumber,
            digitCount: digitCount,
            location: location,
            fontFamily: fontFamily,
            fontSize: fontSize,
            colorHex: color
        )
        let sourceURL = URL(fileURLWithPath: input)
        let inputHash = await BatchReportService.sha256(of: sourceURL)
        try validateDistinctSourceAndOutput(sourceURL: sourceURL, requestedURL: URL(fileURLWithPath: output))
        let outputURL = try resolveOutputURL(
            URL(fileURLWithPath: output),
            keepBoth: keepBoth,
            replace: replace,
            outputKind: .file
        )

        let config = PdfProcessingService.WatermarkConfig(
            text: "",
            size: 24,
            opacity: 0,
            location: 0,
            batesEnabled: true,
            batesPrefix: prefix,
            batesStartNumber: startNumber,
            batesDigitCount: digitCount,
            batesLocation: location,
            batesFontFamily: fontFamily,
            batesFontSize: fontSize,
            batesColorHex: color,
            batesIncludeTimestamp: includeTimestamp
        )

        if sourceURL.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: sourceURL) else {
                print("Failed to read PDF document.")
                throw ExitCode.failure
            }
            do {
                _ = try PdfProcessingService.shared.writeWatermarkedPDF(document: pdf, to: outputURL.workingURL, watermark: config, startBates: startNumber)
                try finalizeOutput(outputURL)
                logCLISuccess(operation: .batesStamp, input: sourceURL, inputHash: inputHash, output: outputURL.finalURL)
                print("Successfully applied Bates numbering to PDF to \(displayPath(outputURL.finalURL))")
            } catch {
                cleanupWorkingOutput(outputURL)
                throw error
            }
        } else if sourceURL.pathExtension.lowercased() == "docx" {
            let options = DocxService.Options(openPassword: "", modifyPassword: "", restriction: .none, markAsFinal: false, watermark: config)
            do {
                _ = try await DocxService.shared.protect(docxAt: sourceURL, to: outputURL.workingURL, options: options, startBates: startNumber)
                try finalizeOutput(outputURL)
                logCLISuccess(operation: .batesStamp, input: sourceURL, inputHash: inputHash, output: outputURL.finalURL)
                print("Successfully applied Bates numbering to DOCX to \(displayPath(outputURL.finalURL))")
            } catch {
                cleanupWorkingOutput(outputURL)
                throw error
            }
        } else {
             print("Bates numbering is only supported for PDFs and DOCXs.")
             throw ExitCode.failure
        }
    }
}

struct PreflightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preflight", abstract: "Validate inputs, destination permissions, and estimated disk space.")

    @Option(help: "The destination directory to validate.")
    var destination: String

    @Argument(help: "Input file or folder paths.")
    var inputs: [String]

    mutating func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one input path is required.")
        }

        let inputURLs = inputs.map { URL(fileURLWithPath: $0) }
        let destinationURL = URL(fileURLWithPath: destination)
        let result = await PreFlightValidator.validate(fileURLs: inputURLs, destination: destinationURL)
        let formatter = ByteCountFormatter()

        print("Preflight \(result.isOK ? "passed" : "failed")")
        print("Required space estimate: \(formatter.string(fromByteCount: result.requiredBytes))")
        print("Available space: \(formatter.string(fromByteCount: result.availableBytes))")
        print("Destination writable: \(result.hasWritePermission ? "yes" : "no")")

        if !result.issues.isEmpty {
            print("Issues:")
            for issue in result.issues {
                print("- \(issue)")
            }
        }

        if !result.isOK {
            throw ExitCode.failure
        }
    }
}

struct ClearHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear-history", abstract: "Clear app logs, audit history, and app-controlled temporary files.")

    mutating func run() async throws {
        let result = await HistoryCleanupService.shared.clearHistoryAsync()
        if result.succeeded {
            print("History cleared.")
        } else {
            print("History cleared with \(result.failedPaths.count) cleanup error(s).")
            for url in result.failedPaths {
                print("- \(displayPath(url))")
            }
            throw ExitCode.failure
        }
    }
}

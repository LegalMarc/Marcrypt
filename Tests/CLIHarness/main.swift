import AppKit
import CryptoKit
import Foundation
import PDFKit

@main
final class CLIHarness {
    private let fileManager = FileManager.default
    private let repoRoot: URL
    private let cliURL: URL
    private let root: URL
    private let home: URL
    private let tmp: URL
    private let fixtures: URL
    private let outputs: URL
    private let keepArtifacts: Bool
    private let commandTimeout: TimeInterval = 20

    private var successes: [String] = []
    private var failures: [String] = []
    private var skips: [String] = []

    init() {
        let args = CommandLine.arguments
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL
        repoRoot = cwd

        if let cliPath = ProcessInfo.processInfo.environment["MARCRYPT_CLI_PATH"] {
            cliURL = URL(fileURLWithPath: cliPath).standardizedFileURL
        } else {
            cliURL = cwd.appendingPathComponent(".build/debug/MarcryptCLI")
        }

        keepArtifacts = args.contains("--keep")
        if let index = args.firstIndex(of: "--workdir"), args.indices.contains(index + 1) {
            root = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
        } else {
            root = fileManager.temporaryDirectory
                .appendingPathComponent("marcrypt-cli-harness-\(UUID().uuidString)")
        }

        home = root.appendingPathComponent("home")
        tmp = root.appendingPathComponent("tmp")
        fixtures = root.appendingPathComponent("fixtures")
        outputs = root.appendingPathComponent("outputs")
    }

    static func main() {
        let harness = CLIHarness()
        harness.run()
    }

    func run() {
        do {
            try bootstrap()
            print("CLI harness workdir: \(root.path)")
            print("CLI executable: \(cliURL.path)")

            checkShellBehavior()
            checkEncryptCommand()
            checkDecryptCommand()
            checkWatermarkCommand()
            checkBatesCommand()
            checkPreflightCommand()
            checkClearHistoryCommand()
        } catch {
            recordFailure("harness bootstrap", error)
        }

        if keepArtifacts {
            print("Artifacts kept at: \(root.path)")
        } else {
            try? fileManager.removeItem(at: root)
        }

        print("")
        print("CLI harness summary: \(successes.count) passed, \(skips.count) skipped, \(failures.count) failed")
        for success in successes {
            print("PASS \(success)")
        }
        for skip in skips {
            print("SKIP \(skip)")
        }
        for failure in failures {
            print("FAIL \(failure)")
        }

        if !failures.isEmpty {
            Foundation.exit(1)
        }
    }

    private func bootstrap() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputs, withIntermediateDirectories: true)

        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw HarnessError.assertion("MarcryptCLI was not found at \(cliURL.path). Run `swift build --product MarcryptCLI` first or set MARCRYPT_CLI_PATH.")
        }
    }

    private func checkShellBehavior() {
        scenario("shell: top-level help") {
            let result = try runCLI(["--help"])
            try expectSuccess(result)
            try expectCombined(result, contains: "SUBCOMMANDS:")
        }

        for command in ["encrypt", "decrypt", "watermark", "bates", "preflight", "clear-history"] {
            scenario("shell: help \(command)") {
                let result = try runCLI(["help", command])
                try expectSuccess(result)
                try expectCombined(result, contains: "USAGE:")
            }
        }

        scenario("shell: unknown command fails") {
            let result = try runCLI(["does-not-exist"])
            try expectFailure(result)
            try expectCombined(result, contains: "Error:")
        }

        scenario("shell: missing required encrypt args fails") {
            let result = try runCLI(["encrypt"])
            try expectFailure(result)
            try expectCombined(result, contains: "Missing expected argument")
        }

        scenario("shell: unexpected flag fails") {
            let input = try writeText(fixture("unexpected-flag.txt"), "input")
            let result = try runCLI(["preflight", "--destination", outputs.path, input.path, "--bogus"])
            try expectFailure(result)
            try expectCombined(result, contains: "Unknown option")
        }

        scenario("shell: invalid integer argument fails") {
            let pdf = try createSamplePDF(named: "shell-invalid-int.pdf", pageCount: 1)
            let result = try runCLI(["bates", pdf.path, output("shell-invalid-int.pdf").path, "BATES-", "not-an-int"])
            try expectFailure(result)
            try expectCombined(result, contains: "is invalid")
        }

        scenario("shell: stdin password is not echoed") {
            let source = try createFolderFixture(named: "no-leak-source")
            let secret = "DoNotLeak Harness Password 123!"
            let result = try runCLI(["encrypt", source.path, output("no-leak.zip").path, "--password-stdin"], stdin: "\(secret)\n")
            try expectSuccess(result)
            try expectCombined(result, notContaining: secret)
        }
    }

    private func checkEncryptCommand() {
        scenario("encrypt: PDF via password stdin") {
            let source = try createSamplePDF(named: "encrypt-source.pdf", pageCount: 2)
            let destination = output("encrypt-source.encrypted.pdf")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectSuccess(result)
            try expectCombined(result, contains: "Successfully encrypted PDF")
            try require(fileManager.fileExists(atPath: destination.path), "encrypted PDF should exist")
            try require(try sha256(source) != sha256(destination), "encrypted PDF should differ from source")
            try requireEncryptedPDF(destination, password: password)
        }

        scenario("encrypt: DOCX via password stdin") {
            let source = try createSampleDOCX(named: "encrypt-source.docx", text: "DOCX encryption source")
            let destination = output("encrypt-source.encrypted.docx")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectSuccess(result)
            try expectCombined(result, contains: "Successfully encrypted DOCX")
            try requireOLEFile(destination)
            try require(try sha256(source) != sha256(destination), "encrypted DOCX should differ from source")
        }

        scenario("encrypt: folder to ZIP via password stdin") {
            let source = try createFolderFixture(named: "encrypt-folder-source")
            let destination = output("encrypt-folder.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectSuccess(result)
            try expectCombined(result, contains: "Successfully zipped folder")
            try require(fileManager.fileExists(atPath: destination.path), "encrypted ZIP should exist")
            try require(fileManager.fileExists(atPath: source.path), "source folder should remain without --remove-originals")
        }

        scenario("encrypt: piped interactive password fallback") {
            let source = try createFolderFixture(named: "interactive-folder")
            let destination = output("interactive-folder.zip")
            let result = try runCLI(["encrypt", source.path, destination.path], stdin: "\(password)\n")
            try expectSuccess(result)
            try expectCombined(result, contains: "Successfully zipped folder")
        }

        scenario("encrypt: empty password stdin fails") {
            let source = try createFolderFixture(named: "empty-password-source")
            let destination = output("empty-password.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Password was not provided")
            try require(!fileManager.fileExists(atPath: destination.path), "empty password should not create output")
        }

        scenario("encrypt: password with spaces unicode and length round-trips ZIP") {
            let source = try createFolderFixture(named: "complex password source")
            let destination = output("complex password.zip")
            let extracted = output("complex password extracted")
            let complexPassword = "space pass \u{1F512} \u{00E9} " + String(repeating: "x", count: 96)
            try expectSuccess(try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(complexPassword)\n"))
            try expectSuccess(try runCLI(["decrypt", destination.path, extracted.path, "--password-stdin"], stdin: "\(complexPassword)\n"))
            try require(try directoriesMatch(source, extracted), "complex-password ZIP should extract matching contents")
        }

        scenario("encrypt: missing input fails and creates no output") {
            let destination = output("missing-input.zip")
            let result = try runCLI(["encrypt", fixture("missing-input-folder").path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try require(!fileManager.fileExists(atPath: destination.path), "missing input should not create output")
        }

        scenario("encrypt: unsupported file-as-archive input fails") {
            let source = try writeText(fixture("not-a-folder.txt"), "not a folder")
            let destination = output("not-a-folder.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try require(!fileManager.fileExists(atPath: destination.path), "unsupported archive source should not create output")
        }

        scenario("encrypt: invalid output parent fails and preserves source") {
            let source = try createFolderFixture(named: "invalid-parent-source")
            let destination = output("missing-parent/invalid-parent.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try require(fileManager.fileExists(atPath: source.path), "source should survive failed encryption")
            try require(!fileManager.fileExists(atPath: destination.path), "invalid parent should not create output")
        }

        scenario("encrypt: paths with spaces and escaped unicode") {
            let source = try createFolderFixture(named: "space path \u{00E9} source")
            let destination = output("space path \u{00E9} archive.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(fileManager.fileExists(atPath: destination.path), "space/unicode path output should exist")
        }

        scenario("encrypt collision: existing output fails by default") {
            let source = try createFolderFixture(named: "collision-default-source")
            let destination = try writeText(output("collision-default.zip"), "existing")
            let original = try Data(contentsOf: destination)
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Output already exists")
            try require(try Data(contentsOf: destination) == original, "default collision should preserve existing output")
        }

        scenario("encrypt collision: --keep-both creates unique file") {
            let source = try createFolderFixture(named: "collision-keep-source")
            _ = try writeText(output("collision-keep.zip"), "existing")
            let unique = output("collision-keep 2.zip")
            let result = try runCLI(["encrypt", source.path, output("collision-keep.zip").path, "--password-stdin", "--keep-both"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(fileManager.fileExists(atPath: unique.path), "--keep-both should create a numbered output")
        }

        scenario("encrypt collision: --replace overwrites file") {
            let source = try createFolderFixture(named: "collision-replace-source")
            let destination = try writeText(output("collision-replace.zip"), "existing")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(try Data(contentsOf: destination) != Data("existing".utf8), "--replace should overwrite existing file")
        }

        scenario("encrypt collision: --replace preserves existing output on failure") {
            let source = try writeText(fixture("invalid-replace-source.pdf"), "not a pdf")
            let destination = try writeText(output("invalid-replace-destination.pdf"), "existing")
            let original = try Data(contentsOf: destination)
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try require(try Data(contentsOf: destination) == original, "failed --replace should preserve existing file")
        }

        scenario("encrypt collision: same source and output path is refused") {
            let source = try createSamplePDF(named: "same-path-source.pdf", pageCount: 1)
            let original = try Data(contentsOf: source)
            let result = try runCLI(["encrypt", source.path, source.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Input and output paths must be different")
            try require(try Data(contentsOf: source) == original, "same-path refusal should preserve input")
        }

        scenario("encrypt: archive output inside source folder is refused") {
            let source = try createFolderFixture(named: "nested-output-source")
            let destination = source.appendingPathComponent("nested-output.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Output path must not be inside the source folder")
            try require(!fileManager.fileExists(atPath: destination.path), "nested archive output should not be created")
        }

        scenario("encrypt collision: --keep-both and --replace conflict") {
            let source = try createFolderFixture(named: "collision-conflict-source")
            let result = try runCLI(["encrypt", source.path, output("collision-conflict.zip").path, "--password-stdin", "--keep-both", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Use either --keep-both or --replace")
        }

        scenario("encrypt collision: replace directory with file is refused") {
            let source = try createSamplePDF(named: "replace-dir-source.pdf", pageCount: 1)
            let destination = output("replace-dir.pdf")
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Refusing to replace directory")
        }

        scenario("encrypt: --remove-originals removes source only after success") {
            let source = try createFolderFixture(named: "remove-originals-source")
            let destination = output("remove-originals.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin", "--remove-originals"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(fileManager.fileExists(atPath: destination.path), "output should exist after --remove-originals")
            try require(!fileManager.fileExists(atPath: source.path), "source should be removed after successful --remove-originals")
        }

        scenario("encrypt: --remove-originals preserves source on failure") {
            let source = try createFolderFixture(named: "remove-originals-failure-source")
            let destination = output("missing-remove-parent/remove-originals.zip")
            let result = try runCLI(["encrypt", source.path, destination.path, "--password-stdin", "--remove-originals"], stdin: "\(password)\n")
            try expectFailure(result)
            try require(fileManager.fileExists(atPath: source.path), "source should survive failed --remove-originals encryption")
        }
    }

    private func checkDecryptCommand() {
        scenario("decrypt: ZIP correct password extracts matching tree") {
            let (source, archive) = try encryptedZipFixture(name: "decrypt-zip-ok")
            let destination = output("decrypt-zip-ok")
            let result = try runCLI(["decrypt", archive.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectSuccess(result)
            try expectCombined(result, contains: "Successfully unzipped archive")
            try require(try directoriesMatch(source, destination), "decrypted ZIP tree should match source")
        }

        scenario("decrypt: ZIP wrong password fails and leaves no destination") {
            let (_, archive) = try encryptedZipFixture(name: "decrypt-zip-wrong")
            let destination = output("decrypt-zip-wrong")
            let result = try runCLI(["decrypt", archive.path, destination.path, "--password-stdin"], stdin: "wrong-password\n")
            try expectFailure(result)
            try require(!fileManager.fileExists(atPath: destination.path), "wrong ZIP password should not leave destination")
        }

        scenario("decrypt: corrupt ZIP fails") {
            let archive = try writeText(fixture("corrupt.zip"), "not a zip")
            let result = try runCLI(["decrypt", archive.path, output("corrupt-zip-out").path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
        }

        scenario("decrypt: DOCX correct password round-trips bytes") {
            let (source, encrypted) = try encryptedDocxFixture(name: "decrypt-docx-ok")
            let destination = output("decrypt-docx-ok.docx")
            let result = try runCLI(["decrypt", encrypted.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectSuccess(result)
            try expectCombined(result, contains: "Successfully decrypted DOCX")
            try require(try Data(contentsOf: source) == Data(contentsOf: destination), "decrypted DOCX should match source bytes")
        }

        scenario("decrypt: DOCX wrong password fails and creates no output") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-docx-wrong")
            let destination = output("decrypt-docx-wrong.docx")
            let result = try runCLI(["decrypt", encrypted.path, destination.path, "--password-stdin"], stdin: "wrong-password\n")
            try expectFailure(result)
            try require(!fileManager.fileExists(atPath: destination.path), "wrong DOCX password should not create output")
        }

        scenario("decrypt: --replace preserves existing output after wrong DOCX password") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-docx-replace-wrong")
            let destination = try writeText(output("decrypt-docx-replace-wrong.docx"), "existing")
            let original = try Data(contentsOf: destination)
            let result = try runCLI(["decrypt", encrypted.path, destination.path, "--password-stdin", "--replace"], stdin: "wrong-password\n")
            try expectFailure(result)
            try require(try Data(contentsOf: destination) == original, "failed decrypt --replace should preserve existing output")
        }

        scenario("decrypt collision: same source and output path is refused") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-same-path")
            let original = try Data(contentsOf: encrypted)
            let result = try runCLI(["decrypt", encrypted.path, encrypted.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Input and output paths must be different")
            try require(try Data(contentsOf: encrypted) == original, "same-path refusal should preserve encrypted input")
        }

        scenario("decrypt: unencrypted DOCX is rejected") {
            let source = try createSampleDOCX(named: "unencrypted-docx.docx", text: "not encrypted")
            let result = try runCLI(["decrypt", source.path, output("unencrypted-docx.out.docx").path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
        }

        scenario("decrypt: PDF remains explicitly unsupported") {
            let source = try createSamplePDF(named: "unsupported-decrypt.pdf", pageCount: 1)
            let result = try runCLI(["decrypt", source.path, output("unsupported-decrypt.out.pdf").path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Decryption is not supported")
        }

        scenario("decrypt: unsupported extension fails") {
            let source = try writeText(fixture("unsupported-decrypt.txt"), "text")
            let result = try runCLI(["decrypt", source.path, output("unsupported-decrypt.out").path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Decryption is only supported")
        }

        scenario("decrypt collision: existing DOCX output fails by default") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-collision-default")
            let destination = try writeText(output("decrypt-collision-default.docx"), "existing")
            let result = try runCLI(["decrypt", encrypted.path, destination.path, "--password-stdin"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Output already exists")
        }

        scenario("decrypt collision: --keep-both creates unique DOCX output") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-collision-keep")
            _ = try writeText(output("decrypt-collision-keep.docx"), "existing")
            let unique = output("decrypt-collision-keep 2.docx")
            let result = try runCLI(["decrypt", encrypted.path, output("decrypt-collision-keep.docx").path, "--password-stdin", "--keep-both"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(fileManager.fileExists(atPath: unique.path), "--keep-both should create unique DOCX output")
        }

        scenario("decrypt collision: --replace overwrites DOCX file") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-collision-replace")
            let destination = try writeText(output("decrypt-collision-replace.docx"), "existing")
            let result = try runCLI(["decrypt", encrypted.path, destination.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(try Data(contentsOf: destination) != Data("existing".utf8), "--replace should overwrite existing DOCX output")
        }

        scenario("decrypt collision: ZIP --keep-both creates unique directory") {
            let (source, archive) = try encryptedZipFixture(name: "decrypt-zip-keep")
            let destination = output("decrypt-zip-keep-dir")
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let unique = output("decrypt-zip-keep-dir 2")
            let result = try runCLI(["decrypt", archive.path, destination.path, "--password-stdin", "--keep-both"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(try directoriesMatch(source, unique), "ZIP --keep-both should extract to unique directory")
        }

        scenario("decrypt collision: ZIP --replace allows empty directory") {
            let (source, archive) = try encryptedZipFixture(name: "decrypt-zip-replace-empty")
            let destination = output("decrypt-zip-replace-empty")
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let result = try runCLI(["decrypt", archive.path, destination.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectSuccess(result)
            try require(try directoriesMatch(source, destination), "ZIP --replace should extract into empty directory")
        }

        scenario("decrypt collision: ZIP --replace refuses non-empty directory") {
            let (_, archive) = try encryptedZipFixture(name: "decrypt-zip-replace-nonempty")
            let destination = output("decrypt-zip-replace-nonempty")
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            _ = try writeText(destination.appendingPathComponent("keep.txt"), "preserve")
            let result = try runCLI(["decrypt", archive.path, destination.path, "--password-stdin", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Refusing to replace non-empty directory")
            try require(fileManager.fileExists(atPath: destination.appendingPathComponent("keep.txt").path), "non-empty destination should be preserved")
        }

        scenario("decrypt collision: --keep-both and --replace conflict") {
            let (_, encrypted) = try encryptedDocxFixture(name: "decrypt-collision-conflict")
            let result = try runCLI(["decrypt", encrypted.path, output("decrypt-collision-conflict.docx").path, "--password-stdin", "--keep-both", "--replace"], stdin: "\(password)\n")
            try expectFailure(result)
            try expectCombined(result, contains: "Use either --keep-both or --replace")
        }
    }

    private func checkWatermarkCommand() {
        scenario("watermark: PDF default options create annotation") {
            let source = try createSamplePDF(named: "watermark-default.pdf", pageCount: 1)
            let destination = output("watermark-default.pdf")
            let result = try runCLI(["watermark", source.path, destination.path, "CONFIDENTIAL"])
            try expectSuccess(result)
            try requirePDFText(destination, contains: "CONFIDENTIAL")
        }

        scenario("watermark: DOCX default options create watermark header") {
            let source = try createSampleDOCX(named: "watermark-default.docx", text: "watermark docx")
            let destination = output("watermark-default.docx")
            let result = try runCLI(["watermark", source.path, destination.path, "PRIVILEGED"])
            try expectSuccess(result)
            try requireDocxXML(destination, contains: "PRIVILEGED")
        }

        scenario("watermark: valid PDF option boundaries") {
            let source = try createSamplePDF(named: "watermark-boundaries.pdf", pageCount: 1)
            let low = output("watermark-opacity-zero.pdf")
            let high = output("watermark-opacity-one.pdf")
            try expectSuccess(try runCLI(["watermark", source.path, low.path, "ZERO", "--size", "1", "--opacity", "0", "--location", "0", "--color", "00FF00"]))
            try expectSuccess(try runCLI(["watermark", source.path, high.path, "ONE", "--size", "96", "--opacity", "1", "--location", "9", "--color", "#0000FF"]))
            try requirePDFText(low, contains: "ZERO")
            try requirePDFText(high, contains: "ONE")
        }

        for (label, args) in [
            ("size zero", ["--size", "0"]),
            ("size negative", ["--size", "-1"]),
            ("opacity low", ["--opacity", "-0.1"]),
            ("opacity high", ["--opacity", "1.1"]),
            ("location low", ["--location", "-1"]),
            ("location high", ["--location", "10"]),
            ("bad color", ["--color", "XYZ"])
        ] {
            scenario("watermark failure: \(label)") {
                let source = try createSamplePDF(named: "watermark-failure-\(slug(label)).pdf", pageCount: 1)
                let result = try runCLI(["watermark", source.path, output("watermark-failure-\(slug(label)).pdf").path, "BAD"] + args)
                try expectFailure(result)
            }
        }

        scenario("watermark failure: unsupported extension") {
            let source = try writeText(fixture("watermark-unsupported.txt"), "text")
            let result = try runCLI(["watermark", source.path, output("watermark-unsupported.out").path, "BAD"])
            try expectFailure(result)
            try expectCombined(result, contains: "Watermarking is only supported")
        }

        scenario("watermark collision: existing output fails by default") {
            let source = try createSamplePDF(named: "watermark-collision.pdf", pageCount: 1)
            let destination = try writeText(output("watermark-collision.pdf"), "existing")
            let result = try runCLI(["watermark", source.path, destination.path, "COLLIDE"])
            try expectFailure(result)
            try expectCombined(result, contains: "Output already exists")
        }

        scenario("watermark collision: --keep-both and --replace conflict") {
            let source = try createSamplePDF(named: "watermark-conflict.pdf", pageCount: 1)
            let result = try runCLI(["watermark", source.path, output("watermark-conflict.pdf").path, "COLLIDE", "--keep-both", "--replace"])
            try expectFailure(result)
            try expectCombined(result, contains: "Use either --keep-both or --replace")
        }
    }

    private func checkBatesCommand() {
        scenario("bates: PDF default options create annotation") {
            let source = try createSamplePDF(named: "bates-default.pdf", pageCount: 2)
            let destination = output("bates-default.pdf")
            let result = try runCLI(["bates", source.path, destination.path, "MARC-", "7"])
            try expectSuccess(result)
            try requirePDFText(destination, contains: "MARC-000007")
            try requirePDFText(destination, contains: "MARC-000008")
        }

        scenario("bates: DOCX default options create header content") {
            let source = try createSampleDOCX(named: "bates-default.docx", text: "bates docx")
            let destination = output("bates-default.docx")
            let result = try runCLI(["bates", source.path, destination.path, "DOC-", "3"])
            try expectSuccess(result)
            try requireDocxXML(destination, contains: "DOC-")
            try requireDocxXML(destination, contains: "000003")
        }

        scenario("bates: valid options and timestamp") {
            let source = try createSamplePDF(named: "bates-options.pdf", pageCount: 1)
            let destination = output("bates-options.pdf")
            let result = try runCLI([
                "bates", source.path, destination.path, "OPT-", "12",
                "--digit-count", "3",
                "--location", "9",
                "--font-family", "0",
                "--font-size", "18",
                "--color", "112233",
                "--include-timestamp"
            ])
            try expectSuccess(result)
            try requirePDFText(destination, contains: "OPT-012")
        }

        for (label, args) in [
            ("start zero", ["P-", "0"]),
            ("start negative", ["P-", "-1"]),
            ("digit zero", ["P-", "1", "--digit-count", "0"]),
            ("digit negative", ["P-", "1", "--digit-count", "-1"]),
            ("location low", ["P-", "1", "--location", "-1"]),
            ("location high", ["P-", "1", "--location", "10"]),
            ("font family low", ["P-", "1", "--font-family", "-1"]),
            ("font family high", ["P-", "1", "--font-family", "3"]),
            ("font size zero", ["P-", "1", "--font-size", "0"]),
            ("bad color", ["P-", "1", "--color", "NOPE"])
        ] {
            scenario("bates failure: \(label)") {
                let source = try createSamplePDF(named: "bates-failure-\(slug(label)).pdf", pageCount: 1)
                let result = try runCLI(["bates", source.path, output("bates-failure-\(slug(label)).pdf").path] + args)
                try expectFailure(result)
            }
        }

        scenario("bates failure: unsupported extension") {
            let source = try writeText(fixture("bates-unsupported.txt"), "text")
            let result = try runCLI(["bates", source.path, output("bates-unsupported.out").path, "B-", "1"])
            try expectFailure(result)
            try expectCombined(result, contains: "Bates numbering is only supported")
        }

        scenario("bates collision: existing output fails by default") {
            let source = try createSamplePDF(named: "bates-collision.pdf", pageCount: 1)
            let destination = try writeText(output("bates-collision.pdf"), "existing")
            let result = try runCLI(["bates", source.path, destination.path, "B-", "1"])
            try expectFailure(result)
            try expectCombined(result, contains: "Output already exists")
        }

        scenario("bates collision: --keep-both and --replace conflict") {
            let source = try createSamplePDF(named: "bates-conflict.pdf", pageCount: 1)
            let result = try runCLI(["bates", source.path, output("bates-conflict.pdf").path, "B-", "1", "--keep-both", "--replace"])
            try expectFailure(result)
            try expectCombined(result, contains: "Use either --keep-both or --replace")
        }
    }

    private func checkPreflightCommand() {
        scenario("preflight: one file writable destination passes") {
            let source = try writeText(fixture("preflight-one.txt"), "preflight")
            let result = try runCLI(["preflight", "--destination", outputs.path, source.path])
            try expectSuccess(result)
            try expectCombined(result, contains: "Preflight passed")
            try expectCombined(result, contains: "Required space estimate:")
            try expectCombined(result, contains: "Available space:")
            try expectCombined(result, contains: "Destination writable: yes")
        }

        scenario("preflight: multiple files pass") {
            let first = try writeText(fixture("preflight-multi-1.txt"), "one")
            let second = try writeText(fixture("preflight-multi-2.txt"), "two")
            let result = try runCLI(["preflight", "--destination", outputs.path, first.path, second.path])
            try expectSuccess(result)
        }

        scenario("preflight: recursive folder sizing passes") {
            let folder = try createFolderFixture(named: "preflight-folder")
            let result = try runCLI(["preflight", "--destination", outputs.path, folder.path])
            try expectSuccess(result)
            try expectCombined(result, contains: "Required space estimate:")
        }

        scenario("preflight: missing input fails") {
            let result = try runCLI(["preflight", "--destination", outputs.path, fixture("preflight-missing.txt").path])
            try expectFailure(result)
            try expectCombined(result, contains: "Cannot read file")
        }

        scenario("preflight: no inputs validation fails") {
            let result = try runCLI(["preflight", "--destination", outputs.path])
            try expectFailure(result)
            try expectCombined(result, contains: "Missing expected argument")
        }

        scenario("preflight: missing destination option fails") {
            let source = try writeText(fixture("preflight-no-destination.txt"), "input")
            let result = try runCLI(["preflight", source.path])
            try expectFailure(result)
            try expectCombined(result, contains: "Missing expected argument")
        }

        scenario("preflight: unreadable input fails when filesystem permits") {
            let source = try writeText(fixture("preflight-unreadable.txt"), "secret")
            try chmod(source, mode: 0)
            defer { try? chmod(source, mode: 0o644) }
            guard !fileManager.isReadableFile(atPath: source.path) else {
                throw HarnessError.skip("filesystem still reports unreadable fixture as readable")
            }
            let result = try runCLI(["preflight", "--destination", outputs.path, source.path])
            try expectFailure(result)
            try expectCombined(result, contains: "Cannot read file")
        }

        scenario("preflight: unwritable destination fails when filesystem permits") {
            let source = try writeText(fixture("preflight-unwritable-input.txt"), "input")
            let destination = output("preflight-unwritable-destination")
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            try chmod(destination, mode: 0o555)
            defer { try? chmod(destination, mode: 0o755) }
            guard !fileManager.isWritableFile(atPath: destination.path) else {
                throw HarnessError.skip("filesystem still reports unwritable destination as writable")
            }
            let result = try runCLI(["preflight", "--destination", destination.path, source.path])
            try expectFailure(result)
            try expectCombined(result, contains: "No write permission")
        }
    }

    private func checkClearHistoryCommand() {
        scenario("clear-history: removes isolated app history and temp targets") {
            let appSupport = home.appendingPathComponent("Library/Application Support/Marcrypt")
            let tempTarget = tmp.appendingPathComponent("MarcryptTemp")
            try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: tempTarget, withIntermediateDirectories: true)
            _ = try writeText(appSupport.appendingPathComponent("marcrypt.log"), "log")
            _ = try writeText(appSupport.appendingPathComponent("audit.jsonl"), "audit")
            _ = try writeText(tempTarget.appendingPathComponent("temp.txt"), "temp")

            let result = try runCLI(["clear-history"])
            try expectSuccess(result)
            try expectCombined(result, contains: "History cleared")
            try require(!fileManager.fileExists(atPath: appSupport.appendingPathComponent("marcrypt.log").path), "log should be removed")
            try require(!fileManager.fileExists(atPath: appSupport.appendingPathComponent("audit.jsonl").path), "audit log should be removed")
            try require(!fileManager.fileExists(atPath: tempTarget.path), "MarcryptTemp should be removed")
        }

        scenario("clear-history: idempotent when history is already gone") {
            let result = try runCLI(["clear-history"])
            try expectSuccess(result)
            try expectCombined(result, contains: "History cleared")
        }

        scenario("clear-history: reports partial cleanup failures in isolated HOME") {
            let appSupport = home.appendingPathComponent("Library/Application Support/Marcrypt")
            try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let log = try writeText(appSupport.appendingPathComponent("marcrypt.log"), "locked")
            try chflags(log, flag: "uchg")
            defer { try? chflags(log, flag: "nouchg"); try? fileManager.removeItem(at: log) }

            let result = try runCLI(["clear-history"])
            try expectFailure(result)
            try expectCombined(result, contains: "cleanup error")
        }
    }

    private var password: String { "HarnessPass123!" }

    private func encryptedZipFixture(name: String) throws -> (source: URL, archive: URL) {
        let source = try createFolderFixture(named: "\(name)-source")
        let archive = output("\(name).zip")
        try expectSuccess(try runCLI(["encrypt", source.path, archive.path, "--password-stdin"], stdin: "\(password)\n"))
        return (source, archive)
    }

    private func encryptedDocxFixture(name: String) throws -> (source: URL, encrypted: URL) {
        let source = try createSampleDOCX(named: "\(name)-source.docx", text: "\(name) source")
        let encrypted = output("\(name).encrypted.docx")
        try expectSuccess(try runCLI(["encrypt", source.path, encrypted.path, "--password-stdin"], stdin: "\(password)\n"))
        return (source, encrypted)
    }

    private func runCLI(_ args: [String], stdin: String? = nil, timeout: TimeInterval? = nil) throws -> CommandResult {
        try runExecutable(cliURL, args: args, stdin: stdin, timeout: timeout ?? commandTimeout, cwd: repoRoot)
    }

    private func runExecutable(
        _ executable: URL,
        args: [String],
        stdin: String? = nil,
        timeout: TimeInterval,
        cwd: URL
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = cwd

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TMPDIR"] = tmp.path.hasSuffix("/") ? tmp.path : "\(tmp.path)/"
        environment["CFFIXED_USER_HOME"] = home.path
        environment["MARCRYPT_TEMP_ROOT"] = tmp.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let input = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input

        try process.run()

        if let stdin {
            let data = stdin.data(using: .utf8) ?? Data()
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 2)
            }
        }

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CommandResult(
            command: ([executable.lastPathComponent] + args).joined(separator: " "),
            exitCode: process.terminationStatus,
            stdout: stdoutText,
            stderr: stderrText,
            timedOut: timedOut
        )
    }

    private func createSamplePDF(named name: String, pageCount: Int) throws -> URL {
        let url = fixture(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw HarnessError.assertion("could not create sample PDF at \(url.path)")
        }

        for pageNumber in 1...pageCount {
            context.beginPage(mediaBox: &mediaBox)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            let text = "Marcrypt CLI harness PDF page \(pageNumber)" as NSString
            text.draw(
                at: CGPoint(x: 72, y: 680),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 24),
                    .foregroundColor: NSColor.black
                ]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPage()
        }
        context.closePDF()
        return url
    }

    private func createSampleDOCX(named name: String, text: String) throws -> URL {
        let packageRoot = fixtures.appendingPathComponent("docx-package-\(UUID().uuidString)")
        let word = packageRoot.appendingPathComponent("word")
        let wordRels = word.appendingPathComponent("_rels")
        let packageRels = packageRoot.appendingPathComponent("_rels")
        let props = packageRoot.appendingPathComponent("docProps")

        try fileManager.createDirectory(at: wordRels, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packageRels, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: props, withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """.write(to: packageRoot.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """.write(to: packageRels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """.write(to: wordRels.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            <w:p><w:r><w:t>\(escapeXML(text))</w:t></w:r></w:p>
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
        """.write(to: word.appendingPathComponent("settings.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                           xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>CLI Harness DOCX</dc:title>
          <dc:creator>Marcrypt CLI Harness</dc:creator>
          <cp:lastModifiedBy>Marcrypt CLI Harness</cp:lastModifiedBy>
          <cp:revision>1</cp:revision>
        </cp:coreProperties>
        """.write(to: props.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
                    xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>Marcrypt CLI Harness</Application>
          <Company>Harness</Company>
          <Pages>1</Pages>
        </Properties>
        """.write(to: props.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)

        let outputURL = fixture(name)
        try zipDirectory(packageRoot, to: outputURL)
        try? fileManager.removeItem(at: packageRoot)
        return outputURL
    }

    private func createFolderFixture(named name: String) throws -> URL {
        let directory = fixture(name)
        let nested = directory.appendingPathComponent("nested")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try writeText(directory.appendingPathComponent("alpha.txt"), "alpha\n")
        _ = try writeText(directory.appendingPathComponent("beta with spaces.txt"), "beta\n")
        _ = try writeText(nested.appendingPathComponent("gamma.txt"), "gamma\n")
        try Data([0, 1, 2, 3, 255]).write(to: nested.appendingPathComponent("binary.bin"))
        return directory
    }

    private func zipDirectory(_ directory: URL, to outputURL: URL) throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let result = try runSystem("/usr/bin/zip", args: ["-qr", outputURL.path, "."], cwd: directory)
        try expectSuccess(result)
    }

    private func unzipArchive(_ archive: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try runSystem("/usr/bin/unzip", args: ["-qq", archive.path, "-d", destination.path], cwd: repoRoot)
        try expectSuccess(result)
    }

    private func runSystem(_ executable: String, args: [String], cwd: URL) throws -> CommandResult {
        try runExecutable(URL(fileURLWithPath: executable), args: args, timeout: commandTimeout, cwd: cwd)
    }

    private func writeText(_ url: URL, _ text: String) throws -> URL {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name)
    }

    private func output(_ name: String) -> URL {
        outputs.appendingPathComponent(name)
    }

    private func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func requireEncryptedPDF(_ url: URL, password: String) throws {
        guard let document = PDFDocument(url: url) else {
            throw HarnessError.assertion("encrypted PDF should be readable as a PDF container")
        }
        try require(document.isLocked, "encrypted PDF should be locked")
        try require(!document.unlock(withPassword: "wrong-password"), "encrypted PDF should reject wrong password")
        try require(document.unlock(withPassword: password), "encrypted PDF should unlock with correct password")
    }

    private func requirePDFText(_ url: URL, contains expected: String) throws {
        guard let document = PDFDocument(url: url) else {
            throw HarnessError.assertion("PDF should be readable: \(url.path)")
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if (page.string ?? "").contains(expected) {
                return
            }
            if page.annotations.contains(where: { ($0.contents ?? "").contains(expected) }) {
                return
            }
        }
        throw HarnessError.assertion("PDF text or annotations should contain \(expected)")
    }

    private func requireOLEFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try require(Array(data.prefix(4)) == [0xD0, 0xCF, 0x11, 0xE0], "file should have OLE compound document magic")
    }

    private func requireDocxXML(_ docx: URL, contains expected: String) throws {
        let destination = outputs.appendingPathComponent("inspect-\(UUID().uuidString)")
        try unzipArchive(docx, to: destination)
        guard let enumerator = fileManager.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw HarnessError.assertion("could not inspect DOCX contents")
        }
        for case let url as URL in enumerator where url.pathExtension == "xml" || url.pathExtension == "rels" {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(expected) {
                return
            }
        }
        throw HarnessError.assertion("DOCX XML should contain \(expected)")
    }

    private func directoriesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsFiles = try relativeFiles(under: lhs)
        let rhsFiles = try relativeFiles(under: rhs)
        guard lhsFiles == rhsFiles else { return false }
        for file in lhsFiles {
            if try Data(contentsOf: lhs.appendingPathComponent(file)) != Data(contentsOf: rhs.appendingPathComponent(file)) {
                return false
            }
        }
        return true
    }

    private func relativeFiles(under root: URL) throws -> [String] {
        let normalizedRoot = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(normalizedRoot + "/") {
                files.append(String(path.dropFirst(normalizedRoot.count + 1)))
            }
        }
        return files.sorted()
    }

    private func chmod(_ url: URL, mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func chflags(_ url: URL, flag: String) throws {
        let result = try runSystem("/usr/bin/chflags", args: [flag, url.path], cwd: repoRoot)
        try expectSuccess(result)
    }

    private func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func slug(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "-")
    }

    private func scenario(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            recordSuccess(name)
        } catch HarnessError.skip(let message) {
            skips.append("\(name): \(message)")
        } catch {
            recordFailure(name, error)
        }
    }

    private func expectSuccess(_ result: CommandResult) throws {
        if result.timedOut {
            throw HarnessError.assertion("timed out: \(result.command)")
        }
        guard result.exitCode == 0 else {
            throw HarnessError.assertion("expected success for \(result.command), got exit \(result.exitCode)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        }
    }

    private func expectFailure(_ result: CommandResult) throws {
        if result.timedOut {
            throw HarnessError.assertion("timed out: \(result.command)")
        }
        guard result.exitCode != 0 else {
            throw HarnessError.assertion("expected failure for \(result.command), got success\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        }
    }

    private func expectCombined(_ result: CommandResult, contains expected: String) throws {
        guard result.combined.contains(expected) else {
            throw HarnessError.assertion("expected output to contain \(expected) for \(result.command)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        }
    }

    private func expectCombined(_ result: CommandResult, notContaining forbidden: String) throws {
        guard !result.combined.contains(forbidden) else {
            throw HarnessError.assertion("output leaked forbidden text for \(result.command)")
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw HarnessError.assertion(message)
        }
    }

    private func recordSuccess(_ message: String) {
        successes.append(message)
    }

    private func recordFailure(_ message: String, _ error: Error) {
        failures.append("\(message): \(error)")
    }
}

private struct CommandResult {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var combined: String {
        stdout + stderr
    }
}

private enum HarnessError: Error, CustomStringConvertible {
    case assertion(String)
    case skip(String)

    var description: String {
        switch self {
        case .assertion(let message), .skip(let message):
            return message
        }
    }
}

import SwiftUI
import PDFKit
import Combine
import Foundation
import MarcryptCore

// MARK: - Central View-Model
@MainActor
final class FileViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var hasEncrypted: Bool = false
    @Published var hasUnencrypted: Bool = false
    @Published var activeReport: ReportViewerItem? = nil

    // Session Management
    private let sessionID = UUID()
    public let sessionTempDirectory: URL // Made public let for easy access and thread-safety


    init() {
        // Initialize session temp directory path once (safe for access in deinit)
        self.sessionTempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Constants.FileSystem.tempDirectoryName)
            .appendingPathComponent(sessionID.uuidString)

        // Safe Cleanup: Create a unique session temp directory
        try? FileManager.default.createDirectory(at: sessionTempDirectory, withIntermediateDirectories: true, attributes: nil)

        // Note: Global cleanup is now delegated to OS or specific maintenance tasks, NOT every init.
    }

    deinit {
        // Best-effort cleanup of this session's temp files
        let sessionDir = sessionTempDirectory
        try? SecureDeletionService.shared.shredItem(at: sessionDir)
    }

    // Batch Progress
    @Published var batchInfo: BatchProgressInfo? {
        didSet {
            AppProcessingState.shared.isProcessing = batchInfo?.isProcessing == true
        }
    }

    // Unsupported Files Alert
    @Published var unsupportedFiles: [URL] = []
    @Published var showUnsupportedAlert = false

    // Collision Handling
    enum CollisionPolicy {
        case keepBoth // Default (append 1, 2)
        case replace // Overwrite
    }

    struct BatchProgressInfo {
        var processed: Int
        var total: Int
        var successCount: Int
        var failedCount: Int
        var isProcessing: Bool
        var currentFileName: String? = nil
        var currentFileProgress: Double? = nil
    }

    struct UserSelectedInput {
        let url: URL
        let bookmarkData: Data
    }

    /// Handle to the currently running batch task for cancellation support.
    private var currentBatchTask: Task<Void, Never>?
    private let statusCheckLimiter = AsyncLimiter(limit: 4)

    /// Cancel the currently running batch operation.
    func cancelCurrentOperation() {
        currentBatchTask?.cancel()
        currentBatchTask = nil
        batchInfo = nil
        resetProcessingFiles()
    }

    func registerCurrentBatchTask(_ task: Task<Void, Never>?) {
        currentBatchTask = task
    }

    private func beginInputAccess(for items: [FileItem]) -> [() -> Void] {
        items.compactMap { item in
            guard let bookmarkData = item.securityScopedBookmarkData,
                  let accessibleURL = try? FileItem.resolvedSecurityScopedURL(from: bookmarkData)
            else {
                return nil
            }
            guard accessibleURL.startAccessingSecurityScopedResource() else {
                return nil
            }
            return {
                accessibleURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    // add files, avoid duplicates, and start async status-check
    @discardableResult
    func add(urls: [URL], managedSourceRoot: URL? = nil) -> Int {
        add(urls: urls, managedSourceRoot: managedSourceRoot, createSecurityScopedBookmarks: false)
    }

    @discardableResult
    func addUserSelected(urls: [URL]) -> Int {
        add(urls: urls, managedSourceRoot: nil, createSecurityScopedBookmarks: true)
    }

    @discardableResult
    func addUserSelected(inputs: [UserSelectedInput]) -> Int {
        add(userSelectedInputs: inputs)
    }

    @discardableResult
    func addPromised(urls: [URL], managedSourceRoot: URL?) -> Int {
        add(urls: urls, managedSourceRoot: managedSourceRoot, createSecurityScopedBookmarks: false)
    }

    func reportDropAdmissionFailures(_ urls: [URL]) {
        unsupportedFiles = urls
        showUnsupportedAlert = true
    }

    @discardableResult
    private func add(urls: [URL], managedSourceRoot: URL?, createSecurityScopedBookmarks: Bool) -> Int {
        let inputs = urls.map { url in
            (url: url, bookmarkData: Optional<Data>.none)
        }
        return add(inputs: inputs, managedSourceRoot: managedSourceRoot, createSecurityScopedBookmarks: createSecurityScopedBookmarks)
    }

    @discardableResult
    private func add(userSelectedInputs: [UserSelectedInput]) -> Int {
        let inputs = userSelectedInputs.map { input in
            (url: input.url, bookmarkData: Optional(input.bookmarkData))
        }
        return add(inputs: inputs, managedSourceRoot: nil, createSecurityScopedBookmarks: false)
    }

    @discardableResult
    private func add(inputs: [(url: URL, bookmarkData: Data?)], managedSourceRoot: URL?, createSecurityScopedBookmarks: Bool) -> Int {
        var newItems: [FileItem] = []
        var detectedUnsupported: [URL] = []

        // Optimization: Pre-calculate existing URLs for O(1) lookup
        let existingURLs = Set(items.map { $0.url })
        var newURLSet = Set<URL>()

        for input in inputs {
            let url = input.url
            // Early validation
            let ext = url.pathExtension.lowercased()
            let bookmarkData: Data?
            if let existingBookmark = input.bookmarkData {
                bookmarkData = existingBookmark
            } else if createSecurityScopedBookmarks {
                do {
                    bookmarkData = try FileItem.makeSecurityScopedBookmark(for: url)
                } catch {
                    detectedUnsupported.append(url)
                    continue
                }
            } else {
                bookmarkData = nil
            }

            let isDir = (try? FileItem.withSecurityScopedAccess(url: url, bookmarkData: bookmarkData) { accessibleURL in
                try accessibleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            }) ?? false

            // Check support
            if isDir || ["pdf", "zip", "docx"].contains(ext) {
                // Supported - Check duplicates efficiently
                if !existingURLs.contains(url) && !newURLSet.contains(url) {
                     let item = FileItem(url: url, securityScopedBookmarkData: bookmarkData, managedSourceRoot: managedSourceRoot)
                     newItems.append(item)
                     newURLSet.insert(url)
                }
            } else {
                // Unsupported
                detectedUnsupported.append(url)
            }
        }

        // Add supported immediately
        for item in newItems {
            items.append(item)
            // Track status check task for zombie prevention
            item.statusCheckTask = Task { await checkStatus(for: item) }
        }

        // Handle unsupported
        if !detectedUnsupported.isEmpty {
            self.unsupportedFiles = detectedUnsupported
            self.showUnsupportedAlert = true
        }

        updateButtonStates()
        return newItems.count
    }

    // Handle user choice for unsupported
    func handleUnsupported(zipAll: Bool) {
        // Helper to add unsupported files to list
        func addUnsupportedAsCorrupted() {
             for url in unsupportedFiles {
                 if !items.contains(where: { $0.url == url }) {
                     let item = FileItem(url: url)
                     item.status = .corrupted
                     item.errorMessage = "Unsupported file type"
                     items.append(item)
                 }
             }
        }

        if zipAll {
            // Add the unsupported files to the list. When the user triggers Encrypt,
            // these items will be handled by the folder/ZIP path in encryptAll.
            // checkStatus may mark them as .corrupted if the type is not recognized,
            // but they remain in the list for the user to act on.
            for url in unsupportedFiles {
                if !items.contains(where: { $0.url == url }) {
                    let item = FileItem(url: url)
                    items.append(item)
                }
            }
        } else {
            // If user declined Zip All, still show them but as corrupted/unsupported
            addUnsupportedAsCorrupted()
        }

        // Clear alert state
        unsupportedFiles.removeAll()
        showUnsupportedAlert = false
        updateButtonStates() // re-calc
    }

    func checkForCollisions(at destination: URL) async -> [String] {
        // Capture necessary data on MainActor
        let checkItems = items.filter { $0.status == .notEncrypted || $0.status == .encryptionFailed }.map { ($0.url, $0.type) }

        return await Task.detached(priority: .userInitiated) {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }

            var collisions: [String] = []

             for (url, _) in checkItems {
                 let name = url.lastPathComponent
                 // Collision check uses the input filename as the candidate output name.
                 // For ZIP output the name stays the same; _DECRYPTED suffixes are added
                 // later in saveDecryptedFiles, so this is a conservative pre-check.
                 let potentialURL = destination.appendingPathComponent(name)
                 if FileManager.default.fileExists(atPath: potentialURL.path) {
                     collisions.append(name)
                 } else {
                     // Check for potential split parts collision
                     let base = name.replacingOccurrences(of: ".\(url.pathExtension)", with: "")
                     let ext = url.pathExtension
                     let part1 = destination.appendingPathComponent("\(base)_Part1.\(ext)")
                     if FileManager.default.fileExists(atPath: part1.path) {
                         collisions.append(name + " (Split Parts)")
                     }
                 }
             }
             return collisions
        }.value
    }

    // async check: encrypted / notEncrypted / corrupted
    private func checkStatus(for item: FileItem) async {
        let url = item.url
        let type = item.type
        let bookmarkData = item.securityScopedBookmarkData

        guard await statusCheckLimiter.acquire() else {
            return
        }

        // Perform the check on a background thread using Task.detached
        let task = Task.detached(priority: .userInitiated) { () -> (ProcessingStatus, String?) in
            if Task.isCancelled { return (.checking, "Cancelled") }

            do {
                return try FileItem.withSecurityScopedAccess(url: url, bookmarkData: bookmarkData) { accessibleURL in
                    if !FileManager.default.isReadableFile(atPath: accessibleURL.path) {
                         return (.corrupted, "Cannot access file - may be corrupted or permission denied. Re-add it to grant access.")
                    }

                    switch type {
                    case .folder:
                        return (.notEncrypted, nil) // Folders are always "source" content

                    case .pdf:
                        guard let pdf = PDFDocument(url: accessibleURL) else {
                            return (.corrupted, "File could not be read - may be corrupted or not a valid PDF.")
                        }

                        if pdf.isEncrypted {
                            // Refinement: Try unlocking with empty password.
                            // Some PDFs are "protected" for editing but open for reading.
                            if pdf.unlock(withPassword: "") {
                                return (.notEncrypted, nil)
                            }
                            return (.encrypted, nil)
                        }
                        return (.notEncrypted, nil)

                    case .zip:
                        // Check local file header general purpose bit flag (bit 0 = encrypted)
                        if let data = try? Data(contentsOf: accessibleURL, options: .mappedIfSafe),
                           data.count >= 8 {
                            let flags = data.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) }
                            return (flags & 0x0001 != 0) ? (.encrypted, nil) : (.notEncrypted, nil)
                        }
                        return (.notEncrypted, nil)

                    case .docx:
                        // Check for OLE EncryptionInfo stream (MS-OFFCRYPTO encrypted DOCX)
                        if DocxEncryptionService.isDocxEncrypted(at: accessibleURL) {
                            return (.encrypted, nil)
                        }
                        return (.notEncrypted, nil)

                    default:
                        return (.corrupted, "Unsupported file type.")
                    }
                }
            } catch {
                return (.corrupted, "Cannot access file. Re-add it to grant access.")
            }
        }

        // Bridge cancellation from current Task to detained task
        let (status, errorMessage) = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await statusCheckLimiter.release()

        // Update on main actor
        update(item, status, errorMessage)
    }

    // helper: mutate on main-thread
    private func update(_ item: FileItem, _ status: ProcessingStatus, _ msg: String?, outputURL: URL? = nil) {
        // Clear decrypted document and shredded temporary files if status is changing away from .decrypted
        if item.status == .decrypted && status != .decrypted {
            item.decryptedDocument = nil
            if let tempURL = item.temporaryDecryptedURL {
                try? SecureDeletionService.shared.shredItem(at: tempURL)
                item.temporaryDecryptedURL = nil
            }
        }

        item.status       = status
        item.errorMessage = msg
        if let out = outputURL {
            item.outputURL = out
        }
        updateButtonStates()
    }

    // decrypt all encrypted items - first decrypt in memory, then save if any succeeded
    func decryptAll(with password: String, completion: @escaping (Bool, Bool) -> Void) {
        let task = Task { @MainActor in
            // Get items that are encrypted OR previously failed (for retry)
            let decryptableItems = self.items.filter { $0.status == .encrypted || $0.status == .decryptionFailed }

            guard !decryptableItems.isEmpty else {
                completion(false, false)
                return
            }

            self.batchInfo = BatchProgressInfo(processed: 0, total: decryptableItems.count, successCount: 0, failedCount: 0, isProcessing: true)

            // Process each item and collect results
            var results: [(success: Bool, item: FileItem)] = []

            // Use TaskGroup usually, but simple iteration is fine here because we want to update UI progressively
            for (index, item) in decryptableItems.enumerated() {
                if Task.isCancelled {
                    self.batchInfo = nil
                    completion(false, false)
                    return
                }
                self.batchInfo?.currentFileName = item.url.lastPathComponent
                let result = await self.processDecryption(for: item, password: password)
                results.append(result)
                self.batchInfo?.processed = index + 1
                if result.success {
                    self.batchInfo?.successCount += 1
                } else {
                    self.batchInfo?.failedCount += 1
                }
            }

            // Analyze results
            let successCount = results.filter { $0.success }.count
            let totalDecryptable = decryptableItems.count

            self.batchInfo?.isProcessing = false
            self.currentBatchTask = nil
            completion(successCount > 0, totalDecryptable > 0 && successCount == 0)
        }
        currentBatchTask = task
    }

    // Process single item decryption
    private func processDecryption(for item: FileItem, password: String) async -> (success: Bool, item: FileItem) {
        let url = item.url
        let type = item.type
        let bookmarkData = item.securityScopedBookmarkData
        let sessionTempDir = self.sessionTempDirectory
        let progressHandler = makeProgressHandler(for: item)

        // Perform the heavy work on a background thread
        let result = await Task.detached(priority: .userInitiated) { [progressHandler] () -> (Bool, PDFDocument?, URL?, String?) in

            // Handle specific file types
            switch type {
            case .pdf:
                do {
                    return try FileItem.withSecurityScopedAccess(url: url, bookmarkData: bookmarkData) { accessibleURL in
                        guard let doc = PDFDocument(url: accessibleURL) else {
                            return (false, nil, nil, "Corrupted PDF.")
                        }
                        if !doc.isEncrypted || doc.unlock(withPassword: "") {
                            return (true, doc, nil, nil)
                        }
                        guard doc.unlock(withPassword: password) else {
                            return (false, nil, nil, "Wrong password.")
                        }
                        return (true, doc, nil, nil)
                    }
                } catch {
                    return (false, nil, nil, "Cannot access file. Re-add it to grant access.")
                }

            case .zip:
                // Decrypt Zip to Temporary Directory
                let tempDir = sessionTempDir.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    try await FileItem.withSecurityScopedAccess(url: url, bookmarkData: bookmarkData) { accessibleURL in
                        try await ArchiveService.shared.unzip(archiveAt: accessibleURL, to: tempDir, password: password, progress: progressHandler)
                    }
                    return (true, nil, tempDir, nil)
                } catch {
                    // Clean up leaked temp directory on failure
                    try? SecureDeletionService.shared.shredItem(at: tempDir)
                    return (false, nil, nil, "Wrong password, corrupted archive, or missing file access.")
                }

            case .docx:
                do {
                    let decryptedData = try await FileItem.withSecurityScopedAccess(url: url, bookmarkData: bookmarkData) { accessibleURL in
                        try await DocxEncryptionService.shared.decrypt(docxFile: accessibleURL, password: password, progress: progressHandler)
                    }

                    // For Docx, since it's a single file (zipped package), returning it as Data or saving to Temp is best.
                    // Let's save it to a temporary .docx file.
                    // Use the managed temp directory for auto-cleanup on restart
                    try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
                    let tempDocx = sessionTempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("docx")
                    try decryptedData.write(to: tempDocx)
                    return (true, nil, tempDocx, nil)
                } catch {
                    return (false, nil, nil, error.localizedDescription)
                }

            default:
                return (false, nil, nil, "Unsupported type.")
            }
        }.value

        // Update UI on main actor
        if result.0 {
            item.decryptedDocument = result.1
            item.temporaryDecryptedURL = result.2
            self.update(item, .decrypted, nil)
            return (true, item)
        } else {
            self.update(item, .decryptionFailed, result.3 ?? "Unknown error")
            return (false, item)
        }
    }

    // Save successfully decrypted files to destination
    func saveDecryptedFiles(to destination: URL, policy: CollisionPolicy = .keepBoth) {
        let task = Task { @MainActor in
            // Try to access destination
            let hasAccess = destination.startAccessingSecurityScopedResource()
            defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }

            let decryptedItems = self.items.filter { $0.status == .decrypted }
            self.batchInfo = BatchProgressInfo(processed: 0, total: decryptedItems.count, successCount: 0, failedCount: 0, isProcessing: true)

            for (index, item) in decryptedItems.enumerated() {
                if Task.isCancelled {
                    self.batchInfo = nil
                    return
                }
                self.batchInfo?.currentFileName = item.url.lastPathComponent
                let outName: String

                // Adjust output name if extracting a folder (Zip)
                if item.type == .zip {
                   let base = item.url.deletingPathExtension().lastPathComponent
                   outName = "\(base)_DECRYPTED"
                } else {
                   let base = item.url.deletingPathExtension().lastPathComponent
                   let ext = item.url.pathExtension
                   outName = "\(base)_DECRYPTED.\(ext)"
                }

                let outURL: URL
                if policy == .replace {
                    outURL = destination.appendingPathComponent(outName)
                } else {
                    outURL = generateUniqueURL(for: outName, in: destination)
                }

                // Handle different types
                if let doc = item.decryptedDocument {
                    // PDF Write
	                    if !doc.write(to: outURL) {
	                        self.update(item, .decryptionFailed, "Failed to save file.")
                            self.batchInfo?.failedCount += 1
	                    } else {
	                        item.decryptedDocument = nil // Cleanup
	                        item.outputURL = outURL
                            self.batchInfo?.successCount += 1
	                    }
	                } else if let tempURL = item.temporaryDecryptedURL {
	                     // Move temp folder/file to destination
	                     do {
	                         try FileManager.default.moveItem(at: tempURL, to: outURL)
	                         item.temporaryDecryptedURL = nil // Cleanup
	                         item.outputURL = outURL
                             self.batchInfo?.successCount += 1
	                     } catch {
	                         self.update(item, .decryptionFailed, "Failed to save extracted files.")
                             self.batchInfo?.failedCount += 1
	                     }
                }
                self.batchInfo?.processed = index + 1
            }
            self.batchInfo?.isProcessing = false
            self.currentBatchTask = nil
        }
        currentBatchTask = task
    }

    // Updated completion signature to return detailed report
    func encryptAll(with password: String, to destination: URL, policy: CollisionPolicy, completion: @escaping (Bool, [String], Int, Int) -> Void) async {
        // Filter for files that can be encrypted
        let encryptableItems = self.items.filter { $0.status == .notEncrypted || $0.status == .encryptionFailed }

        guard !encryptableItems.isEmpty else {
            completion(false, [], 0, 0)
            return
        }

        // Pre-flight validation: check disk space & permissions
        let inputAccessStops = beginInputAccess(for: encryptableItems)
        defer { inputAccessStops.forEach { $0() } }
        let preFlight = await PreFlightValidator.validate(fileURLs: encryptableItems.map(\.url), destination: destination)

        guard preFlight.isOK else {
            let issues = preFlight.issues.joined(separator: "\n")
            AppLogger.warning("Pre-flight issues: \(issues)", logger: AppLogger.general)
            completion(false, preFlight.issues, 0, encryptableItems.count)
            return
        }

        // Init Progress
        await MainActor.run {
            self.batchInfo = BatchProgressInfo(processed: 0, total: encryptableItems.count, successCount: 0, failedCount: 0, isProcessing: true)
        }

        // Set all files to processing state
        for item in encryptableItems {
            self.update(item, .processing, nil)
        }

        // Check Settings ONCE
        let defaults = UserDefaults.standard
        let shouldShred = defaults.bool(forKey: "SecureShredOriginals")
        // Watermark Config
        let watermarkEnabled = defaults.bool(forKey: "WatermarkEnabled")
        let batesEnabled = defaults.bool(forKey: "BatesEnabled")

        var watermarkConfig: PdfProcessingService.WatermarkConfig? = nil
        if watermarkEnabled || batesEnabled {
            let watermarkText = watermarkEnabled ? (defaults.string(forKey: "WatermarkText") ?? "CONFIDENTIAL") : ""
            if !watermarkText.isEmpty || batesEnabled {
                watermarkConfig = PdfProcessingService.WatermarkConfig(
                    text: watermarkText,
                    size: defaults.integer(forKey: "WatermarkSize") > 0 ? defaults.integer(forKey: "WatermarkSize") : 48,
                    opacity: watermarkEnabled ? (defaults.double(forKey: "WatermarkOpacity") > 0 ? defaults.double(forKey: "WatermarkOpacity") : 0.25) : 0.0,
                    location: defaults.integer(forKey: "WatermarkLocation"),
                    colorHex: defaults.string(forKey: "WatermarkColorHex") ?? "#FF0000",
                    batesEnabled: batesEnabled,
                    batesPrefix: defaults.string(forKey: "BatesPrefix") ?? "",
                    batesStartNumber: defaults.integer(forKey: "BatesStartNumber") > 0 ? defaults.integer(forKey: "BatesStartNumber") : 1,
                    batesDigitCount: defaults.integer(forKey: "BatesDigitCount") > 0 ? defaults.integer(forKey: "BatesDigitCount") : 6,
                    batesLocation: defaults.integer(forKey: "BatesLocation") > 0 ? defaults.integer(forKey: "BatesLocation") : 2,
                    batesFontFamily: defaults.integer(forKey: "BatesFontFamily"),
                    batesFontSize: defaults.integer(forKey: "BatesFontSize") > 0 ? defaults.integer(forKey: "BatesFontSize") : 10,
                    batesColorHex: defaults.string(forKey: "BatesColorHex") ?? "#000000",
                    batesIncludeTimestamp: defaults.bool(forKey: "BatesIncludeTimestamp")
                )
            }
        }

        // Docx Settings
        let restrictionModeInt = defaults.integer(forKey: "DocxRestrictionMode")
        let restrictionType: DocxService.RestrictionType = {
            switch restrictionModeInt {
            case 1: return .readOnly
            case 2: return .comments
            case 3: return .trackedChanges
            case 4: return .forms
            default: return .none
            }
        }()

        let config = EncryptionConfig(
            watermarkConfig: watermarkConfig,
            autoSplitEnabled: defaults.bool(forKey: "AutoSplitEnabled"),
            autoSplitLimit: defaults.integer(forKey: "AutoSplitSizeMB"),
            shouldShred: shouldShred,
            restrictionType: restrictionType,
            markAsFinal: defaults.bool(forKey: "DocxMarkFinal"),
            modifyPassword: "",
            encryptStructure: defaults.bool(forKey: "DocxEncryptStructure")
        )

        // Start security access for the destination directory
        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        let reportsEnabled = UserDefaults.standard.bool(forKey: "GenerateBatchReports")
        let hashCache = BatchReportService.HashCache()
        let jobs = await makeBatchEncryptionJobs(
            for: encryptableItems,
            destination: destination,
            policy: policy,
            watermarkConfig: watermarkConfig
        )
        let concurrencyLimit = config.autoSplitEnabled ? 1 : boundedBatchConcurrency(for: jobs.count)

        var results: [BatchEncryptionResult] = []
        results.reserveCapacity(jobs.count)

        var nextJobIndex = 0
        var currentSuccess = 0
        var currentFailed = 0

        // Concurrency note: `concurrencyLimit` child tasks are kept in-flight at a
        // time. Each child calls `processBatchEncryptionJob`, which is an implicit
        // `@MainActor` method (because `FileViewModel` is `@MainActor`). The group
        // tasks therefore run on the main actor and interleave at each `await` rather
        // than executing truly in parallel. Real parallelism occurs in the
        // `Task.detached(priority: .userInitiated)` inside `processEncryption` — that
        // detached task runs off the main actor and performs the actual CPU/I/O work.
        //
        // Effect: up to `concurrencyLimit` detached encryption tasks can be active
        // simultaneously (each launched as soon as its parent group task reaches the
        // `await task.value` suspension point in `processEncryption`). The limit
        // therefore does govern real I/O overlap, but the per-file setup work
        // (hash pre-computation, progress UI updates) is serialised on the main actor.
        //
        // To achieve fully parallel setup as well, `processBatchEncryptionJob` and
        // `processEncryption` would need to become `nonisolated`, with every
        // `@MainActor` state mutation wrapped in `await MainActor.run { }`. This
        // requires `FileItem`'s `@Published` properties to be safe to read off the
        // main actor (e.g. making `FileItem` `@MainActor` or an actor). That is a
        // larger refactor deferred to a future release.
        await withTaskGroup(of: BatchEncryptionResult.self) { group in
            func submitNextJob() {
                guard nextJobIndex < jobs.count else { return }
                let job = jobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    await self.processBatchEncryptionJob(
                        job,
                        password: password,
                        destination: destination,
                        policy: policy,
                        config: config,
                        reportsEnabled: reportsEnabled,
                        hashCache: hashCache
                    )
                }
            }

            for _ in 0..<concurrencyLimit {
                submitNextJob()
            }

            while let result = await group.next() {
                results.append(result)

                if result.success {
                    currentSuccess += 1
                    if shouldShred, let idx = self.items.firstIndex(where: { $0.id == result.item.id }) {
                        self.items.remove(at: idx)
                    }
                } else {
                    currentFailed += 1
                }

                self.batchInfo?.processed = results.count
                self.batchInfo?.successCount = currentSuccess
                self.batchInfo?.failedCount = currentFailed
                self.batchInfo?.currentFileProgress = nil

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                submitNextJob()
            }
        }

        if Task.isCancelled {
            let completedIDs = Set(results.map(\.item.id))
            for remainingItem in encryptableItems where !completedIDs.contains(remainingItem.id) {
                self.update(remainingItem, .notEncrypted, nil)
            }
            await MainActor.run { self.batchInfo = nil }
            completion(false, ["Operation cancelled"], 0, 0)
            return
        }

        let orderedResults = results.sorted { $0.index < $1.index }
        let fileReports = orderedResults.map(\.fileReport)

        // Generate batch report only when explicitly enabled; reports can disclose
        // file inventories and fingerprints.
        if reportsEnabled,
           let reportURL = BatchReportService.shared.generateReport(
            title: "Encryption Report",
            batchOperation: "Encryption",
            files: fileReports,
            outputDirectory: destination
        ) {
            await MainActor.run {
                for item in encryptableItems {
                    item.reportURL = reportURL
                }
            }
        }

        let successCount = orderedResults.filter { $0.success }.count
        // Include failure reason with filename for better error messages
        let failedFiles = orderedResults.filter { !$0.success }.map { result -> String in
            if let reason = result.failureReason {
                return "\(result.item.url.lastPathComponent): \(reason)"
            }
            return result.item.url.lastPathComponent
        }
        let totalProcessed = orderedResults.count

        await MainActor.run { self.batchInfo?.isProcessing = false }

        if successCount > 0 {
            await MainActor.run {
                _ = NSSound(named: "Glass")?.play()
            }
        }

        completion(successCount > 0, failedFiles, successCount, totalProcessed)
    }

    // Configuration struct to pass settings once
    struct EncryptionConfig {
        let watermarkConfig: PdfProcessingService.WatermarkConfig?
        let autoSplitEnabled: Bool
        let autoSplitLimit: Int
        let shouldShred: Bool
        let restrictionType: DocxService.RestrictionType
        let markAsFinal: Bool
        let modifyPassword: String
        let encryptStructure: Bool
    }

    private struct BatchEncryptionJob {
        let index: Int
        let item: FileItem
        let batesStart: Int
        let batesUnitCount: Int
        let reservedOutputURL: URL
    }

    private struct BatchEncryptionResult {
        let index: Int
        let success: Bool
        let item: FileItem
        let failureReason: String?
        let fileReport: BatchReportService.FileReport
    }

    private func boundedBatchConcurrency(for itemCount: Int) -> Int {
        guard itemCount > 1 else { return 1 }
        let configured = UserDefaults.standard.integer(forKey: "BatchConcurrencyLimit")
        let defaultLimit = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
        let limit = configured > 0 ? configured : defaultLimit
        return max(1, min(itemCount, min(limit, 8)))
    }

    private func makeProgressHandler(for item: FileItem) -> OperationProgressHandler {
        let itemName = item.url.lastPathComponent
        return { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                guard self.batchInfo?.isProcessing == true else { return }
                self.batchInfo?.currentFileName = progress.message ?? itemName
                self.batchInfo?.currentFileProgress = progress.fractionCompleted
            }
        }
    }

    private func cachedSHA256(of item: FileItem, using hashCache: BatchReportService.HashCache) async -> String {
        do {
            return try await FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleURL in
                await hashCache.sha256(of: accessibleURL)
            }
        } catch {
            return "Unavailable"
        }
    }

    private func cachedMD5(of item: FileItem, using hashCache: BatchReportService.HashCache) async -> String {
        do {
            return try await FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleURL in
                await hashCache.md5(of: accessibleURL)
            }
        } catch {
            return "Unavailable"
        }
    }

    private func cachedFileSize(of item: FileItem, using hashCache: BatchReportService.HashCache) async -> Int64 {
        do {
            return try await FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleURL in
                await hashCache.fileSize(of: accessibleURL)
            }
        } catch {
            return 0
        }
    }

    private func batesUnitCount(for item: FileItem, watermarkConfig: PdfProcessingService.WatermarkConfig?) async -> Int {
        guard watermarkConfig?.batesEnabled == true else { return 0 }

        switch item.type {
        case .pdf:
            let url = item.url
            let bookmarkData = item.securityScopedBookmarkData
            return await Task.detached(priority: .utility) {
                (try? FileItem.withSecurityScopedAccess(url: url, bookmarkData: bookmarkData) { accessibleURL in
                    PDFDocument(url: accessibleURL)?.pageCount ?? 0
                }) ?? 0
            }.value
        case .docx:
            do {
                return try await FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleURL in
                    await DocxService.shared.estimatedPageCount(inDocxAt: accessibleURL) ?? 1
                }
            } catch {
                return 1
            }
        default:
            return 0
        }
    }

    private func makeBatchEncryptionJobs(
        for items: [FileItem],
        destination: URL,
        policy: CollisionPolicy,
        watermarkConfig: PdfProcessingService.WatermarkConfig?
    ) async -> [BatchEncryptionJob] {
        var nextBatesStart = watermarkConfig?.batesStartNumber ?? 1
        var reservedPaths = Set<String>()
        var jobs: [BatchEncryptionJob] = []
        jobs.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let outName = item.type == .folder ? item.url.lastPathComponent + ".zip" : item.url.lastPathComponent
            let outputURL = reserveBatchOutputURL(
                for: outName,
                in: destination,
                policy: policy,
                reservedPaths: &reservedPaths
            )
            let start = nextBatesStart
            let batesUnits = await batesUnitCount(for: item, watermarkConfig: watermarkConfig)
            if batesUnits > 0 {
                nextBatesStart += batesUnits
            }
            jobs.append(BatchEncryptionJob(
                index: index,
                item: item,
                batesStart: start,
                batesUnitCount: batesUnits,
                reservedOutputURL: outputURL
            ))
        }

        return jobs
    }

    private nonisolated func reserveBatchOutputURL(
        for filename: String,
        in directory: URL,
        policy: CollisionPolicy,
        reservedPaths: inout Set<String>
    ) -> URL {
        let baseURL = directory.appendingPathComponent(filename)
        let nameWithoutExtension = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension

        func candidateURL(counter: Int?) -> URL {
            guard let counter else { return baseURL }
            if fileExtension.isEmpty {
                return directory.appendingPathComponent("\(nameWithoutExtension) (\(counter))")
            }
            return directory.appendingPathComponent("\(nameWithoutExtension) (\(counter)).\(fileExtension)")
        }

        var counter: Int? = nil
        while true {
            let candidate = candidateURL(counter: counter)
            let path = candidate.standardizedFileURL.path
            let exists = FileManager.default.fileExists(atPath: path)
            if !reservedPaths.contains(path), policy == .replace || !exists {
                reservedPaths.insert(path)
                return candidate
            }

            counter = (counter ?? 0) + 1
            if counter ?? 0 > 2000 {
                let fallbackName = fileExtension.isEmpty
                    ? "\(nameWithoutExtension)_\(Int(Date().timeIntervalSince1970))"
                    : "\(nameWithoutExtension)_\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
                let fallback = directory.appendingPathComponent(fallbackName)
                reservedPaths.insert(fallback.standardizedFileURL.path)
                return fallback
            }
        }
    }

    // Executes one job in the batch encryption pipeline. Runs on the main actor
    // (implicitly, because `FileViewModel` is `@MainActor`). Per-file setup work
    // (hash pre-computation, progress state updates) occurs here on the main actor;
    // the CPU/I/O-intensive encryption is delegated to a `Task.detached` inside
    // `processEncryption`, which suspends the main actor while the detached task runs,
    // allowing `concurrencyLimit` detached tasks to overlap. See the `withTaskGroup`
    // comment above for the full concurrency model and the post-beta refactor plan.
    private func processBatchEncryptionJob(
        _ job: BatchEncryptionJob,
        password: String,
        destination: URL,
        policy: CollisionPolicy,
        config: EncryptionConfig,
        reportsEnabled: Bool,
        hashCache: BatchReportService.HashCache
    ) async -> BatchEncryptionResult {
        let item = job.item
        await MainActor.run {
            self.batchInfo?.currentFileName = item.url.lastPathComponent
            self.batchInfo?.currentFileProgress = nil
        }

        let sizeBefore = await cachedFileSize(of: item, using: hashCache)
        let sha256Before = await cachedSHA256(of: item, using: hashCache)
        let md5Before = reportsEnabled ? await cachedMD5(of: item, using: hashCache) : "Hidden"
        let startTime = Date()

        let (success, processedItem, failureReason, _) = await self.processEncryption(
            for: item,
            password: password,
            destination: destination,
            policy: policy,
            config: config,
            startBates: job.batesStart,
            inputHash: sha256Before,
            reservedOutputURL: job.reservedOutputURL,
            hashCache: hashCache
        )

        let endTime = Date()
        var details: [String: String] = [
            "Encryption": item.type == .pdf ? "PDFKit standard PDF encryption" : "Office/ZIP password encryption"
        ]
        if let wm = config.watermarkConfig {
            details["Watermark"] = wm.text
            details["Watermark Opacity"] = String(format: "%.0f%%", wm.opacity * 100)
            if wm.batesEnabled {
                if job.batesUnitCount > 0 {
                    let batesEnd = job.batesStart + job.batesUnitCount - 1
                    let startValue = String(format: "%0\(wm.batesDigitCount)d", job.batesStart)
                    let endValue = String(format: "%0\(wm.batesDigitCount)d", batesEnd)
                    details["Bates Range"] = "\(wm.batesPrefix)\(startValue)-\(wm.batesPrefix)\(endValue)"
                }
            }
        }
        if config.autoSplitEnabled {
            details["Auto-Split"] = "\(config.autoSplitLimit) MB limit"
        }
        if config.shouldShred {
            details["Source Overwritten Then Removed"] = "Yes"
        }
        if config.markAsFinal {
            details["Marked as Final"] = "Yes"
        }
        if config.restrictionType != .none {
            details["DOCX Restriction"] = "\(config.restrictionType)"
        }

        var md5After: String? = nil
        if reportsEnabled, let outURL = item.outputURL {
            md5After = await hashCache.md5(of: outURL)
        }
        let sizeAfter: Int64?
        if let outURL = item.outputURL {
            sizeAfter = await hashCache.fileSize(of: outURL)
        } else {
            sizeAfter = nil
        }

        let fileReport = BatchReportService.FileReport(
            fileID: item.id.uuidString,
            fileName: item.url.lastPathComponent,
            sourceURL: item.url,
            outputURL: item.outputURL,
            operation: "Encryption",
            success: success,
            errorMessage: failureReason,
            startTime: startTime,
            endTime: endTime,
            fileSizeBefore: sizeBefore,
            fileSizeAfter: sizeAfter,
            md5Before: md5Before,
            md5After: md5After,
            details: details
        )

        return BatchEncryptionResult(
            index: job.index,
            success: success,
            item: processedItem,
            failureReason: failureReason,
            fileReport: fileReport
        )
    }

    // Process single file encryption
    private func processEncryption(
        for item: FileItem,
        password: String,
        destination: URL,
        policy: CollisionPolicy,
        config: EncryptionConfig,
        startBates: Int,
        inputHash: String?,
        reservedOutputURL: URL? = nil,
        hashCache: BatchReportService.HashCache? = nil
    ) async -> (success: Bool, item: FileItem, failureReason: String?, nextBates: Int?) {

        // Use config values instead of reading UserDefaults
        let watermarkConfig = config.watermarkConfig
        let autoSplitEnabled = config.autoSplitEnabled
        let autoSplitLimit = config.autoSplitLimit

        // ... (rest of logic uses these variables) ...

        let outName = item.type == .folder ? item.url.lastPathComponent + ".zip" : item.url.lastPathComponent
        let sessionTempDir = self.sessionTempDirectory

        // Base Result Name Logic
        let finalOutputURL: URL
        if let reservedOutputURL {
             finalOutputURL = reservedOutputURL
        } else if policy == .replace {
             finalOutputURL = destination.appendingPathComponent(outName)
        } else {
             finalOutputURL = generateUniqueURL(for: outName, in: destination)
        }

        if item.type == .folder && finalOutputURL.standardizedFileURL.path.hasPrefix(item.url.standardizedFileURL.path + "/") {
            return (false, item, "Output path must not be inside the source folder.", nil)
        }

        // 1. Use standard temporary directory for reliability (avoid volume/permission issues with itemReplacementDirectory)
        let tempUUID = UUID().uuidString
        let tempDirectoryURL = sessionTempDir.appendingPathComponent(tempUUID)
        do {
             try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        } catch {
             return (false, item, "Failed to create temporary directory.", nil)
        }

        let tempURL = tempDirectoryURL.appendingPathComponent(outName)

        // Ensure cleanup of the entire temp directory
        defer {
            try? SecureDeletionService.shared.shredItem(at: tempDirectoryURL)
        }

        // Pre-process: Strip metadata if enabled
        var effectiveSourceURL = item.url
        var effectiveBookmarkData = item.securityScopedBookmarkData
        if UserDefaults.standard.bool(forKey: "StripMetadataBeforeEncryption") {
            let stripTempURL = tempDirectoryURL.appendingPathComponent("stripped_" + item.url.lastPathComponent)
            do {
                switch item.type {
                case .pdf:
                    try FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleSourceURL in
                        try MetadataStripService.shared.stripPDFMetadata(at: accessibleSourceURL, to: stripTempURL)
                    }
                    effectiveSourceURL = stripTempURL
                    effectiveBookmarkData = nil
                case .docx:
                    try await FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleSourceURL in
                        try await MetadataStripService.shared.stripDocxMetadata(at: accessibleSourceURL, to: stripTempURL)
                    }
                    effectiveSourceURL = stripTempURL
                    effectiveBookmarkData = nil
                default:
                    break // No metadata stripping for folders, zips
                }
	            } catch {
	                return (false, item, "Metadata stripping failed: \(error.localizedDescription)", nil)
	            }
	        }


        let itemType = item.type
        let itemURL = item.url
        let originalBookmarkData = item.securityScopedBookmarkData
        let progressHandler = makeProgressHandler(for: item)

        // ... (Captured variables must be Sendable) ...

        // Capture explicit values in the closure to avoid capturing `self`, which is non-Sendable.
        let task = Task.detached(priority: .userInitiated) { [sessionTempDir, effectiveSourceURL, effectiveBookmarkData, originalBookmarkData, destination, itemType, itemURL, password, watermarkConfig, autoSplitEnabled, autoSplitLimit, startBates, tempURL, tempDirectoryURL, progressHandler] () async -> (Bool, String?, Int?, URL?) in
            // Also access destination folder for writing
            let destAccess = destination.startAccessingSecurityScopedResource()

            defer {
                if destAccess {
                    destination.stopAccessingSecurityScopedResource()
                }
            }

            if Task.isCancelled { return (false, "Cancelled", nil, nil) }

            var success = false
            var errorMsg: String? = nil
            var nextBatesResult: Int? = nil
            var producedArtifactURLs: [URL] = []
            var primaryFinalURL: URL? = nil

            do {
                try await FileItem.withSecurityScopedAccess(url: effectiveSourceURL, bookmarkData: effectiveBookmarkData) { accessibleSourceURL in
                    // ... (Encryption Logic) ...
                    switch itemType {
                    case .pdf:
                        guard let doc = PDFDocument(url: accessibleSourceURL) else {
                            throw NSError(domain: "Marcrypt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read PDF"])
                        }

                        if autoSplitEnabled {
                            do {
                                let chunks = try PdfProcessingService.shared.split(document: doc, limitMB: autoSplitLimit, progress: progressHandler)

                                if chunks.count > 1 {
                                    // Split Processing
                                    let baseName = tempURL.deletingPathExtension().lastPathComponent
                                    let ext = tempURL.pathExtension

                                    var currentChunkBates = startBates

                                    for (i, chunk) in chunks.enumerated() {
                                        if Task.isCancelled { throw CancellationError() }

                                        let partName = "\(baseName)_Part\(i+1).\(ext)"
                                        let partURL = tempDirectoryURL.appendingPathComponent(partName)

                                        let next = try PdfProcessingService.shared.writeEncryptedPDF(
                                            document: chunk,
                                            to: partURL,
                                            password: password,
                                            watermark: watermarkConfig,
                                            startBates: currentChunkBates,
                                            progress: progressHandler
                                        )

                                        if let n = next { currentChunkBates = n }
                                        producedArtifactURLs.append(partURL)
                                    }
                                    success = true
                                    nextBatesResult = currentChunkBates
                                } else {
                                     // Split enabled but single chunk (fallback to standard write)
                                     let next = try PdfProcessingService.shared.writeEncryptedPDF(
                                        document: doc,
                                        to: tempURL,
                                        password: password,
                                        watermark: watermarkConfig,
                                        startBates: startBates,
                                        progress: progressHandler
                                    )
                                    success = true
                                    nextBatesResult = next
                                    producedArtifactURLs.append(tempURL)
                                }
                            } catch {
                                throw error
                            }
                        } else {
                            // Standard Write (Single File)
                            let next = try PdfProcessingService.shared.writeEncryptedPDF(
                                document: doc,
                                to: tempURL,
                                password: password,
                                watermark: watermarkConfig,
                                startBates: startBates,
                                progress: progressHandler
                            )
                            success = true
                            nextBatesResult = next
                            producedArtifactURLs.append(tempURL)
                        }

                    case .folder:
                        do {
                            // Pre-processing: If watermark enabled, watermark inner files first
                            if let wmConfig = watermarkConfig {
                                let folderCopy = tempDirectoryURL.appendingPathComponent(itemURL.lastPathComponent)
                                // Copy original to temp folder
                                try FileManager.default.copyItem(at: accessibleSourceURL, to: folderCopy)
                                // Apply watermarks
                                self.applyWatermarksRecursively(in: folderCopy, config: wmConfig)
                                // Zip the MODIFIED folder
                                try await ArchiveService.shared.zipFolder(at: folderCopy, to: tempURL, password: password, progress: progressHandler)
                                // Cleanup folder copy is handled by tempDirectoryURL cleanup
                                producedArtifactURLs.append(tempURL)
                            } else {
                                try await ArchiveService.shared.zipFolder(at: accessibleSourceURL, to: tempURL, password: password, progress: progressHandler)
                                producedArtifactURLs.append(tempURL)
                            }
                            success = true
                        } catch {
                            success = false
                            errorMsg = "Failed to create Zip archive: \(error.localizedDescription)"
                        }

                    case .docx:
                        // Logic updated to use config

                        let docxOptions = DocxService.Options(
                            openPassword: config.encryptStructure ? password : "",
                            modifyPassword: config.modifyPassword,
                            restriction: config.restrictionType,
                            markAsFinal: config.markAsFinal,
                            watermark: watermarkConfig
                        )

                        do {
                            var pageCount: Int?
                            // Always apply Office Agile (AES-256) encryption when a password is set,
                            // because XML-level protection alone does not enforce a password-to-open.
                            if config.encryptStructure || !password.isEmpty {
                                let innerTemp = sessionTempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("docx")
                                pageCount = try await DocxService.shared.protect(docxAt: accessibleSourceURL, to: innerTemp, options: docxOptions, startBates: startBates, progress: progressHandler)
                                defer { try? SecureDeletionService.shared.shredItem(at: innerTemp) }
                                try await DocxEncryptionService.shared.encrypt(docxFile: innerTemp, to: tempURL, password: password, progress: progressHandler)
                            } else {
                                // Ensure parent dir exists (it should, tempURL is in tempDirectoryURL)
                                pageCount = try await DocxService.shared.protect(docxAt: accessibleSourceURL, to: tempURL, options: docxOptions, startBates: startBates, progress: progressHandler)
                            }
                            success = true

                            // Update nextBates for sequence
                            if let pc = pageCount {
                                 nextBatesResult = startBates + pc
                            } else if watermarkConfig?.batesEnabled == true {
                                 nextBatesResult = startBates + 1
                            }
                            producedArtifactURLs.append(tempURL)
                        } catch {
                            success = false
                            errorMsg = "Failed to apply Docx protection: \(error.localizedDescription)"
                        }

                    case .zip:
                        success = false
                        errorMsg = "Cannot re-encrypt a zip file yet."

                    default:
                        success = false
                        errorMsg = "Unsupported"
                    }
                }
            } catch is CancellationError {
                return (false, "Operation cancelled", nil, nil)
            } catch {
                return (false, error.localizedDescription, nil, nil)
            }

            // MOVE to Final Destination
            if success {
                if Task.isCancelled { return (false, "Cancelled", nil, nil) }
                // Destination Handling
                do {
                    // Check if we produced multiple files (split)
                    // Clean up the stripped metadata intermediate file before moving results
                    if effectiveSourceURL != itemURL {
                        try? SecureDeletionService.shared.shredItem(at: effectiveSourceURL)
                    }

                    for fileURL in producedArtifactURLs {
                         let fileName = fileURL.lastPathComponent
                         // Determine final path for this file
                         let finalPath: URL
                             if producedArtifactURLs.count == 1 && tempURL.lastPathComponent == fileName {
                                 finalPath = finalOutputURL
	                         } else if policy == .replace {
	                             finalPath = destination.appendingPathComponent(fileName)
	                         } else {
	                             finalPath = self.generateUniqueURL(for: fileName, in: destination)
	                         }

	                         if config.shouldShred && finalPath.standardizedFileURL.path == itemURL.standardizedFileURL.path {
	                             throw NSError(
	                                domain: "Marcrypt",
	                                code: 2,
	                                userInfo: [NSLocalizedDescriptionKey: "Refusing to shred original when output replaces the original path."]
	                             )
	                         }

                         // Perform Atomic Move
                         if FileManager.default.fileExists(atPath: finalPath.path) {
                              if policy == .replace {
                                  // Atomic replace: crash-safe file placement
                                  _ = try FileManager.default.replaceItemAt(finalPath, withItemAt: fileURL)
                              } else {
                                  throw NSError(domain: "Marcrypt", code: 1, userInfo: [NSLocalizedDescriptionKey: "File exists"])
                              }
                          } else {
                              try FileManager.default.moveItem(at: fileURL, to: finalPath)
                          }

                         if primaryFinalURL == nil {
                             primaryFinalURL = finalPath
                         }
                    }

                } catch {
                    success = false
                    errorMsg = "Failed to save file: \(error.localizedDescription)"
                }
            }

            // Secure Shred if Successful
            if success && config.shouldShred {
                try? FileItem.withSecurityScopedAccess(url: itemURL, bookmarkData: originalBookmarkData) { accessibleOriginalURL in
                    try SecureDeletionService.shared.shredItem(at: accessibleOriginalURL)
                }
            }

            return (success, errorMsg, nextBatesResult, primaryFinalURL)
        }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if result.0 {
            // Encryption Success
            let finalStatus: ProcessingStatus = (watermarkConfig != nil) ? .watermarkedEncrypted : .encryptionSucceeded
            let actualOutputURL = result.3 ?? finalOutputURL
            self.update(item, finalStatus, nil, outputURL: actualOutputURL)
            let outputHash: String?
            if let hashCache {
                outputHash = await hashCache.sha256(of: actualOutputURL)
            } else {
                outputHash = try? IntegrityService.shared.sha256(of: actualOutputURL)
            }

            AuditService.shared.logSuccess(
                operation: .encrypt,
                inputFile: item.url.lastPathComponent,
                inputHash: inputHash,
                outputFile: actualOutputURL.lastPathComponent,
                outputHash: outputHash,
                parameters: ["type": item.type == .pdf ? "PDF" : item.type == .docx ? "DOCX" : "ZIP"]
            )
            return (true, item, nil, result.2)
        } else {
            self.update(item, .encryptionFailed, result.1)
            // Audit: log failure
            AuditService.shared.logFailure(
                operation: .encrypt,
                inputFile: item.url.lastPathComponent,
                reason: result.1 ?? "Unknown error"
            )
            return (false, item, result.1, nil)
        }
    }

    // MARK: - Watermark Only Flow

    func watermarkAll(to destination: URL, completion: @escaping (Bool, [String], Int, Int) -> Void) async {
        let itemsToProcess = self.items.filter { $0.status == .notEncrypted || $0.status == .encryptionFailed }

        guard !itemsToProcess.isEmpty else {
            completion(false, [], 0, 0)
            return
        }

        await MainActor.run {
            self.batchInfo = BatchProgressInfo(processed: 0, total: itemsToProcess.count, successCount: 0, failedCount: 0, isProcessing: true)
            for item in itemsToProcess { self.update(item, .processing, nil) }
        }

        let defaults = UserDefaults.standard
        let watermarkEnabled = defaults.bool(forKey: "WatermarkEnabled")
        let batesEnabled = defaults.bool(forKey: "BatesEnabled")

        let watermarkText = watermarkEnabled ? (defaults.string(forKey: "WatermarkText") ?? "DRAFT") : ""

        let watermarkConfig = PdfProcessingService.WatermarkConfig(
            text: watermarkText,
            size: defaults.integer(forKey: "WatermarkSize") > 0 ? defaults.integer(forKey: "WatermarkSize") : 48,
            opacity: watermarkEnabled ? (defaults.double(forKey: "WatermarkOpacity") > 0 ? defaults.double(forKey: "WatermarkOpacity") : 0.25) : 0.0,
            location: watermarkEnabled ? defaults.integer(forKey: "WatermarkLocation") : 0,
            colorHex: defaults.string(forKey: "WatermarkColorHex") ?? "#FF0000",
            batesEnabled: batesEnabled,
            batesPrefix: defaults.string(forKey: "BatesPrefix") ?? "",
            batesStartNumber: defaults.integer(forKey: "BatesStartNumber") > 0 ? defaults.integer(forKey: "BatesStartNumber") : 1,
            batesDigitCount: defaults.integer(forKey: "BatesDigitCount") > 0 ? defaults.integer(forKey: "BatesDigitCount") : 6,
            batesLocation: defaults.integer(forKey: "BatesLocation") > 0 ? defaults.integer(forKey: "BatesLocation") : 2,
            batesFontFamily: defaults.integer(forKey: "BatesFontFamily"),
            batesFontSize: defaults.integer(forKey: "BatesFontSize") > 0 ? defaults.integer(forKey: "BatesFontSize") : 10,
            batesColorHex: defaults.string(forKey: "BatesColorHex") ?? "#000000",
            batesIncludeTimestamp: defaults.bool(forKey: "BatesIncludeTimestamp")
        )

        var currentBatesStart = watermarkConfig.batesStartNumber

        // Access Destination
        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }

        var results: [(success: Bool, item: FileItem, failureReason: String?)] = []
        var fileReports: [BatchReportService.FileReport] = []
        let reportsEnabled = UserDefaults.standard.bool(forKey: "GenerateBatchReports")
        let hashCache = BatchReportService.HashCache()

        for (index, item) in itemsToProcess.enumerated() {
             // Track current file for UI
             await MainActor.run { self.batchInfo?.currentFileName = item.url.lastPathComponent }

	             if Task.isCancelled { break }

	             // Collect report data before processing
	             let sha256Before = await cachedSHA256(of: item, using: hashCache)
	             let md5Before = reportsEnabled ? await cachedMD5(of: item, using: hashCache) : "Hidden"
	             let sizeBefore = await cachedFileSize(of: item, using: hashCache)
	             let startTime = Date()

            let fileBatesStart = currentBatesStart
            let (success, processedItem, failureReason, nextBates, outputURL) = await self.processWatermarking(for: item, destination: destination, config: watermarkConfig, startBates: fileBatesStart)

            if let nb = nextBates {
                currentBatesStart = nb
            }
            if let outputURL {
                item.outputURL = outputURL
            }

            let result = (success: success, item: processedItem, failureReason: failureReason)

             // Collect report data after processing
             let endTime = Date()
             let details: [String: String] = [
                 "Watermark Text": watermarkConfig.text,
                 "Watermark Opacity": String(format: "%.0f%%", watermarkConfig.opacity * 100),
                 "Watermark Size": "\(watermarkConfig.size)pt"
             ]

	             var md5After: String? = nil
	             if reportsEnabled, let outURL = item.outputURL {
	                 md5After = await hashCache.md5(of: outURL)
	             }
             let sizeAfter: Int64?
             if let outURL = item.outputURL {
                 sizeAfter = await hashCache.fileSize(of: outURL)
             } else {
                 sizeAfter = nil
             }

             fileReports.append(BatchReportService.FileReport(
                 fileID: item.id.uuidString,
                 fileName: item.url.lastPathComponent,
                 sourceURL: item.url,
                 outputURL: item.outputURL,
                 operation: "Watermarking",
                 success: result.success,
                 errorMessage: result.failureReason,
                 startTime: startTime,
                 endTime: endTime,
                 fileSizeBefore: sizeBefore,
                 fileSizeAfter: sizeAfter,
                 md5Before: md5Before,
                 md5After: md5After,
                 details: details
             ))

             results.append(result)
             let outputHashForAudit: String?
             if result.success, let outURL = item.outputURL {
                 outputHashForAudit = await hashCache.sha256(of: outURL)
             } else {
                 outputHashForAudit = nil
             }

            await MainActor.run {
                self.batchInfo?.processed = index + 1
                if result.success { self.batchInfo?.successCount += 1 }
                else { self.batchInfo?.failedCount += 1 }
                // Reset status to allow re-processing or other actions
                self.update(item, result.success ? .watermarked : .notEncrypted, result.success ? nil : "Watermark failed", outputURL: outputURL)

                if result.success {
                    var params = ["Watermark Text": watermarkConfig.text]
                    if watermarkConfig.batesEnabled {
                         let fileBatesEnd = max(fileBatesStart, (nextBates ?? currentBatesStart) - 1)
                         let startValue = String(format: "%0\(watermarkConfig.batesDigitCount)d", fileBatesStart)
                         let endValue = String(format: "%0\(watermarkConfig.batesDigitCount)d", fileBatesEnd)
                         params["Bates Range"] = "\(watermarkConfig.batesPrefix)\(startValue)-\(watermarkConfig.batesPrefix)\(endValue)"
                    }
                    AuditService.shared.logSuccess(
	                        operation: watermarkConfig.batesEnabled ? .batesStamp : .watermark,
	                        inputFile: item.url.lastPathComponent,
	                        inputHash: sha256Before,
	                        outputFile: item.outputURL?.lastPathComponent,
	                        outputHash: outputHashForAudit,
	                        parameters: params
	                    )
	                }
	            }
	        }

	        // Generate batch report
	        if reportsEnabled,
	           let reportURL = BatchReportService.shared.generateReport(
            title: "Watermark Report",
            batchOperation: "Watermarking",
            files: fileReports,
            outputDirectory: destination
        ) {
            await MainActor.run {
                for item in itemsToProcess {
                    item.reportURL = reportURL
                }
            }
        }

        await MainActor.run { self.batchInfo?.isProcessing = false }

        let successCount = results.filter { $0.success }.count
        let failedFiles = results.filter { !$0.success }.map { $0.item.url.lastPathComponent }

        completion(successCount > 0, failedFiles, successCount, results.count)
    }

    private func processWatermarking(for item: FileItem, destination: URL, config: PdfProcessingService.WatermarkConfig, startBates: Int) async -> (success: Bool, item: FileItem, failureReason: String?, nextBates: Int?, outputURL: URL?) {
        let itemType = item.type
        let itemURL = item.url
        let bookmarkData = item.securityScopedBookmarkData
        let progressHandler = makeProgressHandler(for: item)

        let outName = itemType == .folder ? itemURL.lastPathComponent + ".zip" : itemURL.lastPathComponent
        let finalOutputURL = generateUniqueURL(for: outName, in: destination)
        let sessionTempDir = self.sessionTempDirectory

        // Temp Dir
        let tempUUID = UUID().uuidString
        let tempDir = sessionTempDir.appendingPathComponent(tempUUID)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? SecureDeletionService.shared.shredItem(at: tempDir) }

        let tempURL = tempDir.appendingPathComponent(outName)

        // Capture explicit values in the closure to avoid capturing `self`, which is non-Sendable.
        return await Task.detached(priority: .userInitiated) { [itemURL, bookmarkData, tempURL, finalOutputURL, config, startBates, itemType, tempDir, progressHandler] () async -> (Bool, FileItem, String?, Int?, URL?) in
            var success = false
            var error: String? = nil
            var nextBatesResult: Int? = nil

            do {
                try await FileItem.withSecurityScopedAccess(url: itemURL, bookmarkData: bookmarkData) { accessibleSourceURL in
                    switch itemType {
                    case .pdf:
                        if let doc = PDFDocument(url: accessibleSourceURL) {
                            do {
                                if let nextBates = try PdfProcessingService.shared.writeWatermarkedPDF(document: doc, to: tempURL, watermark: config, startBates: startBates, progress: progressHandler) {
                                    success = true
                                    nextBatesResult = nextBates
                                } else {
                                    error = "Failed to write PDF"
                                }
                            } catch let e {
                                error = e.localizedDescription
                            }
                        } else {
                            error = "Invalid PDF"
                        }

                    case .folder:
                        // Folder logic: Copy, Watermark Recursive, Zip
                        let folderCopy = tempDir.appendingPathComponent(itemURL.lastPathComponent)
                        do {
                            try FileManager.default.copyItem(at: accessibleSourceURL, to: folderCopy)
                            self.applyWatermarksRecursively(in: folderCopy, config: config)
                            // Zip the folderCopy to tempURL (which is name.zip)
                            try await ArchiveService.shared.zipFolder(at: folderCopy, to: tempURL, password: "", progress: progressHandler)
                            success = true
                            // Folders don't consume bates numbers unless we track inside recursion (complex).
                            // Bates tracking for folders is not propagated here; caller receives nil (counter unchanged).
                        } catch let e {
                            error = e.localizedDescription
                        }

                    case .docx:
                         do {
                             // Apply Watermark via DocxService (No password/restriction, just WM)
                             // Use config directly
                             let options = DocxService.Options(openPassword: "", modifyPassword: "", restriction: .none, markAsFinal: false, watermark: config)

                             let pageCount = try await DocxService.shared.protect(docxAt: accessibleSourceURL, to: tempURL, options: options, startBates: startBates, progress: progressHandler)
                             success = true

                             if let pc = pageCount {
                                  nextBatesResult = startBates + pc
                             } else {
                                  // Assume 1 page if count fails, to keep sequence moving
                                  nextBatesResult = startBates + 1
                             }
                         } catch let e {
                             error = "DOCX Watermark failed: \(e.localizedDescription)"
                         }

                    default:
                         error = "Unsupported"
                    }
                }
            } catch let accessError {
                _ = accessError
                error = "Cannot access file. Re-add it to grant access."
            }

            if success {
                // Atomic Move Logic
                do {
                    if FileManager.default.fileExists(atPath: finalOutputURL.path) {
                        _ = try FileManager.default.replaceItemAt(finalOutputURL, withItemAt: tempURL)
                    } else {
                        try FileManager.default.moveItem(at: tempURL, to: finalOutputURL)
                    }
	                    return (true, item, nil, nextBatesResult, finalOutputURL)
	                } catch {
	                     return (false, item, "Save failed: \(error.localizedDescription)", nil, nil)
	                }
	            } else {
	                return (false, item, error, nil, nil)
	            }
	        }.value
	    }

    private nonisolated func applyWatermarksRecursively(in directory: URL, config: PdfProcessingService.WatermarkConfig) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "pdf" {
                if let doc = PDFDocument(url: fileURL) {
                    let tempFile = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
                    if (try? PdfProcessingService.shared.writeWatermarkedPDF(document: doc, to: tempFile, watermark: config, startBates: 1)) != nil {
                        try? SecureDeletionService.shared.shredItem(at: fileURL)
                        try? fileManager.moveItem(at: tempFile, to: fileURL)
                    }
                }
            }
        }
    }

    // Generate unique filename using macOS collision handling
    nonisolated private func generateUniqueURL(for filename: String, in directory: URL) -> URL {
        let baseURL = directory.appendingPathComponent(filename)

        // Check if file exists
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        // Generate unique name
        let nameWithoutExtension = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension

        var counter = 1
        // Safety limit to prevent infinite loops (e.g. filesystem issues)
        while counter < 2000 {
            let newName = "\(nameWithoutExtension) (\(counter)).\(fileExtension)"
            let newURL = directory.appendingPathComponent(newName)

            if !FileManager.default.fileExists(atPath: newURL.path) {
                return newURL
            }
            counter += 1
        }

        // Fallback: Use timestamp if limit reached
        let timestamp = Int(Date().timeIntervalSince1970)
        return directory.appendingPathComponent("\(nameWithoutExtension)_\(timestamp).\(fileExtension)")
    }

    // MARK: - State Management

    private    func updateButtonStates() {
        _ = !items.isEmpty
        // Allow encryption if any item is not fully shielded (e.g. not encrypted yet)
        // Or if we just added files (status .notEncrypted)
        hasUnencrypted = items.contains { $0.status == .notEncrypted || $0.status == .decrypted || $0.status == .watermarked || $0.status == .encryptionFailed }

        // Allow decryption if any item is encrypted
        hasEncrypted = items.contains { $0.status == .encrypted || $0.status == .decryptionFailed }
    }

    var hasFiles: Bool {
        !items.isEmpty
    }

    func clearAllFiles() {
        // Prevent clearing during in-flight batch operations to avoid dangling references
        guard batchInfo?.isProcessing != true else {
            AppLogger.warning("Cannot clear files while a batch operation is in progress", logger: AppLogger.general)
            return
        }

	        // Clear any decrypted documents from memory before removing items
	        var managedRoots = Set<URL>()
	        for item in items {
	            // Cancel background tasks
	            item.statusCheckTask?.cancel()

	                item.decryptedDocument = nil
	                if let tempURL = item.temporaryDecryptedURL {
	                    try? SecureDeletionService.shared.shredItem(at: tempURL)
	                }
	                if let root = item.managedSourceRoot {
	                    managedRoots.insert(root)
	                }
	        }
	        for root in managedRoots {
	            try? SecureDeletionService.shared.shredItem(at: root)
	        }
	        items.removeAll()
	        updateButtonStates()
	    }

	    func removeFiles(at offsets: IndexSet) {
	        var managedRoots = Set<URL>()
	        for index in offsets {
	            let item = items[index]
	            item.statusCheckTask?.cancel()

	            if let tempURL = item.temporaryDecryptedURL {
	                try? SecureDeletionService.shared.shredItem(at: tempURL)
	            }
	            if let root = item.managedSourceRoot {
	                managedRoots.insert(root)
	            }
	        }
	        items.remove(atOffsets: offsets)
	        let retainedManagedRoots = Set(items.compactMap(\.managedSourceRoot))
	        for root in managedRoots where !retainedManagedRoots.contains(root) {
	            try? SecureDeletionService.shared.shredItem(at: root)
	        }
	        updateButtonStates()
	    }

    func resetProcessingFiles() {
        for item in items where item.status == .processing {
            update(item, .notEncrypted, nil)
        }
    }

    // MARK: - Report Viewer

    /// Opens the batch report for the given item, deep-linked to that file's section.
    func openReport(for item: FileItem) {
        guard let reportURL = item.reportURL else { return }
        activeReport = ReportViewerItem(
            url: reportURL,
            title: "Processing Report",
            anchorFileID: "file-\(item.id.uuidString)"
        )
    }
}

private actor AsyncLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }

                if active < limit {
                    active += 1
                    continuation.resume(returning: true)
                    return
                }

                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

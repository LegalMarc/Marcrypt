import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit
import MarcryptCore

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var vm = FileViewModel()
    @State private var password = ""
    @State private var showPwdPrompt = false
    @State private var showPasswordRetryPrompt = false
    @State private var alertItem: FileItem?
    @State private var isTargeted = false

    // Collision State
    @State private var collisionPendingDest: URL?
    @State private var collisionPendingPassword = ""
    @State private var showCollisionAlert = false
    @State private var collisionCount = 0
    
    // Encryption state
    @State private var preflightAlertInfo: AlertInfo?
    @State private var currentEncryptionTask: Task<Void, Never>?
    @State private var currentWatermarkTask: Task<Void, Never>?
    @State private var encryptionFlow: EncryptionFlowStep = .idle
    
    // Preferences
    @State private var showSettings = false
    @State private var showClearConfirmation = false
    @State private var keyboardMonitor: Any?
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(spacing: 24) {
            // Drop zone directly in main layout
            dropZone
            
            // Clear List Button (only when files are present)
            if !vm.items.isEmpty {
                HStack {
                Button(action: { vm.clearAllFiles() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Clear List")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.3))
                        .foregroundColor(.white.opacity(0.7))
                        .cornerRadius(10)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Spacer()
                }
            }
            
            FileListView(vm: vm, alertItem: $alertItem)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let info = vm.batchInfo, info.isProcessing {
                        BatchProgressView(
                            processed: info.processed,
                            total: info.total,
                            successCount: info.successCount,
                            failedCount: info.failedCount,
                            currentFileName: info.currentFileName,
                            currentFileProgress: info.currentFileProgress,
                            onCancel: {
                                stopEncryption()
                            }
                        )
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            
            actionButtons
            FooterView()
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 800) // Set minimum size (Portrait/Taller aspect ratio)
        .background(CustomColors.appBackground(for: colorScheme).ignoresSafeArea())
        .background(WindowBackgroundView().opacity(0))
        // Decryption Alerts removed in favor of Unified Sheet logic
        .sheet(isPresented: Binding(
             get: { showPwdPrompt || showPasswordRetryPrompt }, // Triggered by button or retry
             set: { if !$0 { showPwdPrompt = false; showPasswordRetryPrompt = false } }
         )) {
             DecryptPasswordDialog(
                 isRetry: showPasswordRetryPrompt,
                 onCancel: {
                     showPwdPrompt = false
                     showPasswordRetryPrompt = false
                 },
                 onDecrypt: { password in
                     self.password = password
                     showPwdPrompt = false
                     showPasswordRetryPrompt = false
                     attemptDecryption()
                 },
                 vm: vm // Pass viewmodel for guessing
             )
         }
        .sheet(isPresented: Binding(
            get: { encryptionFlow.showsPasswordDialog },
            set: { if !$0 { encryptionFlow = .idle } }
        )) {
            EncryptPasswordDialog(
                isRetry: encryptionFlow.isRetryFlow,
                onCancel: {
                    encryptionFlow = .idle
                },
                onEncrypt: { confirmedPassword in
                    // 1. Dismiss the sheet first by changing state
                    // We need to capture the password to use after dismissal
                    
                    // Check if this is a retry with existing destination
                    if encryptionFlow.isRetryFlow, let existingDestination = encryptionFlow.destinationURL {
                        // For retry, we can proceed immediately as we have the destination
                        proceedWithEncryption(to: existingDestination, password: confirmedPassword, policy: .replace)
                    } else {
                        // For new encryption, close sheet then open panel
                        // We use a slight delay or state change to allow sheet to close
                        encryptionFlow = .idle // Dismiss sheet
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            selectDestinationAndEncrypt(with: confirmedPassword)
                        }
                    }
                }
            )
        }
        .alert(item: $alertItem) { item in
            let title: String
            let message: String
            
            switch item.status {
            case .decryptionFailed:
                title = "Decryption Failed"
                message = item.errorMessage ?? "Unknown error occurred during decryption."
            case .encryptionFailed:
                title = "Encryption Failed"
                message = item.errorMessage ?? "Unknown error occurred during encryption."
            case .corrupted:
                title = "Corrupted File"
                message = item.errorMessage ?? "This file could not be read and may be corrupted or not a valid PDF file."
            case .notEncrypted:
                title = "Information"
                message = item.errorMessage ?? "This file is not encrypted."
            default:
                title = "Information"
                message = item.errorMessage ?? "Unknown error."
            }
            
            return Alert(title: Text(title),
                        message: Text(message),
                        dismissButton: .default(Text("OK")))
        }
        .alert(item: $preflightAlertInfo) { info in
            Alert(title: Text(info.title),
                  message: Text(info.message),
                  dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .marcryptClearHistoryRequested)) { _ in
            vm.clearAllFiles()
            vm.activeReport = nil
        }
        .alert("Clear All Files?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                vm.clearAllFiles()
            }
        } message: {
            Text("This will remove all files from the list. This action cannot be undone.")
        }
        .onAppear {
            guard keyboardMonitor == nil else { return }
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "o":
                        openPanel()
                        return nil
                    case "e":
                        if vm.hasUnencrypted {
                            startEncryptionProcess()
                        }
                        return nil
                    default:
                        break
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let keyboardMonitor {
                NSEvent.removeMonitor(keyboardMonitor)
                self.keyboardMonitor = nil
            }
        }

    
        .alert("Files Already Exist", isPresented: $showCollisionAlert) {
            Button("Keep Both", role: .none) {
                if let dest = collisionPendingDest {
                    proceedWithEncryption(to: dest, password: collisionPendingPassword, policy: .keepBoth)
                }
            }
            Button("Replace", role: .destructive) {
                if let dest = collisionPendingDest {
                    proceedWithEncryption(to: dest, password: collisionPendingPassword, policy: .replace)
                }
            }
            Button("Cancel", role: .cancel) { encryptionFlow = .idle }
        } message: {
            Text("\(collisionCount) file(s) with the same name already exist in the destination. Do you want to replace them or keep both copies?")
        }
        .alert("Unsupported Files", isPresented: $vm.showUnsupportedAlert) {
            Button("Remove Unsupported", role: .none) {
                vm.handleUnsupported(zipAll: false)
            }
            // Future "Zip All" feature
            // Button("Encrypted Zip All", role: .none) { vm.handleUnsupported(zipAll: true) }
        } message: {
            Text("Some files you dropped are not supported directly (only PDF, DOCX, ZIP). They have been removed from the list.")
        }
        .sheet(item: $vm.activeReport) { report in
            ReportViewer(report: report)
        }
    }
    
    // MARK: - UI Helpers
    private var dropZone: some View {
        VStack(spacing: 0) {
            // Drop area with contentBackground
            VStack(spacing: 18) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))

                Text("Drag & Drop PDF, Word, or Zip files")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                Text("(or folders to archive)")
                    .font(.system(size: 13))
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme).opacity(0.8))
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(CustomColors.contentBackground(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isTargeted ? CustomColors.accentColor(for: colorScheme) : CustomColors.subtleBorder(for: colorScheme).opacity(0.2),
                        style: StrokeStyle(lineWidth: 2.5, dash: isTargeted ? [] : [8, 4])
                    )
                    .animation(.easeInOut(duration: 0.2), value: isTargeted)
            )
            .scaleEffect(isTargeted ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
            .overlay(
                // DropCaptureView is the sole drop-handling pipeline. It uses AppKit
                // NSDraggingDestination to intercept both plain file-URL drags (Finder)
                // and NSFilePromiseReceiver drags (Mail/Outlook attachments). The
                // `isTargeted` binding is managed via `onTargetedChanged` callbacks.
                DropCaptureView(
                    isTargeted: $isTargeted,
                    onUserSelectedInputs: { inputs in
                        vm.addUserSelected(inputs: inputs)
                    },
                    onPromisedFiles: { urls, stagingRoot in
                        let acceptedCount = vm.addPromised(urls: urls, managedSourceRoot: stagingRoot)
                        if acceptedCount == 0, let stagingRoot {
                            try? SecureDeletionService.shared.shredItem(at: stagingRoot)
                        }
                    },
                    onFailedURLs: { urls in
                        vm.reportDropAdmissionFailures(urls)
                    }
                )
            )
            .padding([.horizontal, .top], 20)

            // Browse button bar
            HStack {
                Button(action: { openPanel() }) {
                    Text("Browse...")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .tint(CustomColors.accentColor(for: colorScheme))
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("browseButton")
                
                Spacer()
                
                Button(action: { showSettings = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14))
                        Text("Settings")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(20)
        }
        .background(CustomColors.cardBackground(for: colorScheme))
        .cornerRadius(16)
        .shadow(color: CustomColors.shadow(for: colorScheme), radius: 8, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(CustomColors.subtleBorder(for: colorScheme).opacity(0.3), lineWidth: 1)
        )
    }
    
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.pdf, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "zip")!, UTType.folder]
        if panel.runModal() == .OK {
            vm.addUserSelected(urls: panel.urls)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Encrypt/Stop Button
            if encryptionFlow.isEncrypting {
                Button(action: { stopEncryption() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Stop Encryption")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(CustomColors.destructiveColor(for: colorScheme))
                            .shadow(color: CustomColors.destructiveColor(for: colorScheme).opacity(0.2), radius: 6, y: 3)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stopEncryptionButton")
            } else {
                Button(action: { startEncryptionProcess() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Encrypt File(s)")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(vm.hasUnencrypted ? CustomColors.accentColor(for: colorScheme) : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                            .shadow(color: vm.hasUnencrypted ? CustomColors.accentColor(for: colorScheme).opacity(0.2) : Color.clear, radius: 6, y: 3)
                    )
                }
                .disabled(!vm.hasUnencrypted)
                .buttonStyle(.plain)
                .scaleEffect(vm.hasUnencrypted ? 1.0 : 0.98)
                .animation(.easeInOut(duration: 0.2), value: vm.hasUnencrypted)
                .accessibilityIdentifier("encryptButton")
            }
            
            // Decrypt Button
            Button(action: {
                password = ""; showPwdPrompt = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Decrypt File(s)")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(vm.hasEncrypted ? CustomColors.accentColor(for: colorScheme) : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                        .shadow(color: vm.hasEncrypted ? CustomColors.accentColor(for: colorScheme).opacity(0.2) : Color.clear, radius: 6, y: 3)
                )
            }
            .disabled(!vm.hasEncrypted)
            .buttonStyle(.plain)
            .scaleEffect(vm.hasEncrypted ? 1.0 : 0.98)
            .animation(.easeInOut(duration: 0.2), value: vm.hasEncrypted)
            .accessibilityIdentifier("decryptButton")

            // Watermark Only Button
            Button(action: {
                startWatermarkFlow()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Watermark Only")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(vm.hasUnencrypted ? Color.indigo : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                        .shadow(color: vm.hasUnencrypted ? Color.indigo.opacity(0.3) : Color.clear, radius: 6, y: 3)
                )
            }
            .disabled(!vm.hasUnencrypted)
            .buttonStyle(.plain)
            .scaleEffect(vm.hasUnencrypted ? 1.0 : 0.98)
            .animation(.easeInOut(duration: 0.2), value: vm.hasUnencrypted)
            .accessibilityIdentifier("watermarkOnlyButton")
        }
    }
    
    // MARK: - Encryption Flow
    
    private func startEncryptionProcess() {
        // Start with password entry - no destination selection yet
        encryptionFlow = .passwordEntry
    }
    
    private func selectDestinationAndEncrypt(with password: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose a folder to save the encrypted files"
        panel.prompt = "Save Here"
        
        if panel.runModal() == .OK, let dest = panel.url {
            // Pre-flight checks before starting encryption
            
            // 1. Check destination write permissions
            guard verifyDestinationIsWritable(url: dest) else {
                preflightAlertInfo = AlertInfo(
                    title: "Destination Not Writable",
                    message: "You do not have permission to save files to the chosen location. Please select a different folder."
                )
                // Return to password entry state so user can try again
                encryptionFlow = .passwordEntry
                return
            }
            
            // 2. Check for sufficient disk space
            guard verifySufficientDiskSpace(for: vm.items, at: dest) else {
                preflightAlertInfo = AlertInfo(
                    title: "Insufficient Disk Space",
                    message: "There may not be enough free space on the destination drive to save the encrypted files. Please free up space or choose a different location."
                )
                // Return to password entry state so user can try again
                encryptionFlow = .passwordEntry
                return
            }
            
            // All checks passed
            
            // 3. Check for Collisions
            Task {
                let collisions = await vm.checkForCollisions(at: dest)
                
                // Back on Main Actor
                if !collisions.isEmpty {
                    self.collisionCount = collisions.count
                    self.collisionPendingDest = dest
                    self.collisionPendingPassword = password
                    self.showCollisionAlert = true
                } else {
                    // Start encryption
                    proceedWithEncryption(to: dest, password: password, policy: .keepBoth)
                }
            }
        } else {
            // User cancelled destination selection, return to idle
            encryptionFlow = .idle
        }
    }
    
    // MARK: - Pre-flight Verification Functions
    
    private func verifyDestinationIsWritable(url: URL) -> Bool {
        let testFileURL = url.appendingPathComponent(".marcrypt-writetest")
        do {
            // Try to write a dummy file
            try "test".data(using: .utf8)?.write(to: testFileURL)
            // If successful, immediately remove it
            try FileManager.default.removeItem(at: testFileURL)
            return true
        } catch {
            // If either write or delete fails, we don't have permission
            AppLogger.warning("Destination verification failed: \(error.localizedDescription)", logger: AppLogger.general)
            return false
        }
    }
    
    private func verifySufficientDiskSpace(for items: [FileItem], at destination: URL) -> Bool {
        do {
            // Get the total size of all files that will be encrypted
            let filesToEncrypt = items.filter { $0.status == .notEncrypted }
            let totalSize = try filesToEncrypt.reduce(0) { (sum, item) -> Int64 in
                let attributes = try FileItem.withSecurityScopedAccess(url: item.url, bookmarkData: item.securityScopedBookmarkData) { accessibleURL in
                    try FileManager.default.attributesOfItem(atPath: accessibleURL.path)
                }
                return sum + (attributes[.size] as? Int64 ?? 0)
            }
            
            // Get available space on the destination volume
            let resourceValues = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let freeSpace = resourceValues.volumeAvailableCapacityForImportantUsage {
                // Add some buffer (10% or 100MB, whichever is smaller) to account for overhead
                let buffer = min(Int64(totalSize / 10), 100 * 1024 * 1024)
                return (totalSize + buffer) <= freeSpace
            }
            
            // If we can't get free space info, proceed but log a warning.
            AppLogger.warning("Could not verify disk space - proceeding anyway", logger: AppLogger.general)
            return true
            
        } catch {
            // Failed to get file sizes or free space; proceed but log a warning.
            AppLogger.warning("Could not verify disk space: \(error.localizedDescription)", logger: AppLogger.general)
            return true
        }
    }
    

    
    private func proceedWithEncryption(to destination: URL, password: String, policy: FileViewModel.CollisionPolicy) {
        // Check if destination is still available
        if !FileManager.default.fileExists(atPath: destination.path) {
            // Show destination unavailable alert
            preflightAlertInfo = AlertInfo(
                title: "Destination No Longer Available",
                message: "The originally chosen directory is no longer available. Please select a new location."
            )
            encryptionFlow = .idle
            return
        }
        
        // Start encryption with cancellation support
        encryptionFlow = .encrypting(destination, password: password)
        
        let task = Task { @MainActor in
            await vm.encryptAll(with: password, to: destination, policy: policy) { success, failedFiles, successCount, total in
                currentEncryptionTask = nil
                vm.registerCurrentBatchTask(nil)
                
                if success {
                    // Detailed Report
                    let title = failedFiles.isEmpty ? "Encryption Complete" : "Encryption Finished with Errors"
                    
                    var msg = "Successfully encrypted \(successCount) of \(total) files."
                    if !failedFiles.isEmpty {
                        msg += "\n\nFailed Files:\n" + failedFiles.map { "• \($0)" }.joined(separator: "\n")
                    }
                    
                    if UserDefaults.standard.bool(forKey: "SecureShredOriginals") {
                         msg += "\n\nNote: Original files were overwritten then removed. This is best-effort on SSD/APFS storage."
                    }
                    
                    preflightAlertInfo = AlertInfo(title: title, message: msg)
                    encryptionFlow = .idle
                } else {
                    // Distinguish cancellation from genuine failure
                    if failedFiles.isEmpty && total == 0 {
                        encryptionFlow = .idle  // User cancelled or no files
                    } else {
                        // All failed?
                        let title = "Encryption Failed"
                        // Try to provide a more specific reason if possible
                        var reason = failedFiles.first ?? "Unknown"
                        // If reason looks like a path (contains /), truncate it to filename
                        if reason.contains("/") {
                            reason = URL(fileURLWithPath: reason).lastPathComponent
                        }
                        
                        let msg = "Failed to encrypt any files.\nReason: \(reason)"
                         preflightAlertInfo = AlertInfo(title: title, message: msg)
                        // User requested NOT to re-prompt for password after failure.
                        encryptionFlow = .idle
                    }
                }
            }
        }
        currentEncryptionTask = task
        vm.registerCurrentBatchTask(task)
    }
    
    private func stopEncryption() {
        currentEncryptionTask?.cancel()
        currentEncryptionTask = nil
        currentWatermarkTask?.cancel()
        currentWatermarkTask = nil
        vm.cancelCurrentOperation()
        
        // Clear batch progress overlay immediately
        vm.batchInfo = nil
        
        // Reset any files that were in processing state
        vm.resetProcessingFiles()
        
        // Return to idle state
        encryptionFlow = .idle
    }
    
    // MARK: - Decryption Flow
    
    private func attemptDecryption() {
        guard !password.isEmpty else { return }
        
        vm.decryptAll(with: password) { anySucceeded, allFailed in
            if anySucceeded {
                // Some files succeeded, show save dialog
                self.chooseSaveDestination()
                // Clear password for security and reset prompts
                self.password = ""
                self.showPwdPrompt = false
                self.showPasswordRetryPrompt = false
            } else if allFailed {
                // All files failed, clear password and show retry dialog
                self.password = ""
                self.showPwdPrompt = false
                self.showPasswordRetryPrompt = true
            } else {
                // No decryptable files
                self.password = ""
                self.showPwdPrompt = false
                self.showPasswordRetryPrompt = false
            }
        }
    }
    
    // MARK: - Watermark Only Flow
    
    private func startWatermarkFlow() {
        // Just select destination
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a location to save watermarked files"
        panel.prompt = "Save Here"
        
        if panel.runModal() == .OK, let dest = panel.url {
            let task = Task { @MainActor in
                await vm.watermarkAll(to: dest) { success, failedFiles, successCount, total in
                    currentWatermarkTask = nil
                    vm.registerCurrentBatchTask(nil)
                    if success {
                        let title = failedFiles.isEmpty ? "Watermarking Complete" : "Watermarking Finished with Errors"
                        var msg = "Successfully processed \(successCount) of \(total) files."
                         if !failedFiles.isEmpty {
                            msg += "\n\nFailed Files:\n" + failedFiles.map { "• \($0)" }.joined(separator: "\n")
                        }
                        self.preflightAlertInfo = AlertInfo(title: title, message: msg)
                    } else {
                        self.preflightAlertInfo = AlertInfo(title: "Watermarking Failed", message: "Could not watermark files.")
                    }
                }
            }
            currentWatermarkTask = task
            vm.registerCurrentBatchTask(task)
        }
    }
    
    private func chooseSaveDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to save the decrypted files"
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let dest = panel.url {
            vm.saveDecryptedFiles(to: dest)
        }
    }
}

private struct DropCaptureView: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onUserSelectedInputs: ([FileViewModel.UserSelectedInput]) -> Void
    let onPromisedFiles: ([URL], URL?) -> Void
    let onFailedURLs: ([URL]) -> Void

    func makeNSView(context: Context) -> DropCaptureNSView {
        let view = DropCaptureNSView()
        view.onTargetedChanged = { targeted in
            DispatchQueue.main.async {
                isTargeted = targeted
            }
        }
        view.onUserSelectedInputs = onUserSelectedInputs
        view.onPromisedFiles = onPromisedFiles
        view.onFailedURLs = onFailedURLs
        return view
    }

    func updateNSView(_ nsView: DropCaptureNSView, context: Context) {
        nsView.onTargetedChanged = { targeted in
            DispatchQueue.main.async {
                isTargeted = targeted
            }
        }
        nsView.onUserSelectedInputs = onUserSelectedInputs
        nsView.onPromisedFiles = onPromisedFiles
        nsView.onFailedURLs = onFailedURLs
    }
}

private final class DropCaptureNSView: NSView {
    var onTargetedChanged: ((Bool) -> Void)?
    var onUserSelectedInputs: (([FileViewModel.UserSelectedInput]) -> Void)?
    var onPromisedFiles: (([URL], URL?) -> Void)?
    var onFailedURLs: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        let promisedTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL] + promisedTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canReadDrop(sender) else { return [] }
        onTargetedChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadDrop(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetedChanged?(false)
        let pasteboard = sender.draggingPasteboard
        var handled = false

        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let nsURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: urlOptions) as? [NSURL],
           !nsURLs.isEmpty {
            handled = true
            admitUserSelected(urls: nsURLs.map { $0 as URL })
        }

        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            handled = true
            receivePromisedFiles(receivers)
        }

        return handled
    }

    private func canReadDrop(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: urlOptions) {
            return true
        }
        return pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    private func admitUserSelected(urls: [URL]) {
        var inputs: [FileViewModel.UserSelectedInput] = []
        var failures: [URL] = []

        for url in urls {
            do {
                let bookmarkData = try FileItem.makeSecurityScopedBookmark(for: url)
                inputs.append(FileViewModel.UserSelectedInput(url: url, bookmarkData: bookmarkData))
            } catch {
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let bookmarkData = try FileItem.makeSecurityScopedBookmark(for: url)
                    inputs.append(FileViewModel.UserSelectedInput(url: url, bookmarkData: bookmarkData))
                } catch {
                    failures.append(url)
                }
            }
        }

        if !inputs.isEmpty {
            DispatchQueue.main.async { [onUserSelectedInputs] in
                onUserSelectedInputs?(inputs)
            }
        }
        if !failures.isEmpty {
            DispatchQueue.main.async { [onFailedURLs] in
                onFailedURLs?(failures)
            }
        }
    }

    private func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        let stagingRoot = (try? TempFileManager.shared.createTempDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MarcryptTemp").appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: nil)

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: stagingRoot, options: [:], operationQueue: .main) { fileURL, error in
                if error == nil {
                    lock.lock()
                    urls.append(fileURL)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [onPromisedFiles] in
            onPromisedFiles?(urls, stagingRoot)
        }
    }
}

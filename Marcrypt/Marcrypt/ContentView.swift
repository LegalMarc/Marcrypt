//
//  ContentView.swift
//  Marcrypt
//
//  Fixed:   • status-spinner now updates correctly
//           • state moved to a single `ViewModel` (ObservableObject)
//           • no more value-type copies losing their status
//           • Added PDF encryption functionality
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Foundation
import AppKit
import Combine

// --- Custom Color Palette (Modeled after Marcompare) ---
struct CustomColors {
    // Using NSColor initializers for precise HSB control on macOS
    // A - Main window background color
    static let appBackground = Color(NSColor(calibratedHue: 0.58, saturation: 0.04, brightness: 0.98, alpha: 1.0)) // Very light, slightly cool off-white/gray
    
    // C - Background for input areas and primary cards
    static let contentBackground = Color(NSColor(calibratedHue: 0.58, saturation: 0.07, brightness: 0.93, alpha: 1.0)) // Light muted teal-ish gray for drop zones

    // B - Color for primary action buttons, links, and highlights
    static let accentColor = Color(NSColor(calibratedHue: 0.53, saturation: 0.60, brightness: 0.68, alpha: 1.0)) // Soothing teal
    
    // New color for destructive actions like "Clear" or "Delete"
    static let destructiveColor = Color(NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1.0))
    
    // Standard text colors for adaptivity
    static let primaryText = Color(NSColor.labelColor)
    static let secondaryText = Color(NSColor.secondaryLabelColor)
    
    // UI element colors
    static let shadow = Color.black.opacity(0.12)
    static let subtleBorder = Color.black.opacity(0.1)
    
    // Background for secondary cards like file list items
    static let cardBackground = Color(NSColor.windowBackgroundColor) // Adaptive white/off-white
}

// MARK: - Data Models
@MainActor
final class FileItem: Identifiable, ObservableObject, Sendable {
    let id   = UUID()
    let url  : URL
    @Published var status: ProcessingStatus = .checking
    @Published var errorMessage: String?     = nil
    var decryptedDocument: PDFDocument?     = nil
    
    init(url: URL) { self.url = url }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum EncryptionFlowStep: Equatable {
    case idle
    case destinationSelected(URL)
    case encrypting(URL) 
    case retryPassword(URL)
    case destinationUnavailable
    
    var showsPasswordDialog: Bool {
        switch self {
        case .destinationSelected, .retryPassword:
            return true
        case .idle, .encrypting, .destinationUnavailable:
            return false
        }
    }
    
    var isRetryFlow: Bool {
        switch self {
        case .retryPassword:
            return true
        case .idle, .destinationSelected, .encrypting, .destinationUnavailable:
            return false
        }
    }
    
    var isEncrypting: Bool {
        switch self {
        case .encrypting:
            return true
        case .idle, .destinationSelected, .retryPassword, .destinationUnavailable:
            return false
        }
    }
    
    var destinationURL: URL? {
        switch self {
        case .destinationSelected(let url), .encrypting(let url), .retryPassword(let url):
            return url
        case .idle, .destinationUnavailable:
            return nil
        }
    }
}

enum ProcessingStatus: Sendable {
    case checking, encrypted, notEncrypted, corrupted, decrypted, decryptionFailed, encryptionSucceeded, encryptionFailed, processing
}

// MARK: - Central View-Model
@MainActor
final class FileViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var hasEncrypted: Bool = false
    @Published var hasUnencrypted: Bool = false
    
    // add files, avoid duplicates, and start async status-check
    @MainActor
    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = FileItem(url: url)
            items.append(item)
            Task { await checkStatus(for: item) }
        }
        updateButtonStates()
    }
    
    // async check: encrypted / notEncrypted / corrupted
    @MainActor
    private func checkStatus(for item: FileItem) async {
        // Perform the check on a background thread
        let (status, errorMessage) = await withCheckedContinuation { (continuation: CheckedContinuation<(ProcessingStatus, String?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async(execute: {
                // First try without security scoped access (for files opened via browser)
                if let pdf = PDFDocument(url: item.url) {
                    continuation.resume(returning: (pdf.isEncrypted ? .encrypted : .notEncrypted, nil))
                    return
                }
                
                // If that fails, try with security scoped access (for dropped files)
                guard item.url.startAccessingSecurityScopedResource() else {
                    // If we can't access the file at all, it might be corrupted or permission denied
                    continuation.resume(returning: (.corrupted, "Cannot access file - may be corrupted or permission denied."))
                    return
                }
                defer { item.url.stopAccessingSecurityScopedResource() }
                
                guard let pdf = PDFDocument(url: item.url) else {
                    continuation.resume(returning: (.corrupted, "File could not be read - may be corrupted or not a valid PDF."))
                    return
                }
                continuation.resume(returning: (pdf.isEncrypted ? .encrypted : .notEncrypted, nil))
            })
        }
        
        // Update on main actor
        update(item, status, errorMessage)
    }
    
    // helper: mutate on main-thread
    @MainActor
    private func update(_ item: FileItem, _ status: ProcessingStatus, _ msg: String?) {
        // Clear decrypted document if status is changing away from .decrypted
        if item.status == .decrypted && status != .decrypted {
            item.decryptedDocument = nil
        }
        
        item.status       = status
        item.errorMessage = msg
        updateButtonStates()
    }
    
    // decrypt all encrypted items - first decrypt in memory, then save if any succeeded
    @MainActor
    func decryptAll(with password: String, completion: @escaping (Bool, Bool) -> Void) {
        Task { @MainActor in
            // Get items that are encrypted OR previously failed (for retry)
            let decryptableItems = self.items.filter { $0.status == .encrypted || $0.status == .decryptionFailed }
            
            guard !decryptableItems.isEmpty else {
                completion(false, false)
                return
            }
            
            // Process each item and collect results
            var results: [(success: Bool, item: FileItem)] = []
            
            for item in decryptableItems {
                let result = await self.processDecryption(for: item, password: password)
                results.append(result)
            }
            
            // Analyze results
            let successCount = results.filter { $0.success }.count
            let totalDecryptable = decryptableItems.count
            
            completion(successCount > 0, totalDecryptable > 0 && successCount == 0)
        }
    }
    
    // Process single item decryption
    @MainActor
    private func processDecryption(for item: FileItem, password: String) async -> (success: Bool, item: FileItem) {
        // Perform the heavy work on a background thread
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, PDFDocument?, String?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async(execute: {
                // First try without security scoped access (for files opened via browser)
                if let doc = PDFDocument(url: item.url) {
                    if doc.unlock(withPassword: password) {
                        continuation.resume(returning: (true, doc, nil))
                        return
                    } else {
                        continuation.resume(returning: (false, nil, "Wrong password."))
                        return
                    }
                }
                
                // If that fails, try with security scoped access (for dropped files)
                guard item.url.startAccessingSecurityScopedResource() else {
                    continuation.resume(returning: (false, nil, "Permission denied to access file."))
                    return
                }
                defer { item.url.stopAccessingSecurityScopedResource() }
                
                guard let doc = PDFDocument(url: item.url) else {
                    continuation.resume(returning: (false, nil, "File could not be read or is corrupted."))
                    return
                }
                
                guard doc.unlock(withPassword: password) else {
                    continuation.resume(returning: (false, nil, "Wrong password."))
                    return
                }
                
                // Successfully decrypted
                continuation.resume(returning: (true, doc, nil))
            })
        }
        
        // Update UI on main actor
        if result.0 {
            // Success
            item.decryptedDocument = result.1
            self.update(item, .decrypted, nil)
            return (true, item)
        } else {
            // Failure
            self.update(item, .decryptionFailed, result.2 ?? "Unknown error")
            return (false, item)
        }
    }
    
    // Save successfully decrypted files to destination
    @MainActor
    func saveDecryptedFiles(to destination: URL) {
        Task { @MainActor in
            // Try to access destination (should work since user selected it)
            let hasAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    destination.stopAccessingSecurityScopedResource()
                }
            }
            
            // Get successfully decrypted items
            let decryptedItems = self.items.filter { $0.status == .decrypted && $0.decryptedDocument != nil }
            
            for item in decryptedItems {
                guard let doc = item.decryptedDocument else { continue }
                
                let outName = item.url.lastPathComponent
                let outURL = destination.appendingPathComponent(outName)
                
                if !doc.write(to: outURL) {
                    self.update(item, .decryptionFailed, "Failed to write decrypted file to destination.")
                } else {
                    // Clear the decrypted document from memory immediately after successful save
                    item.decryptedDocument = nil
                }
            }
        }
    }
    
    // MARK: - Encryption Logic
    
    /*
     PDF Encryption & Permissions Model:
     
     Current Implementation:
     - User Password: Required to open/view the document
     - Owner Password: Set to same value as user password
     - Result: Anyone who can decrypt gets FULL permissions (print, copy, edit, annotate)
     
     This is the most intuitive behavior for most users. If you can decrypt the file,
     you should be able to do everything with it.
     
     Future Enhancement Possibility:
     - Add advanced permissions UI to set different owner password
     - Allow restricting printing, copying, editing permissions
     - Would require additional UI complexity and user education
     
     Memory Optimization Notes:
     - Encryption: Reads → processes → writes directly (minimal memory footprint)
     - Decryption: Currently stores PDFDocument in memory, but clears after save
     - For very large files: Could implement streaming approach to avoid loading entire PDF
     */
    
    // Main encryption function
    @MainActor
    func encryptAll(with password: String, to destination: URL, completion: @escaping (Bool, [String]) -> Void) async {
        // Filter for files that can be encrypted (not corrupted, not already encrypted)
        let encryptableItems = self.items.filter { $0.status == .notEncrypted }
        
        guard !encryptableItems.isEmpty else {
            completion(false, [])
            return
        }
        
        // Set all files to processing state
        for item in encryptableItems {
            self.update(item, .processing, nil)
        }
        
        // Start security access for the destination directory
        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                destination.stopAccessingSecurityScopedResource()
            }
        }
        
        var results: [(success: Bool, item: FileItem, failureReason: String?)] = []
        
        for item in encryptableItems {
            // Check for cancellation before processing each file
            if Task.isCancelled {
                // Reset remaining files to their original state
                for remainingItem in encryptableItems where !results.contains(where: { $0.item.id == remainingItem.id }) {
                    self.update(remainingItem, .notEncrypted, nil)
                }
                completion(false, [])
                return
            }
            
            let result = await self.processEncryption(for: item, password: password, destination: destination)
            results.append(result)
        }
        
        let successCount = results.filter { $0.success }.count
        let failedFiles = results.filter { !$0.success }.map { $0.item.url.lastPathComponent }
        
        completion(successCount > 0, failedFiles)
    }
    
    // Process single file encryption
    @MainActor
    private func processEncryption(for item: FileItem, password: String, destination: URL) async -> (success: Bool, item: FileItem, failureReason: String?) {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async(execute: {
                // Try without security scoped access first
                if let doc = PDFDocument(url: item.url) {
                    let outputURL = self.generateUniqueURL(for: item.url.lastPathComponent, in: destination)
                    
                    // Create properly-typed options dictionary
                    let writeOptions: [PDFDocumentWriteOption : Any] = [
                        .userPasswordOption: password,
                        .ownerPasswordOption: password // Same password = full permissions after decryption
                    ]
                    
                    if doc.write(to: outputURL, withOptions: writeOptions) {
                        continuation.resume(returning: (true, nil))
                    } else {
                        continuation.resume(returning: (false, "Failed to write encrypted file."))
                    }
                    return
                }
                
                // Try with security scoped access
                guard item.url.startAccessingSecurityScopedResource() else {
                    continuation.resume(returning: (false, "Permission denied to access file."))
                    return
                }
                defer { item.url.stopAccessingSecurityScopedResource() }
                
                guard let doc = PDFDocument(url: item.url) else {
                    continuation.resume(returning: (false, "File could not be read."))
                    return
                }
                
                let outputURL = self.generateUniqueURL(for: item.url.lastPathComponent, in: destination)
                
                // Create properly-typed options dictionary
                // Note: Setting same password for both user and owner gives full permissions to anyone who can decrypt
                let writeOptions: [PDFDocumentWriteOption : Any] = [
                    .userPasswordOption: password,
                    .ownerPasswordOption: password // Same password = full permissions after decryption
                ]
                
                if doc.write(to: outputURL, withOptions: writeOptions) {
                    continuation.resume(returning: (true, nil))
                } else {
                    continuation.resume(returning: (false, "Failed to write encrypted file."))
                }
            })
        }
        
        // Update UI on main actor
        if result.0 {
            self.update(item, .encryptionSucceeded, nil)
            return (true, item, nil)
        } else {
            self.update(item, .encryptionFailed, result.1)
            return (false, item, result.1)
        }
    }
    
    // Generate unique filename using macOS collision handling
    private func generateUniqueURL(for filename: String, in directory: URL) -> URL {
        let baseURL = directory.appendingPathComponent(filename)
        
        // Check if file exists
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        
        // Generate unique name
        let nameWithoutExtension = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension
        
        var counter = 1
        while true {
            let newName = "\(nameWithoutExtension) (\(counter)).\(fileExtension)"
            let newURL = directory.appendingPathComponent(newName)
            
            if !FileManager.default.fileExists(atPath: newURL.path) {
                return newURL
            }
            counter += 1
        }
    }
    
    // MARK: - State Management
    
    @MainActor
    private func updateButtonStates() {
        hasEncrypted = items.contains { item in
            item.status == .encrypted || item.status == .decryptionFailed
        }
        hasUnencrypted = items.contains { item in
            item.status == .notEncrypted
        }
    }
    
    @MainActor
    var hasFiles: Bool {
        !items.isEmpty
    }
    
    @MainActor
    func clearAllFiles() {
        // Clear any decrypted documents from memory before removing items
        for item in items {
            item.decryptedDocument = nil
        }
        items.removeAll()
        updateButtonStates()
    }
    
    @MainActor
    func resetProcessingFiles() {
        for item in items where item.status == .processing {
            update(item, .notEncrypted, nil)
        }
    }
}

// MARK: - Window Background Helper
struct WindowBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.backgroundColor = NSColor(CustomColors.appBackground)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            window.backgroundColor = NSColor(CustomColors.appBackground)
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var vm = FileViewModel()
    @State private var password = ""
    @State private var showPwdPrompt = false
    @State private var showPasswordRetryPrompt = false
    @State private var alertItem: FileItem?
    @State private var isTargeted = false
    
    // Encryption state
    @State private var encryptPassword = ""
    @State private var encryptPasswordConfirm = ""
    @State private var showPasswordText = false
    @State private var preflightAlertInfo: (title: String, message: String)?
    @State private var currentEncryptionTask: Task<Void, Never>?
    @State private var encryptionFlow: EncryptionFlowStep = .idle
    
    var body: some View {
        VStack(spacing: 24) {
            // Drop zone directly in main layout
            dropZone
            
            FileListView(vm: vm, alertItem: $alertItem)
                .frame(maxHeight: .infinity) // Allow FileListView to expand vertically
            
            actionButtons
            FooterView()
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 620) // Set minimum size to show 3.5 file rows
        .background(CustomColors.appBackground.ignoresSafeArea())
        .background(WindowBackgroundView().opacity(0))
        .alert("Enter PDF Password", isPresented: $showPwdPrompt) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { 
                password = ""
            }
            Button("Decrypt") { attemptDecryption() }
        } message: {
            Text("Please enter the password for the encrypted PDF files.")
        }
        .alert("Decryption Failed - Try Different Password", isPresented: $showPasswordRetryPrompt) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { 
                password = ""
            }
            Button("Try Again") { attemptDecryption() }
        } message: {
            Text("Some or all files failed to decrypt. Please try a different password or cancel to stop.")
        }
        .sheet(isPresented: .constant(encryptionFlow.showsPasswordDialog)) {
            EncryptPasswordDialog(
                password: $encryptPassword,
                passwordConfirm: $encryptPasswordConfirm,
                showPasswordText: $showPasswordText,
                isRetry: encryptionFlow.isRetryFlow,
                onCancel: {
                    clearMainPasswords()
                    encryptionFlow = .idle
                },
                onEncrypt: {
                    attemptEncryption()
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
        .alert(item: Binding<AlertInfo?>(
            get: { preflightAlertInfo.map { AlertInfo(title: $0.title, message: $0.message) } },
            set: { _ in preflightAlertInfo = nil }
        )) { info in
            Alert(title: Text(info.title),
                  message: Text(info.message),
                  dismissButton: .default(Text("OK")))
        }
        .onChange(of: encryptionFlow) { _, newFlow in
            handleFlowStateChange(newFlow)
        }
    }

    
    // MARK: UI Helpers
    private var dropZone: some View {
        VStack(spacing: 0) {
            // Drop area with contentBackground
            VStack(spacing: 18) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(CustomColors.secondaryText)

                Text("Drag & Drop .pdf files here")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(CustomColors.contentBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isTargeted ? CustomColors.accentColor : CustomColors.subtleBorder.opacity(0.2),
                        style: StrokeStyle(lineWidth: 2.5, dash: isTargeted ? [] : [8, 4])
                    )
                    .animation(.easeInOut(duration: 0.2), value: isTargeted)
            )
            .scaleEffect(isTargeted ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
            .padding([.horizontal, .top], 20)
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                DispatchQueue.main.async {
                                    vm.add(urls: [url])
                                }
                            }
                        }
                    }
                }
                return true
            }

            // Browse button bar
            HStack {
                Button(action: { openPanel() }) {
                    Text("Browse...")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .tint(CustomColors.accentColor)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
            }
            .padding(20)
        }
        .background(CustomColors.cardBackground)
        .cornerRadius(16)
        .shadow(color: CustomColors.shadow, radius: 8, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(CustomColors.subtleBorder.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.pdf]
        if panel.runModal() == .OK {
            vm.add(urls: panel.urls)
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
                            .fill(CustomColors.destructiveColor)
                            .shadow(color: CustomColors.destructiveColor.opacity(0.2), radius: 6, y: 3)
                    )
                }
                .buttonStyle(.plain)
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
                            .fill(vm.hasUnencrypted ? CustomColors.accentColor : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                            .shadow(color: vm.hasUnencrypted ? CustomColors.accentColor.opacity(0.2) : Color.clear, radius: 6, y: 3)
                    )
                }
                .disabled(!vm.hasUnencrypted)
                .buttonStyle(.plain)
                .scaleEffect(vm.hasUnencrypted ? 1.0 : 0.98)
                .animation(.easeInOut(duration: 0.2), value: vm.hasUnencrypted)
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
                        .fill(vm.hasEncrypted ? CustomColors.accentColor : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                        .shadow(color: vm.hasEncrypted ? CustomColors.accentColor.opacity(0.2) : Color.clear, radius: 6, y: 3)
                )
            }
            .disabled(!vm.hasEncrypted)
            .buttonStyle(.plain)
            .scaleEffect(vm.hasEncrypted ? 1.0 : 0.98)
            .animation(.easeInOut(duration: 0.2), value: vm.hasEncrypted)

            // Clear Files Button
            Button(action: {
                vm.clearAllFiles()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Clear Files")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(vm.hasFiles ? CustomColors.destructiveColor : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                        .shadow(color: vm.hasFiles ? CustomColors.destructiveColor.opacity(0.2) : Color.clear, radius: 6, y: 3)
                )
            }
            .disabled(!vm.hasFiles)
            .buttonStyle(.plain)
            .scaleEffect(vm.hasFiles ? 1.0 : 0.98)
            .animation(.easeInOut(duration: 0.2), value: vm.hasFiles)
        }
    }
    
    // MARK: - Encryption Flow
    
    /*
     Encryption Flow State Management:
     
     The encryption process follows a clean state machine pattern:
     
     .idle 
       ↓ (user clicks "Encrypt")
     .destinationSelected(URL) → shows password dialog
       ↓ (user enters password)
     .encrypting(URL) → shows processing indicators  
       ↓ (success/failure)
     .idle OR .retryPassword(URL)
     
     Error handling:
     - .destinationUnavailable → shows alert, returns to .idle
     - .retryPassword(URL) → shows retry dialog with same destination
     
     Benefits over previous approach:
     - No race conditions or arbitrary delays
     - Explicit state transitions  
     - Single source of truth for flow state
     - Easy to reason about and debug
     */
    
    private func startEncryptionProcess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose a folder to save the encrypted PDF files"
        panel.prompt = "Save Here"
        
        if panel.runModal() == .OK, let dest = panel.url {
            // Pre-flight checks before showing password dialog
            
            // 1. Check destination write permissions
            guard verifyDestinationIsWritable(url: dest) else {
                preflightAlertInfo = (
                    title: "Destination Not Writable",
                    message: "You do not have permission to save files to the chosen location. Please select a different folder."
                )
                return
            }
            
            // 2. Check for sufficient disk space
            guard verifySufficientDiskSpace(for: vm.items, at: dest) else {
                preflightAlertInfo = (
                    title: "Insufficient Disk Space",
                    message: "There may not be enough free space on the destination drive to save the encrypted files. Please free up space or choose a different location."
                )
                return
            }
            
            // All checks passed, proceed to password dialog
            clearMainPasswords()
            showPasswordText = false
            encryptionFlow = .destinationSelected(dest)
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
            print("Destination verification failed: \(error.localizedDescription)")
            return false
        }
    }
    
    private func verifySufficientDiskSpace(for items: [FileItem], at destination: URL) -> Bool {
        do {
            // Get the total size of all files that will be encrypted
            let filesToEncrypt = items.filter { $0.status == .notEncrypted }
            let totalSize = try filesToEncrypt.reduce(0) { (sum, item) -> Int64 in
                let attributes = try FileManager.default.attributesOfItem(atPath: item.url.path)
                return sum + (attributes[.size] as? Int64 ?? 0)
            }
            
            // Get available space on the destination volume
            let resourceValues = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let freeSpace = resourceValues.volumeAvailableCapacityForImportantUsage {
                // Add some buffer (10% or 100MB, whichever is smaller) to account for overhead
                let buffer = min(Int64(totalSize / 10), 100 * 1024 * 1024)
                return (totalSize + buffer) <= freeSpace
            }
            
            // If we can't get free space info, proceed but warn in console
            print("Could not verify disk space - proceeding anyway")
            return true
            
        } catch {
            // Failed to get file sizes or free space; proceed but log warning
            print("Could not verify disk space: \(error.localizedDescription)")
            return true
        }
    }
    
    private func attemptEncryption() {
        guard !encryptPassword.isEmpty, encryptPassword == encryptPasswordConfirm else { return }
        guard let destination = encryptionFlow.destinationURL else { return }
        
        // Check if destination is still available
        if !FileManager.default.fileExists(atPath: destination.path) {
            // Transition to destination unavailable state - this will trigger re-selection
            encryptionFlow = .destinationUnavailable
            return
        }
        
        // Start encryption with cancellation support
        encryptionFlow = .encrypting(destination)
        let passwordCopy = encryptPassword // Capture password for async context
        
        currentEncryptionTask = Task {
            await vm.encryptAll(with: passwordCopy, to: destination) { success, failedFiles in
                Task { @MainActor in
                    // Secure password cleanup
                    clearMainPasswords()
                    currentEncryptionTask = nil
                    
                    if success {
                        // Encryption succeeded, return to idle
                        encryptionFlow = .idle
                    } else {
                        // All files failed, show retry dialog
                        encryptionFlow = .retryPassword(destination)
                    }
                }
            }
        }
    }
    
    private func stopEncryption() {
        currentEncryptionTask?.cancel()
        currentEncryptionTask = nil
        
        // Reset any files that were in processing state
        vm.resetProcessingFiles()
        
        // Secure password cleanup and return to idle
        clearMainPasswords()
        encryptionFlow = .idle
    }
    
    private func clearMainPasswords() {
        // Zero out password memory
        encryptPassword = ""
        encryptPasswordConfirm = ""
    }
    
    private func handleFlowStateChange(_ newFlow: EncryptionFlowStep) {
        switch newFlow {
        case .destinationUnavailable:
            // Show alert and offer to re-select destination
            preflightAlertInfo = (
                title: "Destination No Longer Available",
                message: "The originally chosen directory is no longer available. Please select a new location."
            )
            // After user dismisses the alert, they can manually restart the process
            encryptionFlow = .idle
            
        case .idle, .destinationSelected, .encrypting, .retryPassword:
            // These states are handled by their respective UI components
            break
        }
    }
    
    // MARK: - Decryption Flow
    
    private func attemptDecryption() {
        guard !password.isEmpty else { return }
        
        vm.decryptAll(with: password) { anySucceeded, allFailed in
            if anySucceeded {
                // Some files succeeded, show save dialog
                self.chooseSaveDestination()
                // Reset password prompts since we're done
                self.showPwdPrompt = false
                self.showPasswordRetryPrompt = false
            } else if allFailed {
                // All files failed, show retry dialog (infinite retries until cancel)
                self.showPwdPrompt = false
                self.showPasswordRetryPrompt = true
            } else {
                // No decryptable files
                // This shouldn't happen since button is disabled when no decryptable files
                self.showPwdPrompt = false
                self.showPasswordRetryPrompt = false
            }
        }
    }
    
    private func chooseSaveDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to save the decrypted PDF files"
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let dest = panel.url {
            vm.saveDecryptedFiles(to: dest)
        }
    }
}

// MARK: - File List
struct FileListView: View {
    @ObservedObject var vm: FileViewModel
    @Binding var alertItem: FileItem?
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(vm.items) { item in
                    FileRow(item: item)
                        .onTapGesture { handleTap(on: item) }
                        .animation(.easeInOut(duration: 0.2), value: item.status)
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollContentBackground(.hidden) // <-- ADD THIS MODIFIER
    }
    
    private func handleTap(on item: FileItem) {
        switch item.status {
        case .decryptionFailed, .encryptionFailed, .corrupted: 
            alertItem = item
        case .notEncrypted:
            let info = FileItem(url: item.url)
            info.status = .notEncrypted
            info.errorMessage = "This file is a valid PDF but is not encrypted, so no action is needed."
            alertItem = info
        default: break
        }
    }
}

// single row
struct FileRow: View {
    @ObservedObject var item: FileItem
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(CustomColors.accentColor) // Use accent color
                .frame(width: 24, height: 24)
            
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(CustomColors.primaryText) // Use primary text color
            
            Spacer(minLength: 12)
            
            StatusView(status: item.status)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CustomColors.cardBackground) // Use the new adaptive card background
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(CustomColors.subtleBorder, lineWidth: 1) // Use subtle border
        )
    }
}

// status widget
struct StatusView: View {
    let status: ProcessingStatus
    
    var body: some View {
        Group {
            switch status {
            case .checking:         
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            case .encrypted:        
                Text("[Encrypted]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(CustomColors.destructiveColor)
                    )
            case .notEncrypted:     
                Text("[Not Encrypted]")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.secondaryText.opacity(0.1))
                    )
            case .corrupted:        
                Text("[Corrupted]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.destructiveColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.destructiveColor.opacity(0.1))
                    )
            case .decrypted:        
                Text("[Decryption Succeeded]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.accentColor.opacity(0.15))
                    )
            case .decryptionFailed: 
                Text("[Decryption Failed]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.destructiveColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.destructiveColor.opacity(0.1))
                    )
            case .encryptionSucceeded:
                Text("[Encryption Succeeded]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.accentColor.opacity(0.15))
                    )
            case .encryptionFailed:
                Text("[Encryption Failed]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.destructiveColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.destructiveColor.opacity(0.1))
                    )
            case .processing:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 12, height: 12)
                    Text("[Processing...]")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(CustomColors.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CustomColors.accentColor.opacity(0.1))
                )
            }
        }
        .transition(.opacity.combined(with: .scale))
    }
}

// footer
struct FooterView: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("Released by Marc Mandel under the MIT license at ")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText)
                Text("github.com/LegalMarc/Marcrypt")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.accentColor) // Use accent color for links
            }
            .lineLimit(1)
            .truncationMode(.tail)
            
            HStack(spacing: 0) {
                Text("Got bugs? Message me at ")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText)
                Text("linkedin.com/in/marcmandel/")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.accentColor) // Use accent color for links
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
}

// MARK: - Encrypt Password Dialog
struct EncryptPasswordDialog: View {
    @Binding var password: String
    @Binding var passwordConfirm: String
    @Binding var showPasswordText: Bool
    let isRetry: Bool
    let onCancel: () -> Void
    let onEncrypt: () -> Void
    
    // Local secure password storage
    @State private var localPassword = ""
    @State private var localPasswordConfirm = ""
    @State private var localShowPasswordText = false
    
    private func calculatePasswordEntropy(_ password: String) -> Double {
        guard !password.isEmpty else { return 0.0 }
        
        var characterSets: Set<Character> = []
        var poolSize = 0
        
        let lowercase = CharacterSet.lowercaseLetters
        let uppercase = CharacterSet.uppercaseLetters
        let digits = CharacterSet.decimalDigits
        let symbols = CharacterSet.punctuationCharacters.union(CharacterSet.symbols)
        
        for char in password {
            let scalar = char.unicodeScalars.first!
            if lowercase.contains(scalar) {
                characterSets.insert("a")
            } else if uppercase.contains(scalar) {
                characterSets.insert("A")
            } else if digits.contains(scalar) {
                characterSets.insert("0")
            } else if symbols.contains(scalar) {
                characterSets.insert("!")
            }
        }
        
        if characterSets.contains("a") { poolSize += 26 }
        if characterSets.contains("A") { poolSize += 26 }
        if characterSets.contains("0") { poolSize += 10 }
        if characterSets.contains("!") { poolSize += 32 }
        
        // Prevent log2 crashes with invalid pool sizes
        guard poolSize > 1 else { return 0.0 }
        
        return log2(Double(poolSize)) * Double(password.count)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text(isRetry ? "Encryption Failed - Try Different Password" : "Set Encryption Password")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(CustomColors.primaryText)
                
                Text(isRetry ? "Some or all files failed to encrypt. Please try a different password or cancel to stop." : "Enter a password to encrypt the PDF files. The same password will be applied to all files.")
                    .font(.body)
                    .foregroundColor(CustomColors.secondaryText)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                // Password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.headline)
                        .foregroundColor(CustomColors.primaryText)
                    
                                         HStack {
                         if localShowPasswordText {
                             TextField("Enter password", text: $localPassword)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         } else {
                             SecureField("Enter password", text: $localPassword)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         }
                         
                         Button(action: { localShowPasswordText.toggle() }) {
                             Image(systemName: localShowPasswordText ? "eye.slash" : "eye")
                                 .foregroundColor(CustomColors.accentColor)
                         }
                         .buttonStyle(.plain)
                     }
                }
                
                // Confirm password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm Password")
                        .font(.headline)
                        .foregroundColor(CustomColors.primaryText)
                    
                                         HStack {
                         if localShowPasswordText {
                             TextField("Confirm password", text: $localPasswordConfirm)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         } else {
                             SecureField("Confirm password", text: $localPasswordConfirm)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         }
                     }
                }
                
                                 // Password strength meter
                 let entropy = calculatePasswordEntropy(localPassword)
                 
                 VStack(alignment: .leading, spacing: 8) {
                     Text("Password Strength")
                         .font(.headline)
                         .foregroundColor(CustomColors.primaryText)
                     
                     HStack(spacing: 4) {
                         ForEach(0..<4, id: \.self) { index in
                             let thresholds: [Double] = [40, 60, 120, 200]
                             RoundedRectangle(cornerRadius: 2)
                                 .fill(entropy >= thresholds[index] ? CustomColors.accentColor : Color.gray.opacity(0.3))
                                 .frame(height: 8)
                         }
                     }
                     
                     HStack {
                         Text("Poor")
                             .font(.caption2)
                         Spacer()
                         Text("Not Great")
                             .font(.caption2)
                         Spacer()
                         Text("Good")
                             .font(.caption2)
                         Spacer()
                         Text("Excellent")
                             .font(.caption2)
                     }
                     .foregroundColor(CustomColors.secondaryText)
                     
                     Text("\(Int(entropy)) bits of entropy")
                         .font(.caption)
                         .foregroundColor(CustomColors.secondaryText)
                 }
            }
            
                         // Buttons
             HStack(spacing: 12) {
                 Button("Cancel") {
                     // Secure cleanup before canceling
                     clearPasswords()
                     onCancel()
                 }
                 .buttonStyle(.bordered)
                 .controlSize(.large)
                 .tint(CustomColors.destructiveColor)
                 
                 Button(isRetry ? "Try Again" : "Encrypt") {
                     // Sync passwords and encrypt
                     password = localPassword
                     passwordConfirm = localPasswordConfirm
                     showPasswordText = localShowPasswordText
                     onEncrypt()
                     
                     // Clear local passwords after use
                     clearPasswords()
                 }
                 .buttonStyle(.borderedProminent)
                 .controlSize(.large)
                 .tint(CustomColors.accentColor)
                 .disabled(localPassword.isEmpty || localPassword != localPasswordConfirm)
             }
        }
        .padding(32)
        .frame(maxWidth: 500)
        .background(CustomColors.cardBackground)
        .cornerRadius(16)
        .shadow(color: CustomColors.shadow, radius: 20, x: 0, y: 10)
        .onAppear {
            // Initialize with existing values if any
            localPassword = password
            localPasswordConfirm = passwordConfirm
            localShowPasswordText = showPasswordText
        }
        .onDisappear {
            // Secure cleanup when dialog is dismissed
            clearPasswords()
        }
    }
    
    private func clearPasswords() {
        // Zero out password memory
        localPassword = ""
        localPasswordConfirm = ""
        localShowPasswordText = false
    }
}

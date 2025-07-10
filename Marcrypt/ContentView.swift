//
//  ContentView.swift
//  Marcrypt
//
//  Fixed:   • status-spinner now updates correctly
//           • state moved to a single `ViewModel` (ObservableObject)
//           • no more value-type copies losing their status
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Foundation
import AppKit
import Combine

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

enum ProcessingStatus: Sendable {
    case checking, encrypted, notEncrypted, corrupted, decrypted, decryptionFailed
}

// MARK: - Central View-Model
@MainActor
final class FileViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    
    // add files, avoid duplicates, and start async status-check
    @MainActor
    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = FileItem(url: url)
            items.append(item)
            Task { await checkStatus(for: item) }
        }
    }
    
    // async check: encrypted / notEncrypted / corrupted
    @MainActor
    private func checkStatus(for item: FileItem) async {
        // Perform the check on a background thread
        let (status, errorMessage) = await withCheckedContinuation { (continuation: CheckedContinuation<(ProcessingStatus, String?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
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
            }
        }
        
        // Update on main actor
        update(item, status, errorMessage)
    }
    
    // helper: mutate on main-thread
    @MainActor
    private func update(_ item: FileItem, _ status: ProcessingStatus, _ msg: String?) {
        item.status       = status
        item.errorMessage = msg
    }
    
    // decrypt all encrypted items - first decrypt in memory, then save if any succeeded
    @MainActor
    func decryptAll(with password: String, completion: @escaping (Bool, Bool) -> Void) {
        Task { @MainActor in
            // Only get items that are currently in "encrypted" status (not previously processed)
            let encryptedItems = self.items.filter { $0.status == .encrypted }
            
            guard !encryptedItems.isEmpty else {
                completion(false, false)
                return
            }
            
            // Process each item and collect results
            var results: [(success: Bool, item: FileItem)] = []
            
            for item in encryptedItems {
                let result = await self.processDecryption(for: item, password: password)
                results.append(result)
            }
            
            // Analyze results
            let successCount = results.filter { $0.success }.count
            let totalEncrypted = encryptedItems.count
            
            completion(successCount > 0, totalEncrypted > 0 && successCount == 0)
        }
    }
    
    // Process single item decryption
    @MainActor
    private func processDecryption(for item: FileItem, password: String) async -> (success: Bool, item: FileItem) {
        // Perform the heavy work on a background thread
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, PDFDocument?, String?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
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
            }
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
            if hasAccess {
                defer { destination.stopAccessingSecurityScopedResource() }
            }
            
            // Get successfully decrypted items
            let decryptedItems = self.items.filter { $0.status == .decrypted && $0.decryptedDocument != nil }
            
            for item in decryptedItems {
                guard let doc = item.decryptedDocument else { continue }
                
                let outName = item.url.deletingPathExtension().lastPathComponent + " (no crypt).pdf"
                let outURL = destination.appendingPathComponent(outName)
                
                if !doc.write(to: outURL) {
                    self.update(item, .decryptionFailed, "Failed to write decrypted file to destination.")
                }
            }
        }
    }
    

    
    @MainActor
    var hasEncrypted: Bool { 
        items.contains { item in
            item.status == .encrypted
        } 
    }
    
    @MainActor
    var hasFiles: Bool {
        !items.isEmpty
    }
    
    @MainActor
    func clearAllFiles() {
        items.removeAll()
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var vm = FileViewModel()
    @State private var password = ""
    @State private var showPwdPrompt = false
    @State private var showPasswordRetryPrompt = false
    @State private var alertItem: FileItem?
    
    var body: some View {
        VStack(spacing: 24) {
            InputCardView(vm: vm)
            FileListView(vm: vm, alertItem: $alertItem)
            Spacer()
            actionButtons
            FooterView()
        }
        .padding(24)
        .frame(width: 580, height: 650)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
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
            Text("All encrypted files failed to decrypt. Please try a different password or cancel to stop.")
        }
        .alert(item: $alertItem) { item in
            let title: String
            let message: String
            
            switch item.status {
            case .decryptionFailed:
                title = "Decryption Failed"
                message = item.errorMessage ?? "Unknown error occurred during decryption."
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
    }
    
    // MARK: UI Helpers
    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Decrypt Button
            Button {
                password = ""; showPwdPrompt = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Decrypt Encrypted File(s)")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
            }
            .disabled(!vm.hasEncrypted)
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(vm.hasEncrypted ? Color(red: 0.3, green: 0.6, blue: 0.7) : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                    .shadow(color: vm.hasEncrypted ? Color(red: 0.3, green: 0.6, blue: 0.7).opacity(0.2) : Color.clear, radius: 6, y: 3)
            )
            .foregroundColor(.white)
            .scaleEffect(vm.hasEncrypted ? 1.0 : 0.98)
            .animation(.easeInOut(duration: 0.2), value: vm.hasEncrypted)
            
            // Clear Files Button
            Button {
                vm.clearAllFiles()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Clear Files")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
            }
            .disabled(!vm.hasFiles)
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(vm.hasFiles ? Color(red: 0.8, green: 0.4, blue: 0.4) : Color(red: 0.7, green: 0.7, blue: 0.75).opacity(0.4))
                    .shadow(color: vm.hasFiles ? Color(red: 0.8, green: 0.4, blue: 0.4).opacity(0.2) : Color.clear, radius: 6, y: 3)
            )
            .foregroundColor(.white)
            .scaleEffect(vm.hasFiles ? 1.0 : 0.98)
            .animation(.easeInOut(duration: 0.2), value: vm.hasFiles)
        }
    }
    
    private func attemptDecryption() {
        guard !password.isEmpty else { return }
        
        vm.decryptAll(with: password) { anySucceeded, allFailed in
            if anySucceeded {
                // Some files succeeded, show save dialog
                self.chooseSaveDestination()
            } else if allFailed {
                // All files failed, show retry dialog
                self.showPasswordRetryPrompt = true
            } else {
                // No encrypted files to decrypt
                // This shouldn't happen since button is disabled when no encrypted files
            }
        }
    }
    
    private func chooseSaveDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            vm.saveDecryptedFiles(to: dest)
        }
    }
}

// MARK: - Input Card
// MARK: - Input Card (fixed async errors)
struct InputCardView: View {
    @ObservedObject var vm: FileViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            dropZone
            browseBar
        }
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 1)
        )
    }

    // ───────── Drag-&-Drop zone ─────────
    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))

            Text("Drag & Drop .pdf files here")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.95, green: 0.96, blue: 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color(red: 0.3, green: 0.6, blue: 0.7) : Color(red: 0.85, green: 0.85, blue: 0.85),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [8, 4])
                )
                .animation(.easeInOut(duration: 0.2), value: isTargeted)
        )
        .scaleEffect(isTargeted ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .padding([.horizontal, .top], 20)

        // ✅ FIX: drop-handler using proper file URL handling
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
    }

    // ───────── Browse… button ─────────
    private var browseBar: some View {
        HStack {
            Button("Browse...") { openPanel() }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.3, green: 0.6, blue: 0.7))
                        .shadow(color: Color(red: 0.3, green: 0.6, blue: 0.7).opacity(0.2), radius: 4, y: 2)
                )
                .foregroundColor(.white)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(20)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.pdf]
        if panel.runModal() == .OK {
            vm.add(urls: panel.urls)
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
    }
    
    private func handleTap(on item: FileItem) {
        switch item.status {
        case .decryptionFailed, .corrupted: 
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
                .foregroundColor(Color(red: 0.3, green: 0.6, blue: 0.7))
                .frame(width: 24, height: 24)
            
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
            
            Spacer(minLength: 12)
            
            StatusView(status: item.status)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 1)
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
                            .fill(Color(red: 0.8, green: 0.4, blue: 0.4))
                    )
            case .notEncrypted:     
                Text("[Not Encrypted]")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.5, green: 0.5, blue: 0.5).opacity(0.1))
                    )
            case .corrupted:        
                Text("[Corrupted]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.8, green: 0.4, blue: 0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.8, green: 0.4, blue: 0.4).opacity(0.1))
                    )
            case .decrypted:        
                Text("[Decryption Succeeded]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.3, green: 0.6, blue: 0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.3, green: 0.6, blue: 0.7).opacity(0.15))
                    )
            case .decryptionFailed: 
                Text("[Decryption Failed]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.8, green: 0.4, blue: 0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.8, green: 0.4, blue: 0.4).opacity(0.1))
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
            Text("Released by Marc Mandel under the MIT license at github.com/LegalMarc/Marcrypt")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("Got bugs? Message me at linkedin.com/in/marcmandel/")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
}

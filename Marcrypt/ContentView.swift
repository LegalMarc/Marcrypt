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
                guard item.url.startAccessingSecurityScopedResource() else {
                    continuation.resume(returning: (.corrupted, "Permission denied to access file."))
                    return
                }
                defer { item.url.stopAccessingSecurityScopedResource() }
                
                guard let pdf = PDFDocument(url: item.url) else {
                    continuation.resume(returning: (.corrupted, "This file could not be read and may be corrupted or not a valid PDF file."))
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
            // Get encrypted items
            let encryptedItems = self.items.filter { $0.status == .encrypted }
            
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
            guard destination.startAccessingSecurityScopedResource() else { return }
            defer { destination.stopAccessingSecurityScopedResource() }
            
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
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var vm = FileViewModel()
    @State private var password = ""
    @State private var showPwdPrompt = false
    @State private var showPasswordRetryPrompt = false
    @State private var alertItem: FileItem?
    
    var body: some View {
        VStack(spacing: 20) {
            InputCardView(vm: vm)
            FileListView(vm: vm, alertItem: $alertItem)
            Spacer()
            decryptButton
            FooterView()
        }
        .padding()
        .frame(width: 580, height: 650)
        .alert("Enter PDF Password", isPresented: $showPwdPrompt) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { }
            Button("Decrypt") { attemptDecryption() }
        } message: {
            Text("Please enter the password for the encrypted PDF files.")
        }
        .alert("Decryption Failed", isPresented: $showPasswordRetryPrompt) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { }
            Button("Try Again") { attemptDecryption() }
        } message: {
            Text("All encrypted files failed to decrypt. Please try a different password.")
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
    private var decryptButton: some View {
        Button {
            password = ""; showPwdPrompt = true
        } label: {
            Label("Decrypt Encrypted File(s)", systemImage: "bolt.fill")
                .frame(maxWidth: .infinity).padding()
        }
        .disabled(!vm.hasEncrypted)
        .buttonStyle(.plain)
        .background(vm.hasEncrypted ? Color("accentTeal")
                                    : Color("brandBlue").opacity(0.4))
        .foregroundColor(.white)
        .cornerRadius(10)
        .font(.system(.title3, design: .default).weight(.semibold))
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
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }

    // ───────── Drag-&-Drop zone ─────────
    private var dropZone: some View {
        VStack(spacing: 15) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundColor(Color("textSecondary"))

            Text("Drag & Drop .pdf files here")
                .font(.headline)
                .foregroundColor(Color("textSecondary"))
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Color("panelBlue"))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color("accentTeal")
                                         : Color("lineLight"),
                              style: StrokeStyle(lineWidth: 2, dash: [8]))
        )
        .padding([.horizontal, .top], 15)

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
                .padding(.horizontal, 15).padding(.vertical, 8)
                .background(Color("accentTeal")).foregroundColor(.white)
                .cornerRadius(8)
                .font(.system(.body, design: .default).weight(.medium))
            Spacer()
        }
        .padding(15)
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
            LazyVStack(spacing: 10) {
                ForEach(vm.items) { item in
                    FileRow(item: item)
                        .onTapGesture { handleTap(on: item) }
                }
            }
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
        HStack {
            Image(systemName: "doc.text.fill").foregroundColor(Color("accentTeal"))
            Text(item.url.lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Color("textPrimary"))
            Spacer(minLength: 8)
            StatusView(status: item.status)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color("lineLight"), lineWidth: 1))
    }
}

// status widget
struct StatusView: View {
    let status: ProcessingStatus
    
    var body: some View {
        Group {
            switch status {
            case .checking:         
                ProgressView().scaleEffect(0.7)
            case .encrypted:        
                Text("[Encrypted]")
                    .bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color("accentRed"))
                    .cornerRadius(6)
            case .notEncrypted:     
                Text("[Not Encrypted]")
                    .foregroundColor(Color("textSecondary"))
            case .corrupted:        
                Text("[Corrupted]")
                    .bold()
                    .foregroundColor(Color("accentRed"))
            case .decrypted:        
                Text("[Decryption Succeeded]")
                    .bold()
                    .foregroundColor(Color("accentTeal"))
            case .decryptionFailed: 
                Text("[Decryption Failed]")
                    .bold()
                    .foregroundColor(Color("accentRed"))
            }
        }
        .font(.caption)
        .transition(.opacity)
    }
}

// footer
struct FooterView: View {
    var body: some View {
        VStack(spacing: 5) {
            Text("Released by Marc Mandel under the MIT license at github.com/LegalMarc/Marcrypt")
                .font(.callout)
                .foregroundColor(Color("textSecondary"))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("Got bugs? Message me at linkedin.com/in/marcmandel/")
                .font(.callout)
                .foregroundColor(Color("textSecondary"))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
    }
}

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

// MARK: - Data Models
final class FileItem: Identifiable, ObservableObject {
    let id   = UUID()
    let url  : URL
    @Published var status: ProcessingStatus = .checking
    @Published var errorMessage: String?     = nil
    
    init(url: URL) { self.url = url }
}

enum ProcessingStatus {
    case checking, encrypted, notEncrypted, corrupted, decrypted, decryptionFailed
}

// MARK: - Central View-Model
@MainActor
final class FileViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    
    // add files, avoid duplicates, and start async status-check
    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = FileItem(url: url)
            items.append(item)
            Task { await checkStatus(for: item) }
        }
    }
    
    // async check: encrypted / notEncrypted / corrupted
    private func checkStatus(for item: FileItem) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.resume() }
                
                guard item.url.startAccessingSecurityScopedResource() else {
                    self.update(item, .corrupted, "Permission denied.")
                    return
                }
                defer { item.url.stopAccessingSecurityScopedResource() }
                
                guard let pdf = PDFDocument(url: item.url) else {
                    self.update(item, .corrupted, "Unreadable PDF.")
                    return
                }
                self.update(item, pdf.isEncrypted ? .encrypted : .notEncrypted, nil)
            }
        }
    }
    
    // helper: mutate on main-thread
    private func update(_ item: FileItem, _ status: ProcessingStatus, _ msg: String?) {
        DispatchQueue.main.async {
            item.status       = status
            item.errorMessage = msg
        }
    }
    
    // decrypt all encrypted items
    func decryptAll(with password: String, destination: URL) {
        Task.detached {
            guard destination.startAccessingSecurityScopedResource() else { return }
            defer { destination.stopAccessingSecurityScopedResource() }
            
            for item in self.items where item.status == .encrypted {
                await self.decrypt(item, password: password, dest: destination)
            }
        }
    }
    
    // single-file decryption
    private func decrypt(_ item: FileItem, password: String, dest: URL) async {
        guard item.url.startAccessingSecurityScopedResource() else {
            update(item, .decryptionFailed, "Permission denied.")
            return
        }
        defer { item.url.stopAccessingSecurityScopedResource() }
        
        guard let doc = PDFDocument(url: item.url) else {
            update(item, .decryptionFailed, "Unreadable PDF.")
            return
        }
        guard doc.unlock(withPassword: password) else {
            update(item, .decryptionFailed, "Wrong password.")
            return
        }
        let outName = item.url.deletingPathExtension().lastPathComponent + " (no crypt).pdf"
        let outURL  = dest.appendingPathComponent(outName)
        guard doc.write(to: outURL) else {
            update(item, .decryptionFailed, "Failed to write file.")
            return
        }
        update(item, .decrypted, nil)
    }
    
    var hasEncrypted: Bool { items.contains { $0.status == .encrypted } }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var vm = FileViewModel()
    @State private var password = ""
    @State private var showPwdPrompt = false
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
        .frame(width: 450, height: 650)
        .alert("Enter PDF Password", isPresented: $showPwdPrompt) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { }
            Button("Decrypt") { chooseDestinationAndDecrypt() }
        } message: {
            Text("Please enter the password for the encrypted PDF files.")
        }
        .alert(item: $alertItem) { item in
            Alert(title: Text(item.status == .decryptionFailed ? "Decryption Failed"
                                                               : item.status == .corrupted ? "Corrupted File"
                                                               : "Information"),
                  message: Text(item.errorMessage ?? "Unknown error."),
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
    
    private func chooseDestinationAndDecrypt() {
        guard !password.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            vm.decryptAll(with: password, destination: dest)
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

        // ✅ FIX: async drop-handler wrapped in Task & awaited properly
        .onDrop(of: [UTType.pdf], isTargeted: $isTargeted) { providers in
            Task {   // run drop handling in an async context
                for provider in providers {
                    if await provider.canLoadObject(ofClass: NSURL.self) {
                        if let nsurl = try? await provider.loadObject(ofClass: NSURL.self),
                           let url   = nsurl as URL? {
                            await MainActor.run { vm.add(urls: [url]) }
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
            Task { await MainActor.run { vm.add(urls: panel.urls) } }
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
        case .decryptionFailed, .corrupted: alertItem = item
        case .notEncrypted:
            let info = FileItem(url: item.url)
            info.status = .notEncrypted
            info.errorMessage = "This file is not encrypted. No action required."
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
            case .checking:         ProgressView().scaleEffect(0.7)
            case .encrypted:        Text("[Encrypted]").bold().foregroundColor(.orange)
            case .notEncrypted:     Text("[Not Encrypted]").foregroundColor(Color("textSecondary"))
            case .corrupted:        Text("[Corrupted]").bold().foregroundColor(Color("accentRed"))
            case .decrypted:        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .decryptionFailed: Image(systemName: "xmark.circle.fill").foregroundColor(Color("accentRed"))
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
            Text("Got bugs? Message me at linkedin.com/in/marcmandel/")
        }
        .font(.callout)
        .foregroundColor(Color("textSecondary"))
        .multilineTextAlignment(.center)
    }
}

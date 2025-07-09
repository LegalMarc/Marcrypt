//
//  ContentView.swift
//  Marcrypt
//
//  Final Version with UI and Logic Polish
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Data Models and Enums
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var status: ProcessingStatus = .checking
    var errorMessage: String?
    
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum ProcessingStatus {
    case checking
    case encrypted
    case unencrypted
    case corrupted
    case success
    case failure
}


// MARK: - Main Content View
struct ContentView: View {
    @State private var password = ""
    @State private var fileItems: [FileItem] = []
    @State private var isShowingPasswordAlert = false
    @State private var selectedFailedItem: FileItem?

    var body: some View {
        // Use system background which matches the light grey look
        VStack(spacing: 20) {
            InputCardView(fileItems: $fileItems)
            
            // The list now takes up the remaining space
            FileListView(fileItems: $fileItems, selectedFailedItem: $selectedFailedItem)
            
            // Action Button
            Button(action: handleDecryptButtonTap) {
                Label("Decrypt Encrypted File(s)", systemImage: "bolt.fill")
                    .font(.system(.title3, design: .default).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color("AccentTeal"))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!fileItems.contains(where: { $0.status == .encrypted }))
            
            FooterView()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 600)
        // Alerts
        .alert("Enter PDF Password", isPresented: $isShowingPasswordAlert, actions: {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { }
            Button("Decrypt") {
                if !password.isEmpty {
                    askForSaveLocation()
                }
            }
        }, message: { Text("Please enter the password for the encrypted PDF files.") })
        .alert(item: $selectedFailedItem) { item in
            Alert(
                title: Text("Decryption Failed"),
                message: Text("File: \(item.url.lastPathComponent)\n\nError: \(item.errorMessage ?? "Unknown error")"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Logic
    
    func handleDecryptButtonTap() {
        self.password = ""
        self.isShowingPasswordAlert = true
    }
    
    func askForSaveLocation() {
        let savePanel = NSOpenPanel()
        savePanel.title = "Choose Destination for Decrypted Files"
        savePanel.canChooseFiles = false
        savePanel.canChooseDirectories = true
        savePanel.canCreateDirectories = true
        savePanel.prompt = "Choose"

        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            DispatchQueue.global(qos: .userInitiated).async {
                processPDFs(destinationFolder: destinationURL)
            }
        }
    }

    func processPDFs(destinationFolder: URL) {
        guard destinationFolder.startAccessingSecurityScopedResource() else { return }

        for index in fileItems.indices {
            // Only attempt to decrypt files marked as encrypted
            guard fileItems[index].status == .encrypted else { continue }
            
            let currentItem = fileItems[index]
            guard currentItem.url.startAccessingSecurityScopedResource() else {
                updateItemStatus(at: index, status: .failure, message: "Could not get permission to access file.")
                continue
            }

            do {
                guard let pdfDoc = PDFDocument(url: currentItem.url) else {
                    throw NSError(domain: "PDFError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF document."])
                }
                
                if !pdfDoc.unlock(withPassword: self.password) {
                    throw NSError(domain: "PDFError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong password."])
                }
                let outputName = currentItem.url.deletingPathExtension().lastPathComponent + " (no crypt).pdf"
                let outputURL = destinationFolder.appendingPathComponent(outputName)
                if !pdfDoc.write(to: outputURL) {
                    throw NSError(domain: "PDFError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write new file."])
                }
                updateItemStatus(at: index, status: .success, message: nil)
            } catch {
                updateItemStatus(at: index, status: .failure, message: error.localizedDescription)
            }
            currentItem.url.stopAccessingSecurityScopedResource()
        }
        destinationFolder.stopAccessingSecurityScopedResource()
    }
    
    func updateItemStatus(at index: Int, status: ProcessingStatus, message: String?) {
        DispatchQueue.main.async {
            fileItems[index].status = status
            fileItems[index].errorMessage = message
        }
    }
}


// MARK: - Subviews

struct InputCardView: View {
    @Binding var fileItems: [FileItem]
    @State private var isTargetedForDrop = false

    var body: some View {
        VStack(spacing: 0) {
            // Inner Drop Zone
            VStack(spacing: 15) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 40))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                Text("Drag & Drop .pdf files here")
                    .font(.system(.headline, design: .default))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isTargetedForDrop ? Color("AccentTeal") : Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8]))
            )
            .padding([.horizontal, .top], 15)
            .onDrop(of: [UTType.pdf], isTargeted: $isTargetedForDrop, perform: handleDrop)

            // Bottom bar with Browse button
            HStack {
                Button("Browse...") { selectFiles() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(Color("AccentTeal"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .font(.system(.body, design: .default).weight(.medium))
                Spacer()
            }
            .padding(15)
        }
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    checkAndAddFile(url: url)
                }
            }
        }
        return true
    }
    
    private func selectFiles() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [UTType.pdf]
        if openPanel.runModal() == .OK {
            for url in openPanel.urls {
                checkAndAddFile(url: url)
            }
        }
    }
    
    private func checkAndAddFile(url: URL) {
        DispatchQueue.main.async {
            guard !fileItems.contains(where: { $0.url == url }) else { return }
            let newItem = FileItem(url: url)
            fileItems.append(newItem)
            
            // Asynchronously check the status
            DispatchQueue.global(qos: .userInitiated).async {
                guard url.startAccessingSecurityScopedResource() else {
                    updateStatus(for: newItem.id, to: .corrupted, message: "Permission denied.")
                    return
                }
                
                var newStatus: ProcessingStatus = .unencrypted
                if let pdfDoc = PDFDocument(url: url) {
                    if pdfDoc.isEncrypted {
                        newStatus = .encrypted
                    }
                } else {
                    newStatus = .corrupted
                }
                url.stopAccessingSecurityScopedResource()
                updateStatus(for: newItem.id, to: newStatus, message: nil)
            }
        }
    }
    
    private func updateStatus(for id: UUID, to status: ProcessingStatus, message: String?) {
        DispatchQueue.main.async {
            if let index = fileItems.firstIndex(where: { $0.id == id }) {
                fileItems[index].status = status
                fileItems[index].errorMessage = message
            }
        }
    }
}

struct FileListView: View {
    @Binding var fileItems: [FileItem]
    @Binding var selectedFailedItem: FileItem?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(fileItems) { item in
                    FileListItemView(item: item)
                        .onTapGesture {
                            if item.status == .failure { selectedFailedItem = item }
                        }
                }
            }
        }
    }
}

struct FileListItemView: View {
    let item: FileItem

    var body: some View {
        HStack {
            Image(systemName: "doc.text.fill")
                .foregroundColor(Color("AccentTeal"))
            
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(.body, design: .monospaced))
            
            Spacer()
            
            StatusView(status: item.status)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.05), radius: 3, y: 2)
    }
}

struct StatusView: View {
    let status: ProcessingStatus
    
    var body: some View {
        Group {
            switch status {
            case .checking:
                ProgressView().scaleEffect(0.7)
            case .encrypted:
                Text("[Encrypted]").font(.caption).foregroundColor(.orange)
            case .unencrypted:
                Text("[Unencrypted]").font(.caption).foregroundColor(.secondary)
            case .corrupted:
                Text("[Corrupted]").font(.caption).foregroundColor(.red)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .failure:
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            }
        }
        .transition(.opacity.animation(.easeInOut))
    }
}


struct FooterView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Released by Marc Mandel under the MIT license at [github.com/LegalMarc/Marcrypt](https://github.com/LegalMarc/Marcrypt)")
            Text("Got bugs? Message me at [linkedin.com/in/marcmandel/](https://www.linkedin.com/in/marcmandel/)")
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
}

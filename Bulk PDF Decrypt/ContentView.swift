//
//  ContentView.swift
//  Bulk PDF Decrypt
//
//  Final UI revision based on user feedback
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Data Models for State Management

/// Represents the processing status of a single file.
enum ProcessingStatus {
    case pending
    case success
    case failure
}

/// A struct to hold a file URL and its processing status.
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var status: ProcessingStatus = .pending
    var errorMessage: String?
    
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}


// MARK: - Main Content View
struct ContentView: View {
    // MARK: State Variables
    @State private var password = ""
    @State private var fileItems: [FileItem] = []
    
    @State private var isShowingPasswordAlert = false
    @State private var selectedFailedItem: FileItem?

    var body: some View {
        ZStack {
            // Background Color
            Color(nsColor: .windowBackgroundColor).edgesIgnoringSafeArea(.all)

            ScrollView {
                VStack(spacing: 25) {
                    // Header
                    Text("Bulk PDF Decrypter")
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .foregroundColor(.primary)

                    // Main Input Card
                    InputCardView(fileItems: $fileItems)
                    
                    // List of selected files
                    if !fileItems.isEmpty {
                        FileListView(fileItems: $fileItems, selectedFailedItem: $selectedFailedItem)
                    }

                    // Action Button
                    Button(action: {
                        if !fileItems.isEmpty {
                            self.password = ""
                            self.isShowingPasswordAlert = true
                        }
                    }) {
                        Label("Decrypt \(fileItems.count) File(s)", systemImage: "bolt.fill")
                            .font(.system(.title2, design: .default).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color("AccentTeal"))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(fileItems.isEmpty)
                    
                    // Footer
                    FooterView()
                }
                .padding(30)
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        // Password Alert
        .alert("Enter PDF Password", isPresented: $isShowingPasswordAlert, actions: {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { }
            Button("Decrypt") {
                if !password.isEmpty {
                    askForSaveLocation()
                }
            }
        }, message: {
            Text("Please enter the password for the selected PDF files.")
        })
        // Error message alert for a specific failed item
        .alert(item: $selectedFailedItem) { item in
            Alert(
                title: Text("Decryption Failed"),
                message: Text("File: \(item.url.lastPathComponent)\n\nError: \(item.errorMessage ?? "Unknown error")"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Logic
    
    func askForSaveLocation() {
        let savePanel = NSOpenPanel()
        savePanel.title = "Choose Destination for Decrypted Files"
        savePanel.canChooseFiles = false
        savePanel.canChooseDirectories = true
        savePanel.canCreateDirectories = true
        savePanel.allowsMultipleSelection = false
        savePanel.prompt = "Choose"

        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            // Reset statuses before processing
            for i in fileItems.indices {
                fileItems[i].status = .pending
                fileItems[i].errorMessage = nil
            }
            // Process on a background thread
            DispatchQueue.global(qos: .userInitiated).async {
                processPDFs(destinationFolder: destinationURL)
            }
        }
    }

    func processPDFs(destinationFolder: URL) {
        guard destinationFolder.startAccessingSecurityScopedResource() else { return }

        for index in fileItems.indices {
            let currentItem = fileItems[index]
            guard currentItem.url.startAccessingSecurityScopedResource() else {
                updateItemStatus(at: index, status: .failure, message: "Could not get permission to access file.")
                continue
            }

            var updatedItem = currentItem
            do {
                guard let pdfDoc = PDFDocument(url: currentItem.url) else {
                    throw NSError(domain: "PDFError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF document."])
                }
                if pdfDoc.isEncrypted && !pdfDoc.unlock(withPassword: self.password) {
                    throw NSError(domain: "PDFError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong password."])
                }
                let outputName = currentItem.url.deletingPathExtension().lastPathComponent + " (no crypt).pdf"
                let outputURL = destinationFolder.appendingPathComponent(outputName)
                if !pdfDoc.write(to: outputURL) {
                    throw NSError(domain: "PDFError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write new file."])
                }
                updatedItem.status = .success
            } catch {
                updatedItem.status = .failure
                updatedItem.errorMessage = error.localizedDescription
            }
            
            // Update the main array on the main thread
            DispatchQueue.main.async {
                self.fileItems[index] = updatedItem
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


// MARK: - Subviews for Cleaner UI

struct InputCardView: View {
    @Binding var fileItems: [FileItem]
    @State private var isTargetedForDrop = false

    var body: some View {
        VStack(spacing: 0) {
            // Inner Drop Zone
            VStack {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 40))
                    .foregroundColor(Color("AccentTeal"))
                Text("Drag & Drop .pdf files here")
                    .font(.system(.headline, design: .default))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isTargetedForDrop ? Color("AccentTeal") : .gray.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8]))
            )
            .padding(20)
            .onDrop(of: [UTType.pdf], isTargeted: $isTargetedForDrop) { providers -> Bool in
                handleDrop(providers: providers)
                return true
            }

            Divider()

            // Bottom bar with Browse button
            HStack {
                Button("Browse...") {
                    selectFiles()
                }
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
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url {
                    DispatchQueue.main.async {
                        if !fileItems.contains(where: { $0.url == url }) {
                            fileItems.append(FileItem(url: url))
                        }
                    }
                }
            }
        }
    }
    
    private func selectFiles() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [UTType.pdf]
        if openPanel.runModal() == .OK {
            for url in openPanel.urls {
                if !fileItems.contains(where: { $0.url == url }) {
                    fileItems.append(FileItem(url: url))
                }
            }
        }
    }
}

struct FileListView: View {
    @Binding var fileItems: [FileItem]
    @Binding var selectedFailedItem: FileItem?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Selected Files")
                    .font(.system(.headline, design: .default))
                Spacer()
                Button("Clear All") {
                    fileItems.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
            }

            // Using List for better performance with many items
            List($fileItems) { $item in
                FileListItemView(item: item)
                    .onTapGesture {
                        if item.status == .failure {
                            selectedFailedItem = item
                        }
                    }
            }
            .frame(maxHeight: 250)
            .listStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
    }
}

struct FileListItemView: View {
    let item: FileItem

    var body: some View {
        HStack {
            Image(systemName: "doc.text.fill")
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // Status Indicator
            switch item.status {
            case .pending:
                EmptyView() // No icon when pending
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FooterView: View {
    var body: some View {
        VStack {
            // Using a Text view with Markdown for the link
            Text("Released by Marc Mandel under the MIT license at [github.com/LegalMarc/Marcrypt](https://github.com/LegalMarc/Marcrypt)")
            Text("Got bugs? Message me at [linkedin.com/in/marcmandel/](https://www.linkedin.com/in/marcmandel/)")
        }
        .font(.footnote) // Larger than .caption
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
}

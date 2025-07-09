//
//  ContentView.swift
//  Bulk PDF Decrypt
//
//  App Store Compliant Version - Asks for Save Location
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    // MARK: - State Variables
    @State private var password = ""
    @State private var isShowingPasswordAlert = false
    @State private var filesToProcess: [URL] = []
    
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isShowingResultAlert = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("PDF Decrypter")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Select files or drag and drop PDFs onto this window to remove their password encryption.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Button(action: selectFiles) {
                Label("Select PDF Files...", systemImage: "plus.circle.fill")
                    .font(.title2)
            }
            .controlSize(.large)
            
            Text("The original files will not be modified.")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(width: 450, height: 350)
        .onDrop(of: [UTType.pdf], isTargeted: nil) { providers -> Bool in
            handleDrop(providers: providers)
            return true
        }
        .alert("Enter PDF Password", isPresented: $isShowingPasswordAlert, actions: {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { }
            Button("Decrypt") {
                if !password.isEmpty {
                    // Ask the user where to save the files
                    askForSaveLocation()
                }
            }
        }, message: {
            Text("Please enter the password for the selected PDF files.")
        })
        .alert(alertTitle, isPresented: $isShowingResultAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(alertMessage)
        })
    }

    // MARK: - Core Logic (No changes here)

    func selectFiles() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [UTType.pdf]

        if openPanel.runModal() == .OK {
            self.filesToProcess = openPanel.urls
            if !self.filesToProcess.isEmpty {
                self.password = ""
                self.isShowingPasswordAlert = true
            }
        }
    }
    
    func handleDrop(providers: [NSItemProvider]) {
        var droppedUrls: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url {
                    droppedUrls.append(url)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            self.filesToProcess = droppedUrls
            if !self.filesToProcess.isEmpty {
                self.password = ""
                self.isShowingPasswordAlert = true
            }
        }
    }
    
    // MARK: - Save Location & PDFKit Processing Logic
    
    /// Prompts the user to select a destination folder for the decrypted files.
    func askForSaveLocation() {
        let savePanel = NSOpenPanel()
        savePanel.title = "Choose Destination for Decrypted Files"
        savePanel.canChooseFiles = false
        savePanel.canChooseDirectories = true
        savePanel.canCreateDirectories = true
        savePanel.allowsMultipleSelection = false
        savePanel.prompt = "Choose"

        if savePanel.runModal() == .OK {
            if let destinationURL = savePanel.url {
                DispatchQueue.global(qos: .userInitiated).async {
                    processPDFs(urls: filesToProcess, destinationFolder: destinationURL)
                }
            }
        }
    }

    /// The main function that uses native PDFKit to decrypt files.
    func processPDFs(urls: [URL], destinationFolder: URL) {
        var successCount = 0
        var errorMessages: [String] = []

        // Explicitly start accessing the destination folder provided by the user.
        guard destinationFolder.startAccessingSecurityScopedResource() else {
            showResultAlert(title: "Permission Error", message: "Could not get permission to write to the destination folder.")
            return
        }

        for url in urls {
            // Start accessing the source file.
            guard url.startAccessingSecurityScopedResource() else {
                errorMessages.append("• \(url.lastPathComponent): Could not get permission to access the file.")
                // Stop accessing the destination folder before continuing.
                destinationFolder.stopAccessingSecurityScopedResource()
                continue
            }

            do {
                guard let pdfDoc = PDFDocument(url: url) else {
                    throw NSError(domain: "PDFError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF document from source."])
                }

                if pdfDoc.isEncrypted && pdfDoc.isLocked {
                    if !pdfDoc.unlock(withPassword: self.password) {
                        throw NSError(domain: "PDFError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong password."])
                    }
                }
                
                // Construct the new file path inside the user-chosen destination folder.
                let outputName = url.deletingPathExtension().lastPathComponent + " (no crypt).pdf"
                let outputURL = destinationFolder.appendingPathComponent(outputName)

                if pdfDoc.write(to: outputURL) {
                    successCount += 1
                } else {
                    throw NSError(domain: "PDFError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write the new file."])
                }

            } catch {
                errorMessages.append("• \(url.lastPathComponent): \(error.localizedDescription)")
            }

            // Release access for the source file before moving to the next one.
            url.stopAccessingSecurityScopedResource()
        }
        
        // Release access for the destination folder now that we are done.
        destinationFolder.stopAccessingSecurityScopedResource()
        
        // Report the results back on the main thread to update the UI
        DispatchQueue.main.async {
            var finalMessage = ""
            if successCount > 0 {
                finalMessage = "Successfully decrypted and saved \(successCount) file(s)."
            }
            if !errorMessages.isEmpty {
                finalMessage += "\n\nErrors:\n" + errorMessages.joined(separator: "\n")
            }
            showResultAlert(title: "Processing Complete", message: finalMessage.isEmpty ? "No files were processed." : finalMessage)
        }
    }
    
    func showResultAlert(title: String, message: String) {
        self.alertTitle = title
        self.alertMessage = message
        self.isShowingResultAlert = true
    }
}

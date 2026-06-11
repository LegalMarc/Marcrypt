import SwiftUI
import MarcryptCore

struct FileRow: View {
    @ObservedObject var item: FileItem
    @Environment(\.colorScheme) var colorScheme
    var onSettings: () -> Void = {}
    var onOpenReport: ((FileItem) -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Dynamic Icon
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(CustomColors.accentColor(for: colorScheme))
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.deletingPathExtension().lastPathComponent + "." + item.url.pathExtension)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(CustomColors.primaryText(for: colorScheme))
                
                if !item.fileSizeString.isEmpty {
                    Text(item.fileSizeString)
                        .font(.caption2)
                        .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                }
            }
            
            Spacer() 
            
            // Action Buttons - Only when processed
            if isProcessedSuccessfully {
                HStack(spacing: 8) {
                    // Open File
                    TooltipButton(
                        action: { openFile() },
                        icon: "doc.text.fill",
                        tooltip: "Open File",
                        description: "Opens the processed output file",
                        isEnabled: true,
                        accessibilityId: "fileRow.open.\(item.id.uuidString)"
                    )
                    
                    // Reveal in Finder
                    TooltipButton(
                        action: { revealInFinder() },
                        icon: "folder.fill",
                        tooltip: "Show in Finder",
                        description: "Reveals the output file in Finder",
                        isEnabled: true,
                        accessibilityId: "fileRow.reveal.\(item.id.uuidString)"
                    )
                    
                    // View Report
                    if item.reportURL != nil {
                        TooltipButton(
                            action: { onOpenReport?(item) },
                            icon: "doc.text.magnifyingglass",
                            tooltip: "View Report",
                            description: "Opens the processing report with details and checksums",
                            isEnabled: true,
                            accessibilityId: "fileRow.report.\(item.id.uuidString)"
                        )
                    }
                    
                    // Share
                    TooltipButton(
                        action: { shareFile() },
                        icon: "square.and.arrow.up",
                        tooltip: "Share",
                        description: "Share the output file via system share sheet",
                        isEnabled: true,
                        accessibilityId: "fileRow.share.\(item.id.uuidString)"
                    )
                }
            }
            
            StatusView(status: item.status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fileRow_\(item.url.lastPathComponent)")
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CustomColors.cardBackground(for: colorScheme))
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(CustomColors.subtleBorder(for: colorScheme), lineWidth: 1)
        )
    }
    
    var isProcessedSuccessfully: Bool {
        return item.status == .decrypted || item.status == .encryptionSucceeded || item.status == .watermarked || item.status == .watermarkedEncrypted
    }
    
    // Actions
    func revealInFinder() {
        let targetURL = getTargetURL()
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }
    
    func openFile() {
        let targetURL = getTargetURL()
        NSWorkspace.shared.open(targetURL)
    }
    
    func shareFile() {
        let targetURL = getTargetURL()
        let picker = NSSharingServicePicker(items: [targetURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }
    
    func getTargetURL() -> URL {
        // Return the output URL (encrypted/decrypted result) if available
        if let output = item.outputURL { return output }
        if let docDetails = item.decryptedDocument?.documentURL { return docDetails }
        if let temp = item.temporaryDecryptedURL { return temp }
        // Fallback to original source
        return item.url 
    }
    
    var iconName: String {
        switch item.type {
        case .pdf: return "doc.text.fill"
        case .zip: return "doc.zipper" // Requires SF Symbols
        case .folder: return "folder.fill"
        case .docx: return "doc.richtext.fill" // Word-like icon
        default: return "doc"
        }
    }
}

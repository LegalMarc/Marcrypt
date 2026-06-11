import SwiftUI
import QuickLook

import UniformTypeIdentifiers
import MarcryptCore

struct FileListView: View {
    @ObservedObject var vm: FileViewModel
    @Binding var alertItem: FileItem?
    
    // Quick Look State
    @State private var previewItem: URL?
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(vm.items) { item in
                    FileRow(item: item, onOpenReport: { item in vm.openReport(for: item) })
                        .onTapGesture { handleTap(on: item) }
                        .contextMenu {
                            Button("Quick Look") { previewItem = item.url }
                            Button("Remove") { 
                                if let idx = vm.items.firstIndex(where: {$0.id == item.id}) {
                                    vm.items.remove(at: idx)
                                }
                            }
                        }
                        // .animation removed to prevent scroll jitter

                }
            }
            .padding(.horizontal, 4)
        }
        .scrollContentBackground(.hidden) 
        .quickLookPreview($previewItem)
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

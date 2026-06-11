import SwiftUI
import MarcryptCore

struct BatchProgressView: View {
    let processed: Int
    let total: Int
    let successCount: Int
    let failedCount: Int
    var currentFileName: String? = nil
    var currentFileProgress: Double? = nil
    var onCancel: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: Double(processed), total: Double(total))
            
            if let fileName = currentFileName {
                Text(fileName.count > 40 ? String(fileName.prefix(37)) + "..." : fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let currentFileProgress {
                ProgressView(value: currentFileProgress)
                    .controlSize(.small)
            }
            
            HStack {
                Text("Processing \(processed)/\(total)")
                    .font(.caption)
                    .monospacedDigit()
                
                Spacer()
                
                if failedCount > 0 {
                    Text("\(failedCount) Failed")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                if let cancel = onCancel {
                    Button(action: cancel) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                            Text("Cancel")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

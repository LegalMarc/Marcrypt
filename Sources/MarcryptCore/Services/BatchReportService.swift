import Foundation
import CryptoKit

/// Generates a combined HTML batch report with per-file sections and deep-link anchors.
public class BatchReportService {
    public static let shared = BatchReportService()
    private init() {}

    public actor HashCache {
        private struct CacheKey: Hashable {
            let path: String
            let size: Int64
            let modificationTime: TimeInterval

            init(url: URL) {
                let standardized = url.standardizedFileURL
                let attrs = try? FileManager.default.attributesOfItem(atPath: standardized.path)
                let modified = attrs?[.modificationDate] as? Date
                self.path = standardized.path
                self.size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                self.modificationTime = modified?.timeIntervalSince1970 ?? -1
            }
        }

        private var sha256Values: [CacheKey: String] = [:]
        private var md5Values: [CacheKey: String] = [:]
        private var sha256Tasks: [CacheKey: Task<String, Never>] = [:]
        private var md5Tasks: [CacheKey: Task<String, Never>] = [:]
        private var sizeValues: [CacheKey: Int64] = [:]
        private var sha256Misses = 0
        private var md5Misses = 0

        public init() {}

        public func sha256(of url: URL) async -> String {
            let key = CacheKey(url: url)
            if let cached = sha256Values[key] { return cached }
            if let task = sha256Tasks[key] { return await task.value }

            sha256Misses += 1
            let task = Task<String, Never> {
                await BatchReportService.sha256(of: url)
            }
            sha256Tasks[key] = task
            let value = await task.value
            sha256Values[key] = value
            sha256Tasks[key] = nil
            return value
        }

        public func md5(of url: URL) async -> String {
            let key = CacheKey(url: url)
            if let cached = md5Values[key] { return cached }
            if let task = md5Tasks[key] { return await task.value }

            md5Misses += 1
            let task = Task<String, Never> {
                await BatchReportService.md5(of: url)
            }
            md5Tasks[key] = task
            let value = await task.value
            md5Values[key] = value
            md5Tasks[key] = nil
            return value
        }

        public func fileSize(of url: URL) -> Int64 {
            let key = CacheKey(url: url)
            if let cached = sizeValues[key] { return cached }
            let value = BatchReportService.fileSize(of: url)
            sizeValues[key] = value
            return value
        }

        public var debugStats: (sha256Misses: Int, md5Misses: Int) {
            (sha256Misses, md5Misses)
        }
    }

    // MARK: - Report Data Model

    /// Details about a single file's processing within a batch.
    public struct FileReport {
        public let fileID: String // UUID string, used as HTML anchor
        public let fileName: String
        public let sourceURL: URL
        public let outputURL: URL?
        public let operation: String // "Encryption", "Watermarking", "Decryption"
        public let success: Bool
        public let errorMessage: String?
        public let startTime: Date
        public let endTime: Date
        public let fileSizeBefore: Int64
        public let fileSizeAfter: Int64?
        public let md5Before: String
        public let md5After: String?
        public let details: [String: String] // Operation-specific details

        public init(
            fileID: String,
            fileName: String,
            sourceURL: URL,
            outputURL: URL?,
            operation: String,
            success: Bool,
            errorMessage: String? = nil,
            startTime: Date,
            endTime: Date,
            fileSizeBefore: Int64,
            fileSizeAfter: Int64? = nil,
            md5Before: String,
            md5After: String? = nil,
            details: [String: String] = [:]
        ) {
            self.fileID = fileID
            self.fileName = fileName
            self.sourceURL = sourceURL
            self.outputURL = outputURL
            self.operation = operation
            self.success = success
            self.errorMessage = errorMessage
            self.startTime = startTime
            self.endTime = endTime
            self.fileSizeBefore = fileSizeBefore
            self.fileSizeAfter = fileSizeAfter
            self.md5Before = md5Before
            self.md5After = md5After
            self.details = details
        }
    }

    // MARK: - MD5 Helpers

    /// Computes the MD5 hash of a file at the given URL.
    /// Computes the MD5 hash of a file at the given URL asynchronously and memory-efficiently.
    public static func md5(of url: URL) async -> String {
        return await Task.detached(priority: .userInitiated) {
            let bufferSize = 1024 * 1024 // 1MB chunks
            do {
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }
                
                var digest = Insecure.MD5()
                
                while true {
                    let data = fileHandle.readData(ofLength: bufferSize)
                    if data.isEmpty { break }
                    digest.update(data: data)
                    
                    if Task.isCancelled { return "N/A" }
                }
                
                let finalized = digest.finalize()
                return finalized.map { String(format: "%02hhx", $0) }.joined()
            } catch {
                return "N/A" // Should unlikely happen if file exists check passed
            }
        }.value
    }

    public static func sha256(of url: URL) async -> String {
        return await Task.detached(priority: .userInitiated) {
            (try? IntegrityService.shared.sha256(of: url)) ?? "N/A"
        }.value
    }

    /// Gets the file size in bytes.
    public static func fileSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Report Generation

    /// Generates the combined HTML report and writes it to the given URL.
    /// Returns the URL on success, nil on failure.
    @discardableResult
    public func generateReport(
        title: String,
        batchOperation: String,
        files: [FileReport],
        outputDirectory: URL
    ) -> URL? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        let reportFileName = "Marcrypt_Report_\(dateString()).html"
        let reportURL = outputDirectory.appendingPathComponent(reportFileName)

        let successCount = files.filter { $0.success }.count
        let failureCount = files.count - successCount

        var html = htmlHeader(title: title)
        html += summarySection(
            batchOperation: batchOperation,
            totalFiles: files.count,
            successCount: successCount,
            failureCount: failureCount,
            dateFormatter: dateFormatter
        )

        for file in files {
            html += fileSection(file: file, dateFormatter: dateFormatter)
        }

        html += htmlFooter()

        do {
            try html.write(to: reportURL, atomically: true, encoding: .utf8)
            return reportURL
        } catch {
            AppLogger.error("Failed to write batch report: \(error)", logger: AppLogger.general)
            return nil
        }
    }

    // MARK: - HTML Sections

    private func summarySection(batchOperation: String, totalFiles: Int, successCount: Int, failureCount: Int, dateFormatter: DateFormatter) -> String {
        """
        <div class="summary-card">
            <h2>Batch Summary</h2>
            <div class="summary-grid">
                <div class="stat-item">
                    <span class="stat-label">Operation</span>
                    <span class="stat-value">\(batchOperation)</span>
                </div>
                <div class="stat-item">
                    <span class="stat-label">Total Files</span>
                    <span class="stat-value">\(totalFiles)</span>
                </div>
                <div class="stat-item">
                    <span class="stat-label">Succeeded</span>
                    <span class="stat-value success-text">\(successCount)</span>
                </div>
                <div class="stat-item">
                    <span class="stat-label">Failed</span>
                    <span class="stat-value \(failureCount > 0 ? "error-text" : "")">\(failureCount)</span>
                </div>
                <div class="stat-item">
                    <span class="stat-label">Generated</span>
                    <span class="stat-value">\(dateFormatter.string(from: Date()))</span>
                </div>
            </div>
        </div>
        """
    }

    private func fileSection(file: FileReport, dateFormatter: DateFormatter) -> String {
        let statusClass = file.success ? "status-success" : "status-error"
        let statusText = file.success ? "✅ Success" : "❌ Failed"
        let duration = file.endTime.timeIntervalSince(file.startTime)
        let durationStr = String(format: "%.1fs", duration)

        var section = """
        <div class="file-section" id="file-\(file.fileID)">
            <div class="file-header" onclick="toggleSection(this)">
                <div class="file-title">
                    <span class="file-icon">\(fileIcon(for: file.fileName))</span>
                    <span class="file-name">\(escapeHTML(file.fileName))</span>
                </div>
                <div class="file-status \(statusClass)">
                    \(statusText)
                    <span class="chevron">▼</span>
                </div>
            </div>
            <div class="file-details">
                <table class="detail-table">
                    <tr>
                        <td class="detail-label">Operation</td>
                        <td class="detail-value">\(escapeHTML(file.operation))</td>
                    </tr>
                    <tr>
                        <td class="detail-label">Source</td>
                        <td class="detail-value mono">\(escapeHTML(displayPath(file.sourceURL)))</td>
                    </tr>
        """

        if let outputURL = file.outputURL {
            section += """
                    <tr>
                        <td class="detail-label">Output</td>
                        <td class="detail-value mono">\(escapeHTML(displayPath(outputURL)))</td>
                    </tr>
            """
        }

        section += """
                    <tr>
                        <td class="detail-label">Duration</td>
                        <td class="detail-value">\(durationStr)</td>
                    </tr>
                    <tr>
                        <td class="detail-label">Started</td>
                        <td class="detail-value">\(dateFormatter.string(from: file.startTime))</td>
                    </tr>
                    <tr>
                        <td class="detail-label">Completed</td>
                        <td class="detail-value">\(dateFormatter.string(from: file.endTime))</td>
                    </tr>
        """

        // File size
        section += """
                    <tr>
                        <td class="detail-label">Size Before</td>
                        <td class="detail-value">\(formatBytes(file.fileSizeBefore))</td>
                    </tr>
        """
        if let sizeAfter = file.fileSizeAfter {
            section += """
                    <tr>
                        <td class="detail-label">Size After</td>
                        <td class="detail-value">\(formatBytes(sizeAfter))</td>
                    </tr>
            """
        }

        // MD5 checksums
        section += """
                    <tr>
                        <td class="detail-label">MD5 Before</td>
                        <td class="detail-value mono">\(escapeHTML(file.md5Before))</td>
                    </tr>
        """
        if let md5After = file.md5After {
            section += """
                    <tr>
                        <td class="detail-label">MD5 After</td>
                        <td class="detail-value mono">\(escapeHTML(md5After))</td>
                    </tr>
            """
        }

        // Operation-specific details
        for (key, value) in file.details.sorted(by: { $0.key < $1.key }) {
            section += """
                    <tr>
                        <td class="detail-label">\(escapeHTML(key))</td>
                        <td class="detail-value">\(escapeHTML(value))</td>
                    </tr>
            """
        }

        // Error message if failed
        if let errorMessage = file.errorMessage {
            section += """
                    <tr>
                        <td class="detail-label">Error</td>
                        <td class="detail-value error-text">\(escapeHTML(errorMessage))</td>
                    </tr>
            """
        }

        section += """
                </table>
            </div>
        </div>
        """

        return section
    }

    // MARK: - HTML Template

    private func htmlHeader(title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(title))</title>
            <style>
                :root {
                    --bg-primary: #0e0e1a;
                    --bg-card: #161625;
                    --bg-card-hover: #1c1c30;
                    --border: #2a2a44;
                    --text-primary: #e8e8f0;
                    --text-secondary: #8888aa;
                    --text-mono: #a0a0cc;
                    --accent: #5b8def;
                    --accent-light: #7aa8ff;
                    --success: #4caf50;
                    --error: #ef5350;
                    --warning: #ff9800;
                }
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
                    background: var(--bg-primary);
                    color: var(--text-primary);
                    padding: 32px;
                    line-height: 1.5;
                }
                h1 {
                    font-size: 24px;
                    font-weight: 700;
                    margin-bottom: 8px;
                    color: var(--accent-light);
                }
                h2 {
                    font-size: 18px;
                    font-weight: 600;
                    margin-bottom: 16px;
                    color: var(--text-primary);
                }
                .header {
                    margin-bottom: 32px;
                    padding-bottom: 16px;
                    border-bottom: 1px solid var(--border);
                }
                .header-subtitle {
                    color: var(--text-secondary);
                    font-size: 13px;
                }
                .summary-card {
                    background: var(--bg-card);
                    border: 1px solid var(--border);
                    border-radius: 12px;
                    padding: 24px;
                    margin-bottom: 24px;
                }
                .summary-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
                    gap: 16px;
                }
                .stat-item {
                    display: flex;
                    flex-direction: column;
                    gap: 4px;
                }
                .stat-label {
                    font-size: 12px;
                    color: var(--text-secondary);
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                }
                .stat-value {
                    font-size: 20px;
                    font-weight: 600;
                }
                .success-text { color: var(--success); }
                .error-text { color: var(--error); }
                .file-section {
                    background: var(--bg-card);
                    border: 1px solid var(--border);
                    border-radius: 12px;
                    margin-bottom: 12px;
                    overflow: hidden;
                    scroll-margin-top: 16px;
                }
                .file-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    padding: 16px 20px;
                    cursor: pointer;
                    transition: background 0.15s;
                }
                .file-header:hover {
                    background: var(--bg-card-hover);
                }
                .file-title {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                    font-weight: 500;
                }
                .file-icon {
                    font-size: 20px;
                }
                .file-name {
                    font-size: 15px;
                }
                .file-status {
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    font-size: 13px;
                    font-weight: 500;
                }
                .status-success { color: var(--success); }
                .status-error { color: var(--error); }
                .chevron {
                    font-size: 10px;
                    transition: transform 0.2s;
                    color: var(--text-secondary);
                }
                .file-section.collapsed .chevron {
                    transform: rotate(-90deg);
                }
                .file-section.collapsed .file-details {
                    display: none;
                }
                .file-details {
                    border-top: 1px solid var(--border);
                    padding: 16px 20px;
                }
                .detail-table {
                    width: 100%;
                    border-collapse: collapse;
                }
                .detail-table tr {
                    border-bottom: 1px solid rgba(42, 42, 68, 0.5);
                }
                .detail-table tr:last-child {
                    border-bottom: none;
                }
                .detail-label {
                    padding: 8px 16px 8px 0;
                    font-size: 13px;
                    color: var(--text-secondary);
                    white-space: nowrap;
                    width: 140px;
                    vertical-align: top;
                }
                .detail-value {
                    padding: 8px 0;
                    font-size: 13px;
                    word-break: break-all;
                }
                .mono {
                    font-family: 'SF Mono', 'Menlo', 'Monaco', monospace;
                    font-size: 12px;
                    color: var(--text-mono);
                }
                .footer {
                    margin-top: 32px;
                    padding-top: 16px;
                    border-top: 1px solid var(--border);
                    text-align: center;
                    color: var(--text-secondary);
                    font-size: 12px;
                }
                @media print {
                    body { background: white; color: black; }
                    .file-section, .summary-card { border-color: #ddd; background: #fafafa; }
                    .file-section.collapsed .file-details { display: block !important; }
                    .chevron { display: none; }
                    .file-header { cursor: default; }
                    .file-header:hover { background: transparent; }
                    :root {
                        --text-primary: #111;
                        --text-secondary: #666;
                        --text-mono: #333;
                        --success: #2e7d32;
                        --error: #c62828;
                    }
                }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>🔐 \(escapeHTML(title))</h1>
                <p class="header-subtitle">Generated by Marcrypt</p>
            </div>
        """
    }

    private func htmlFooter() -> String {
        """
            <div class="footer">
                <p>Marcrypt Batch Report · Generated \(dateString())</p>
            </div>
            <script>
                function toggleSection(header) {
                    const section = header.closest('.file-section');
                    section.classList.toggle('collapsed');
                }
            </script>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func displayPath(_ url: URL) -> String {
        if UserDefaults.standard.bool(forKey: "IncludeFullPathsInBatchReports") {
            return url.path
        }
        return url.lastPathComponent
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func fileIcon(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "📄"
        case "docx", "doc": return "📝"
        case "zip": return "📦"
        default: return "📁"
        }
    }
}

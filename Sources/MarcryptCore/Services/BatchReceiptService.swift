import Foundation

/// Generates a human-readable HTML batch receipt from JSON audit data, in pure Swift.
/// Service to generate HTML batch processing receipts.
/// Self-contained single-file HTML with embedded CSS/JS.
public class BatchReceiptService {
    
    /// Generate an HTML receipt from audit events.
    /// Returns the URL of the generated .html file.
    public static func generateReceipt(
        events: [AuditService.AuditEvent],
        outputDirectory: URL
    ) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = "marcrypt_receipt_\(timestamp.replacingOccurrences(of: ":", with: "-")).html"
        let outputURL = outputDirectory.appendingPathComponent(fileName)
        
        let html = buildHTML(events: events, generatedAt: timestamp)
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
        
        return outputURL
    }
    
    // MARK: - HTML Builder
    
    private static func buildHTML(events: [AuditService.AuditEvent], generatedAt: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        
        let successCount = events.filter { if case .success = $0.outcome { return true }; return false }.count
        let failureCount = events.count - successCount
        
        var rows = ""
        for (index, event) in events.enumerated() {
            let outcomeClass: String
            let outcomeText: String
            switch event.outcome {
            case .success:
                outcomeClass = "success"
                outcomeText = "✓ Success"
            case .failure(let reason):
                outcomeClass = "failure"
                outcomeText = "✗ \(escapeHTML(reason))"
            }
            
            let params = event.parameters.map { "\(escapeHTML($0.key)): \(escapeHTML($0.value))" }.joined(separator: "; ")
            
            rows += """
            <tr>
                <td>\(index + 1)</td>
                <td>\(dateFormatter.string(from: event.timestamp))</td>
                <td><span class="op-badge">\(event.operation.rawValue.uppercased())</span></td>
                <td class="file-cell">\(escapeHTML(event.inputFile))</td>
                <td class="hash-cell">\(event.inputHash.map { String($0.prefix(16)) + "…" } ?? "—")</td>
                <td class="file-cell">\(event.outputFile.map { escapeHTML($0) } ?? "—")</td>
                <td class="hash-cell">\(event.outputHash.map { String($0.prefix(16)) + "…" } ?? "—")</td>
                <td class="\(outcomeClass)">\(outcomeText)</td>
                <td class="params-cell">\(params.isEmpty ? "—" : params)</td>
            </tr>
            """
        }
        
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Marcrypt Processing Receipt</title>
            <style>
                :root {
                    --bg: #1a1a2e; --surface: #16213e; --card: #0f3460;
                    --text: #e6e6e6; --text-muted: #a0a0b0;
                    --accent: #e94560; --success: #4ade80; --fail: #f87171;
                    --border: #2a2a4a;
                }
                @media (prefers-color-scheme: light) {
                    :root {
                        --bg: #f8f9fa; --surface: #ffffff; --card: #e8ecf1;
                        --text: #1a1a2e; --text-muted: #6b7280;
                        --accent: #e94560; --success: #16a34a; --fail: #dc2626;
                        --border: #d1d5db;
                    }
                }
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif;
                    background: var(--bg); color: var(--text);
                    padding: 2rem; line-height: 1.6;
                }
                .container { max-width: 1200px; margin: 0 auto; }
                header {
                    display: flex; justify-content: space-between; align-items: center;
                    padding: 1.5rem 2rem; background: var(--surface);
                    border-radius: 12px; margin-bottom: 1.5rem;
                    border: 1px solid var(--border);
                }
                h1 { font-size: 1.5rem; font-weight: 700; }
                h1 span { color: var(--accent); }
                .meta { font-size: 0.85rem; color: var(--text-muted); text-align: right; }
                .summary {
                    display: grid; grid-template-columns: repeat(3, 1fr);
                    gap: 1rem; margin-bottom: 1.5rem;
                }
                .stat-card {
                    padding: 1.25rem; background: var(--surface);
                    border-radius: 10px; text-align: center;
                    border: 1px solid var(--border);
                }
                .stat-card .number { font-size: 2rem; font-weight: 800; }
                .stat-card .label { font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; }
                .stat-card.total .number { color: var(--accent); }
                .stat-card.success .number { color: var(--success); }
                .stat-card.failure .number { color: var(--fail); }
                table {
                    width: 100%; border-collapse: collapse;
                    background: var(--surface); border-radius: 10px;
                    overflow: hidden; border: 1px solid var(--border);
                }
                th {
                    background: var(--card); padding: 0.75rem 1rem;
                    text-align: left; font-size: 0.75rem;
                    text-transform: uppercase; letter-spacing: 0.05em;
                    color: var(--text-muted); font-weight: 600;
                }
                td { padding: 0.65rem 1rem; border-bottom: 1px solid var(--border); font-size: 0.85rem; }
                tr:last-child td { border-bottom: none; }
                .op-badge {
                    background: var(--card); padding: 0.2rem 0.6rem;
                    border-radius: 4px; font-size: 0.7rem; font-weight: 600;
                    letter-spacing: 0.03em;
                }
                .success { color: var(--success); font-weight: 600; }
                .failure { color: var(--fail); font-weight: 600; }
                .hash-cell { font-family: 'SF Mono', 'Menlo', monospace; font-size: 0.75rem; color: var(--text-muted); }
                .file-cell { max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
                .params-cell { font-size: 0.75rem; color: var(--text-muted); max-width: 150px; }
                footer {
                    margin-top: 1.5rem; text-align: center;
                    font-size: 0.75rem; color: var(--text-muted);
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <h1>🔐 <span>Marcrypt</span> Processing Receipt</h1>
                    <div class="meta">
                        <div>Generated: \(escapeHTML(generatedAt))</div>
                        <div>Marcrypt Document Security</div>
                    </div>
                </header>
                
                <div class="summary">
                    <div class="stat-card total">
                        <div class="number">\(events.count)</div>
                        <div class="label">Total Operations</div>
                    </div>
                    <div class="stat-card success">
                        <div class="number">\(successCount)</div>
                        <div class="label">Successful</div>
                    </div>
                    <div class="stat-card failure">
                        <div class="number">\(failureCount)</div>
                        <div class="label">Failed</div>
                    </div>
                </div>
                
                <table>
                    <thead>
                        <tr>
                            <th>#</th><th>Timestamp</th><th>Operation</th>
                            <th>Input File</th><th>Input Hash</th>
                            <th>Output File</th><th>Output Hash</th>
                            <th>Outcome</th><th>Parameters</th>
                        </tr>
                    </thead>
                    <tbody>
                        \(rows)
                    </tbody>
                </table>
                
                <footer>
                    <p>This receipt was automatically generated by Marcrypt and constitutes a record of document processing operations.</p>
                    <p>SHA-256 hashes are truncated for display. Full hashes are stored in the audit log.</p>
                </footer>
            </div>
        </body>
        </html>
        """
    }
    
    // MARK: - Helpers
    
    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

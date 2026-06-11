# Marcrypt Product Requirements Document (PRD)

**Version:** 1.0  
**Date:** 2026-02-13  
**Status:** Implemented

## 1. Executive Summary
Marcrypt is a secure document processing application designed for legal and professional environments. It provides batch encryption, watermarking, and Bates numbering for PDF and DOCX files. The system emphasizes password-based document protection, auditability, and ease of use through a drag-and-drop macOS interface.

## 2. Product Goals
*   **Security**: Ensure documents are encrypted with industry-standard algorithms.
*   **Compliance**: Provide robust Bates numbering and watermarking for legal discovery and classification.
*   **Efficiency**: Enable high-volume batch processing with sequential numbering logic.
*   **Accountability**: Maintain a tamper-evident audit trail of all operations.

## 3. Core Features

### 3.1. File Encryption
*   **PDF Encryption**:
    *   **Algorithm**: PDFKit standard password encryption; public claims must match the generated PDF encryption dictionary.
    *   **Features**: User (Open) Password, Owner (Permissions) Password.
    *   **Splitting**: Optional splitting of large PDFs into chunks (e.g., 10MB) before encryption.
*   **DOCX Encryption**:
    *   **Standard**: Office Open XML Crypto (Agile Encryption).
    *   **Features**: Password protection compatible with Microsoft Word.
*   **Overwrite & Remove Originals**: Optional best-effort cleanup feature that overwrites original files before removing them after processing, with clear SSD/APFS limitations.

### 3.2. Watermarking
*   **Text Watermarks**:
    *   **Content**: Customizable text (e.g., "CONFIDENTIAL", "DRAFT").
    *   **Appearance**:
        *   **Opacity**: Adjustable (0.0 - 1.0).
        *   **Size**: Adjustable font size (pts).
        *   **Color**: Customizable Hex color (User-selected via Color Picker).
        *   **Location**: 9 discrete positions (Top-Left to Bottom-Right) plus Diagonal.
    *   **Format Support**:
        *   **PDF**: Vector-based text overlay (under or over content).
        *   **DOCX**: VML Header Injection (compatible with Word 2007+).

### 3.3. Bates Numbering
*   **Functionality**:
    *   **Sequential Numbering**: Automatically chains numbers across multiple files in a batch (e.g., Doc 1: 001-005, Doc 2: 006-010).
    *   **Scope**: Applied to every page of the document.
*   **Configuration**:
    *   **Prefix**: Customizable string (e.g., "CASE-").
    *   **Start Number**: Manually definable starting integer.
    *   **Digit Count**: User-defined padding (e.g., 6 digits -> "000123").
    *   **Suffix/Timestamp**: Optional inclusion of a UNIX timestamp for forensic verification.
*   **Visual Customization**:
    *   **Font**: Selectable family (Sans Serif, Serif, Monospace).
    *   **Size & Color**: Independent of watermark settings.
    *   **Location**: Independent positioning (e.g., Bottom Right).
*   **Format Implementation**:
    *   **PDF**: Direct text drawing on page canvas.
    *   **DOCX**: Injection of VML Text Boxes containing Word Field Codes (`{ PAGE }`) to ensure dynamic, correct numbering even if the document is edited.

### 3.4. Audit Logging
*   **Format**: JSON Lines (`.jsonl`) for machine readability and append-only performance.
*   **Captured Data**:
    *   **Operation**: Encrypt, Watermark, Decrypt.
    *   **Timestamp**: UTC ISO-8601.
    *   **File Identity**: Filename, File Hash (MD5/SHA) before and after processing.
    *   **Parameters**: Applied Watermark Text, Bates Number Range, Encryption Settings.
    *   **Outcome**: Success/Failure status and error messages.

## 4. User Interface (UI) Requirements
*   **Settings View**:
    *   **Tabbed Config**: Separate sections for Encryption, Watermark, and Bates Numbering.
    *   **Live Validation**: Visual feedback for valid hex codes and number inputs.
    *   **Color Picker**: Native macOS color picker integration.
*   **Main View**:
    *   **Drag & Drop**: drop zone for adding files/folders.
    *   **Batch List**: Displays file status (Idle, Processing, Success, Failed).
    *   **Progress Monitoring**: Real-time progress bar and "Success/Total" counters.
    *   **Quick Actions**: "Reveal in Finder" for processed files.

## 5. Technical Requirements
*   **Platform**: macOS 14.0+ (Apple Silicon).
*   **Concurrency**:
    *   Utilize Swift Structured Concurrency (`async/await`, `TaskGroup`) for parallel processing.
    *   Ensure UI responsiveness (MainActor isolated UI updates).
*   **File Handling**:
    *   **Sandboxing**: Strict adherence to App Sandbox (Security Scoped Bookmarks).
    *   **Atomic Saves**: Write to temporary location -> Move to destination to prevent data corruption.
    *   **Context Preservation**: Maintain Bates sequence state across asynchronous tasks.
    *   **Public Beta DOCX Size Limit**: DOCX encryption/decryption is limited to 256 MB until the Office Crypto path is replaced with a streaming or temp-file-backed implementation.

## 6. Workflow Logic
1.  **Input**: User selects files (PDF, DOCX) and configures settings.
2.  **Initialization**:
    *   System reads `UserDefaults` for configuration.
    *   Sets initial `CurrentBatesNumber` = `StartNumber`.
3.  **Batch Loop**:
    *   **For Each File**:
        1.  Determine File Type.
        2.  **Processing**:
            *   **PDF**: Split (if needed) -> Watermark/Bates -> Encrypt -> Save.
            *   **DOCX**: Inject XML (Watermark/Bates) -> Encrypt (Office Crypto) -> Repackage -> Save.
        3.  **Sequence Update**:
            *   Extract Page Count (PDF metadata or DOCX `app.xml`).
            *   `CurrentBatesNumber` += `PageCount`.
        4.  **Audit**: Log operation details.
4.  **Completion**: Generate Batch Report (HTML/CSV) and notify user.

## 7. Future Scope
*   **PDF Splitting for DOCX**: Implement chunking for large Word documents.
*   **Advanced Formatting**: Rich text support for watermarks.
*   **Cloud Integration**: Direct upload to secure storage providers.

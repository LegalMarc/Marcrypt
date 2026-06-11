# Marcrypt 1.0 (Public Beta)

Marcrypt is local document encryption for legal professionals — batch-encrypt,
watermark, and Bates-number PDF, Word, and folder contents entirely on your Mac.
**Nothing is ever uploaded.**

## Highlights
- **AES-256 encryption** for Word/DOCX (Office Agile Encryption, opens natively
  in Word) and folders (WinZip AES-256 ZIP).
- **PDF encryption** — standard password-to-open protection (PDFKit), with a
  distinct owner/permissions password.
- **Watermarks & Bates numbering** for PDF and DOCX, with sequential numbering
  across a batch.
- **Metadata stripping** before encryption.
- **Word editing restrictions** (read-only, comments, tracked changes, forms).
- **Privacy by default** — no network access; audit/diagnostic logging off by
  default; one-click Clear History.

## Install
1. Download `Marcrypt.dmg` below.
2. Open it and drag Marcrypt to Applications.
3. macOS 14+ on Apple Silicon required. The build is signed and notarized.

## Known limitations (beta)
- PDF *decryption* (password removal) is not yet supported via the CLI; the app
  unlocks read-protected PDFs for viewing only.
- "Overwrite & Remove Original" is best-effort and cannot guarantee physical
  erasure on SSD/APFS storage.
- DOCX encryption currently supports documents up to 256 MB (streaming support
  is planned).
- Editing restrictions on Word documents are advisory and can be bypassed by
  non-Word editors.

## Feedback
Found a bug or have a request? Message me on
[LinkedIn](https://www.linkedin.com/in/marcmandel/) or open an issue.

MIT licensed. © 2026 Marc Mandel.

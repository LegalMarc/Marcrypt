# Marcrypt

**Local document encryption for legal professionals.** Batch-encrypt,
watermark, and Bates-number PDF, Word, and folder contents — entirely on your
Mac. Marcrypt never connects to the internet.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)

## Why Marcrypt

Legal and professional documents are confidential. Cloud encryption tools upload
your files to do their work. Marcrypt does everything locally — there is no
network code in the app, by design — so client data never leaves your machine.

## Features

- **Encryption**
  - **PDF** — password-to-open, with a distinct owner/permissions password.
  - **Word (DOCX)** — Microsoft Office Agile Encryption (AES-256), opens
    natively in Word.
  - **Folders / ZIP** — WinZip AES-256 archives.
- **Watermarking** — customizable text, size, opacity, color, and placement for
  PDF and DOCX.
- **Bates numbering** — sequential numbering across a batch, for legal
  discovery.
- **Metadata stripping** — remove Author/Title/Company/Producer and similar
  before encrypting.
- **Editing restrictions (DOCX)** — read-only, comments-only, tracked-changes,
  form-fill (advisory; honored by Word).
- **Batch processing** — drag in many files and folders at once.
- **Privacy controls** — audit history and verbose logging are off by default;
  one-click Clear History.

## Security model

- 100% local processing — no network access.
- Standard, audited cryptography via Apple frameworks (CommonCrypto, CryptoKit,
  PDFKit) and WinZip AES-256 for archives.
- "Overwrite & Remove Original" is best-effort cleanup; on SSD/APFS it cannot
  guarantee physical erasure (the app states this in-product).

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (arm64)

## Install

Download the latest signed, notarized build from the
[Releases](https://github.com/LegalMarc/Marcrypt/releases) page, open the DMG,
and drag Marcrypt to Applications.

## Build from source

```bash
git clone https://github.com/LegalMarc/Marcrypt.git
cd Marcrypt
swift build            # builds the app, CLI, and test harnesses
swift run Marcrypt     # run the app
swift test             # run the test suite
```

There is also a command-line interface:

```bash
swift run MarcryptCLI encrypt input.pdf output.pdf --password-stdin
swift run MarcryptCLI --help
```

## Command-line usage

Marcrypt ships a `MarcryptCLI` with `encrypt`, `decrypt`, `watermark`, `bates`,
`preflight`, and `clear-history` subcommands. Passwords are read interactively
(hidden) or via `--password-stdin`; they are never passed as plain arguments.

## Privacy

Marcrypt processes everything on-device and makes no network calls. Audit logs
and diagnostics are opt-in and locally stored; Clear History removes them.

## License

MIT © 2026 Marc Mandel. See [LICENSE](LICENSE).

Built with [ZipArchive](https://github.com/ZipArchive/ZipArchive) (MIT),
[swift-argument-parser](https://github.com/apple/swift-argument-parser)
(Apache-2.0), and POLE (BSD).

# CONTEXT — Marcrypt domain vocabulary

This file is a glossary only: the terms and concepts specific to this repo's
domain, not implementation details. It grows lazily, one entry at a time, as
terms get resolved in conversation.

## Document processing

**Bates numbering** — Sequential identifiers stamped across every page of a
batch, continuing across file boundaries, so a discovery production has one
unbroken page sequence. A legal-discovery convention, not a page number.

**Watermark** — Text drawn over page content with configurable size, opacity,
color, and placement. Applied to PDF and DOCX. Distinct from a Bates stamp:
a watermark labels the document, a Bates number identifies the page.

**Legal classification** — A preset stamp identity (`none`, `confidential`,
`privileged`, `workProduct`, `protectiveOrder`, `custom`), each carrying a
display name, watermark text, and color. Drives the default watermark for a
batch.

**Metadata stripping** — Removal of authoring metadata (Author, Title,
Company, Producer, and similar) before encryption, so the delivered file does
not leak who produced it or on what system.

**Editing restrictions (DOCX)** — Word-level protection modes (read-only,
comments-only, tracked-changes, form-fill). Advisory: honored by Word, not
cryptographically enforced.

## Encryption

**Agile Encryption** — Microsoft Office's AES-256 encryption scheme for OOXML
files. What Marcrypt writes for DOCX so the result opens natively in Word.

**Owner / permissions password** — In PDF, the password governing permissions,
kept distinct from the user (password-to-open) password. Setting only a user
password would leave permissions unprotected.

**WinZip AES-256** — The archive encryption standard used for folder and ZIP
output, chosen for interoperability with mainstream unzip tools.

**POLE** — The vendored C++ library for reading and writing OLE compound-file
structures, which legacy Office encryption containers require.

## Integrity and defensibility

**Audit trail** — An append-only, structured JSON event log of processing
operations, kept for legal defensibility. Opt-in and stored locally.

**Batch receipt** — A self-contained single-file HTML summary of one batch,
rendered from audit JSON with embedded CSS and JS, suitable for handing to a
client or opposing counsel.

**Batch report** — The combined HTML report covering a batch, with per-file
sections and deep-link anchors. Broader than a receipt.

**Integrity hash / sidecar** — A SHA-256 digest computed before and after an
operation to prove the payload was not altered in processing. Written beside
the output as a sidecar file.

**Pre-flight validation** — The checks run before a batch starts: disk space,
write permissions, and file accessibility. Catches a doomed batch before any
file is touched.

## Data handling

**Shredding / secure deletion** — Best-effort overwrite-then-remove of an
original file. On SSD and APFS this cannot guarantee physical erasure, and the
app says so in-product; treat it as cleanup, not forensic destruction.

**Clear History** — The one-click action that removes app-controlled history
and transient processing artifacts. Must never interrupt an active batch.

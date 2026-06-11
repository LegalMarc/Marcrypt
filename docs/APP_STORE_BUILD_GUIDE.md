# App Store And Direct Distribution Build Notes

This document is intentionally short because Marcrypt now keeps direct
distribution and App Store submission as separate operational paths.

## Public Repository Hygiene

Before any external beta, public repository share, or App Store publication,
verify that no real or realistic client, legal, personnel, or matter documents
are present in the current tree or in distributable artifacts. The
pre-public-beta audit removed sensitive-looking sample PDFs from the current
tree, but deleting files from the current checkout does not remove them from git
history. If this repository history will be shared outside trusted maintainers,
complete history cleanup first and validate with a fresh clone before release.

## Direct Distribution

Use `scripts/build_direct_release.sh` for signed DMG builds outside the Mac App
Store. The legacy `scripts/build_appstore_release.sh` filename remains as a
compatibility alias, but the build it performs is a direct-distribution build.

Direct distribution uses:

- A Developer ID Application certificate.
- Hardened runtime signing through `scripts/bundle_app.sh`.
- Optional notarization with `xcrun notarytool`.
- A DMG named `Marcrypt-v<version>-Direct.dmg` under `ignore-resources/dist/`.

Release builds fail closed if no signing identity is configured. Debug/local
bundles may still use ad-hoc signing through `scripts/bundle_app.sh`.

## App Store Submission

Use `scripts/submit_appstore.sh` only for App Store upload packaging. It rejects
ad-hoc signatures and Developer ID Application signatures before creating the
submission package.

App Store submission requires:

- An app bundle signed with Apple Distribution or 3rd Party Mac Developer
  Application.
- A 3rd Party Mac Developer Installer certificate for `productbuild`.
- App Store Connect API key credentials in `ASC_API_KEY_ID` and
  `ASC_API_ISSUER_ID`, with the private key in Apple's standard altool
  location.

Do not use the direct-distribution DMG as an App Store submission artifact.

## Export Compliance

**Determination (recorded 2026-06-10):** Marcrypt uses only standard, publicly
available cryptography via Apple OS frameworks and the WinZip AES-256 archive
format:

- PDF encryption via Apple PDFKit (standard password-based encryption).
- DOCX encryption via Apple CommonCrypto/CryptoKit (AES-256, MS-OFFCRYPTO
  Office Agile Encryption format).
- ZIP archive encryption via SSZipArchive/ZipArchive (WinZip AES-256).

No proprietary cryptography is implemented. As a publicly available, mass-market
application that uses only standard published encryption algorithms supplied by
the operating system and well-known open-source libraries, Marcrypt is classified
under U.S. Export Administration Regulations (EAR) ECCN 5D992.c (mass-market
encryption software) and qualifies for the corresponding export exemption.

**`ITSAppUsesNonExemptEncryption = true` is intentional.** This key is set to
`true` to trigger App Store Connect's encryption questionnaire at each
submission. At submission, answer:

1. "Does your app use encryption?" — **Yes.**
2. "Does your app qualify for the encryption exemption?" — **Yes** (mass-market
   exemption, ECCN 5D992.c, standard algorithms via Apple frameworks).

This approach ensures the exemption claim is documented in App Store Connect per
submission rather than relying on the `false` bypass, which is appropriate for
apps that do use encryption but qualify for an exemption. Do not change this
plist key without re-evaluating the questionnaire answers.

**Annual review:** Confirm this determination with qualified counsel or via
Apple's standard self-classification guidance at the start of each calendar
year, or any time the cryptographic approach changes materially.

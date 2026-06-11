#!/usr/bin/env python3
"""Validate that swift-test skips are intentional and exactly identified."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED_SKIPS: dict[str, str] = {
    "EncryptionTests.FullFlowTests.testE1_PDFFullCycle": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.FullFlowTests.testE3_EncryptPlusSecureDelete": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.FullFlowTests.testE5_BulkProcessing": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.FullFlowTests.testE6_WatermarkPlusEncrypt": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.PasswordGuessTests.testGuessPassword_PDF_Found": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.PasswordGuessTests.testGuessPassword_PDF_NotFound": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.DocxRealWorldCorruptionTests.testRealWorldDOCXFlowStructureIntegrity": "Set MARCRYPT_REALWORLD_DOCX_PATH to the RealWorld DOCX for fixture repro",
    "EncryptionTests.PdfServiceTests.testEncryptedPdfWithWatermark": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "EncryptionTests.PdfServiceTests.testPdfEncryption_LocksFile": "PDF encryption via CGContext requires application entitlements not available in swift test",
    "UITests.MarcryptUITests.testStress_InvalidFilePaths": "UI Tests require Xcode UI Runner, skipping in swift test CLI",
    "UITests.MarcryptUITests.testStress_RapidTabSwitching": "UI Tests require Xcode UI Runner, skipping in swift test CLI",
    "UITests.MarcryptUITests.testStress_SettingsToggle": "UI Tests require Xcode UI Runner, skipping in swift test CLI",
}

SKIP_RE = re.compile(r"-\[(?P<suite>\S+) (?P<test>[^\]]+)\] : Test skipped - (?P<reason>.+)$")


def parse_skips(log_text: str) -> dict[str, str]:
    skips: dict[str, str] = {}
    for line in log_text.splitlines():
        if "Test skipped -" not in line:
            continue
        match = SKIP_RE.search(line)
        if not match:
            raise SystemExit(f"Could not parse skipped test line:\n{line}")
        identifier = f"{match.group('suite')}.{match.group('test')}"
        skips[identifier] = match.group("reason")
    return skips


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_test_skips.py <swift-test-log>", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1])
    skips = parse_skips(log_path.read_text(encoding="utf-8", errors="replace"))

    unexpected: list[str] = []
    wrong_reason: list[str] = []
    for identifier, reason in sorted(skips.items()):
        expected_reason = EXPECTED_SKIPS.get(identifier)
        if expected_reason is None:
            unexpected.append(f"{identifier}: {reason}")
        elif reason != expected_reason:
            wrong_reason.append(f"{identifier}: expected {expected_reason!r}, got {reason!r}")

    if unexpected or wrong_reason:
        if unexpected:
            print("Unexpected skipped tests:")
            print("\n".join(unexpected))
        if wrong_reason:
            print("Skipped tests with unexpected reasons:")
            print("\n".join(wrong_reason))
        return 1

    resolved = sorted(set(EXPECTED_SKIPS) - set(skips))
    print(f"Allowlisted skipped tests: {len(skips)}")
    if resolved:
        print("Previously allowlisted skips no longer present:")
        for identifier in resolved:
            print(f"- {identifier}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

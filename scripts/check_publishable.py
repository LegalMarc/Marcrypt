#!/usr/bin/env python3
"""Publish-safety guard for the public Marcrypt repository.

Fails (exit 1) if the git-tracked tree — i.e. anything that would actually be
published — contains either:

  1. A confidential/binary document file (PDF, Word, Excel, PowerPoint, iWork,
     RTF, ZIP, ...). Such files may carry client or personal data and must never
     be committed. Real sample documents belong in the git-ignored
     `ignore-resources/` tree, never in version control.

  2. Forbidden text: client/company identifiers, sibling-project codenames,
     internal backlog ticket ids, or an Apple app-specific-password-format
     token. These leaked into the repo during development and must stay out.

Only git-tracked files are scanned (untracked / git-ignored working files are
irrelevant to what gets published). Run by scripts/test_all.sh and the
public-beta GitHub Actions workflow so a regression fails CI before release.

If a genuinely non-confidential, synthetic fixture ever needs to be tracked,
add a narrow, reviewed exception to ALLOWLIST below.
"""
from __future__ import annotations

import re
import subprocess
import sys

# Document/binary extensions that may contain client or personal data.
FORBIDDEN_EXTS = {
    ".pdf", ".doc", ".docx", ".dot", ".dotx",
    ".xls", ".xlsx", ".ppt", ".pptx",
    ".pages", ".numbers", ".key",
    ".rtf", ".odt", ".ods", ".odp", ".zip",
}

# Forbidden content. (pattern, human-readable reason)
FORBIDDEN_PATTERNS = [
    (r"\bGGH\b", "client identifier 'GGH'"),
    (r"(?i)smartfrog", "client/company name 'Smartfrog'"),
    (r"\bMarcut\b", "sibling-project codename 'Marcut'"),
    (r"Bulk PDF Decrypt", "legacy project name 'Bulk PDF Decrypt'"),
    (r"\bLB-\d+\b", "internal backlog ticket id (LB-NN)"),
    (r"\bPB-\d+\b", "internal backlog ticket id (PB-NN)"),
    (r"(?i)(?:password|passwd|pwd|secret|app-?specific|notariz)\w*[\"'\s:=]+[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}\b",
     "app-specific-password-format token in a credential context"),
    (r"(?i)(NOTARIZATION_PASSWORD|APP_SPECIFIC_PASSWORD)\s*=\s*[\"']?(?!\s|\"|'|\$|<)\S",
     "hardcoded notarization/app-specific password"),
]

# Paths exempt from the *content* scan (not the extension scan).
# This guard names the forbidden strings, so it must not scan itself.
ALLOWLIST = {
    "scripts/check_publishable.py",
}


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, text=True, check=True
    ).stdout
    return [f for f in out.split("\0") if f]


def looks_textual(path: str) -> bool:
    try:
        with open(path, "rb") as fh:
            return b"\x00" not in fh.read(8192)
    except OSError:
        return False


def main() -> int:
    files = tracked_files()
    ext_hits: list[str] = []
    content_hits: list[tuple[str, int, str, str]] = []

    for f in files:
        dot = f.lower().rfind(".")
        ext = f.lower()[dot:] if dot != -1 else ""
        if ext in FORBIDDEN_EXTS:
            ext_hits.append(f)
            continue
        if f in ALLOWLIST or not looks_textual(f):
            continue
        try:
            with open(f, "r", encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        for pattern, reason in FORBIDDEN_PATTERNS:
            m = re.search(pattern, text)
            if m:
                line = text.count("\n", 0, m.start()) + 1
                content_hits.append((f, line, reason, m.group(0)))

    ok = True
    if ext_hits:
        ok = False
        print("ERROR: tracked confidential/binary document files (never publish these):")
        for f in ext_hits:
            print(f"  - {f}")
    if content_hits:
        ok = False
        print("ERROR: tracked files contain forbidden content:")
        for f, line, reason, match in content_hits:
            print(f"  - {f}:{line}: {reason}  (matched: {match!r})")

    if ok:
        print(f"check_publishable: OK — {len(files)} tracked files, no confidential "
              "documents or forbidden content.")
        return 0

    print()
    print("These must not be published. Remove the file(s) from git (they may remain on")
    print("disk if git-ignored), or scrub the content. Real sample documents belong under")
    print("the git-ignored ignore-resources/ tree. If a synthetic, non-confidential fixture")
    print("is genuinely required, add a narrow exception to ALLOWLIST in this script.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

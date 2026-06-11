#!/usr/bin/env python3
"""Validate Marcrypt app metadata has one authoritative source."""

from __future__ import annotations

import plistlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "Marcrypt/Marcrypt/Info.plist"
PROJECT = ROOT / "Marcrypt/Marcrypt.xcodeproj/project.pbxproj"
DIRECT_BUILD = ROOT / "scripts/build_appstore_release.sh"


def fail(message: str) -> int:
    print(f"Metadata consistency check failed: {message}")
    return 1


def main() -> int:
    info = plistlib.loads(INFO_PLIST.read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]

    project = PROJECT.read_text(encoding="utf-8")
    app_configs = re.findall(
        r"GENERATE_INFOPLIST_FILE = (?P<generate>[^;]+);(?P<body>.*?)PRODUCT_BUNDLE_IDENTIFIER = (?P<bundle>[^;]+);",
        project,
        flags=re.S,
    )
    app_bundles = [bundle.strip().strip('"') for generate, body, bundle in app_configs if bundle.strip().strip('"') == bundle_id]

    if not app_bundles:
        return fail(f"project does not contain app bundle id {bundle_id}")
    if "INFOPLIST_FILE = Marcrypt/Info.plist;" not in project:
        return fail("app target must reference Marcrypt/Info.plist")
    if re.search(r"PRODUCT_BUNDLE_IDENTIFIER = " + re.escape(bundle_id) + r";(?:(?!};).)*GENERATE_INFOPLIST_FILE = YES;", project, flags=re.S):
        return fail("app target must not generate an independent Info.plist")

    direct = DIRECT_BUILD.read_text(encoding="utf-8")
    required_fragments = [
        "INFO_PLIST=",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "CFBundleIdentifier",
    ]
    missing = [fragment for fragment in required_fragments if fragment not in direct]
    if missing:
        return fail(f"direct build script does not read plist metadata: {missing}")

    print(f"Metadata consistency check passed ({bundle_id} {version} build {build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

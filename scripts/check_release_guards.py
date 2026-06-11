#!/usr/bin/env python3
"""Static release-path guard checks for credential-free validation."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    failures: list[str] = []

    direct = read("scripts/build_appstore_release.sh")
    wrapper = read("scripts/build_direct_release.sh")
    bundle = read("scripts/bundle_app.sh")
    submit = read("scripts/submit_appstore.sh")
    tui = read("scripts/build_tui.sh")

    require('DMG_NAME="${APP_NAME}-v${VERSION}-Direct"' in direct, "direct build DMG must use -Direct name", failures)
    require("REQUIRE_SIGNING_IDENTITY=1" in direct, "direct release must require signing identity", failures)
    require("Signing identity" in direct and "exit 1" in direct, "direct release must fail on missing signing identity", failures)
    require("Signature=adhoc" in direct and "refusing to continue" in direct, "direct release must reject ad-hoc signatures", failures)
    require("--skip-notarization" in direct and "Skipping notarization validation" in direct, "direct release must support skip-notarization validation path", failures)

    require('exec "${SCRIPT_DIR}/build_appstore_release.sh" "$@"' in wrapper, "build_direct_release wrapper must delegate all args", failures)

    require('SIGNING_IDENTITY="${SIGNING_IDENTITY:-${DEVELOPER_ID:-}}"' in bundle, "bundle_app must map DEVELOPER_ID to SIGNING_IDENTITY", failures)
    require('APPLE_TEAM_ID="${APPLE_TEAM_ID:-${TEAM_ID:-}}"' in bundle, "bundle_app must map TEAM_ID to APPLE_TEAM_ID", failures)
    require('REQUIRE_SIGNING_IDENTITY:-0' in bundle and "No signing identity configured" in bundle, "bundle_app must fail closed when signing is required", failures)

    require("Signature=adhoc" in submit and "refusing App Store packaging" in submit, "App Store submit must reject ad-hoc app bundles", failures)
    require("Authority=Developer ID Application" in submit and "not the Mac App Store" in submit, "App Store submit must reject Developer ID app bundles", failures)
    require("Authority=(Apple Distribution|3rd Party Mac Developer Application)" in submit, "App Store submit must require App Store-compatible authority", failures)
    require("ASC_API_KEY_ID" in submit and "ASC_API_ISSUER_ID" in submit, "App Store submit must require API key credentials", failures)

    require("build_direct_release.sh" in tui, "build TUI must use direct release entrypoint", failures)
    require("scripts/test_all.sh" in tui, "build TUI test option must use test_all gate", failures)

    if failures:
        print("Release guard check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("Release guard check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

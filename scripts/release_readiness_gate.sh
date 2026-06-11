#!/bin/bash
#
# Release-grade validation gate. This is intentionally stricter than
# scripts/test_all.sh and should be run before any external beta or release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
cd "${ROOT_DIR}"

missing=()
for tool in qpdf soffice; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        missing+=("${tool}")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required release verification tool(s): ${missing[*]}" >&2
    exit 1
fi

RUN_SIGNED_APP_SMOKE=1 \
RUN_XCODE_UI_TESTS=1 \
RUN_RELEASE_DRY_RUN=1 \
scripts/test_all.sh

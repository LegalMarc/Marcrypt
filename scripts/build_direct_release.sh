#!/bin/bash
#
# Preferred entrypoint for direct-distribution DMG builds.
# The legacy build_appstore_release.sh filename is retained for compatibility.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/build_appstore_release.sh" "$@"

#!/bin/bash
#
# Marcrypt public-beta validation gate.
#
# Default mode is credential-free and suitable for local development/CI.
# Optional gates are enabled with:
#   RUN_SIGNED_APP_SMOKE=1
#   RUN_XCODE_UI_TESTS=1
#   RUN_RELEASE_DRY_RUN=1
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
LOG_DIR="${ROOT_DIR}/ignore-resources/test-logs"
mkdir -p "${LOG_DIR}"

SWIFT_TEST_LOG="${LOG_DIR}/swift-test.log"
CLI_LOG="${LOG_DIR}/cli-harness.log"
CORE_LOG="${LOG_DIR}/core-e2e-harness.log"
COMPLIANCE_LOG="${LOG_DIR}/compliance.log"
RELEASE_GUARDS_LOG="${LOG_DIR}/release-guards.log"
METADATA_LOG="${LOG_DIR}/metadata-consistency.log"
SIGNED_APP_LOG="${LOG_DIR}/signed-app-smoke.log"
XCODE_UI_LOG="${LOG_DIR}/xcode-ui.log"
RELEASE_DRY_RUN_LOG="${LOG_DIR}/release-dry-run.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_step() { echo -e "${BLUE}▶ $1${NC}"; }
log_success() { echo -e "${GREEN}✓ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
log_error() { echo -e "${RED}✗ $1${NC}"; }

run_logged() {
    local label="$1"
    local logfile="$2"
    shift 2

    log_step "${label}"
    if "$@" 2>&1 | tee "${logfile}"; then
        log_success "${label}"
    else
        log_error "${label}"
        echo "Log: ${logfile}"
        exit 1
    fi
}

check_bundle_identifier_consistency() {
    log_step "Bundle identifier consistency"

    local plist_id project_id
    plist_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${ROOT_DIR}/Marcrypt/Marcrypt/Info.plist")"
    project_id="$(grep -E 'PRODUCT_BUNDLE_IDENTIFIER = ' "${ROOT_DIR}/Marcrypt/Marcrypt.xcodeproj/project.pbxproj" | sed -E 's/.*PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;.*/\1/' | grep -v 'Tests' | head -n 1)"

    if [ -z "${project_id}" ]; then
        log_error "Could not find project app bundle identifier"
        exit 1
    fi

    if [ "${plist_id}" != "${project_id}" ]; then
        log_error "Bundle identifier mismatch: Info.plist=${plist_id}, project=${project_id}"
        exit 1
    fi

    log_success "Bundle identifier consistency (${plist_id})"
}

run_signed_app_smoke() {
    log_step "Signed app smoke"
    {
        cd "${ROOT_DIR}"
        scripts/build_direct_release.sh --skip-notarization

        local app_binary="${ROOT_DIR}/ignore-resources/build/Marcrypt.app/Contents/MacOS/Marcrypt"
        if [ ! -x "${app_binary}" ]; then
            echo "Missing app binary: ${app_binary}"
            exit 1
        fi

        if codesign -dvv "${ROOT_DIR}/ignore-resources/build/Marcrypt.app" 2>&1 | grep -q "Signature=adhoc"; then
            echo "Signed app smoke requires a non-ad-hoc signature"
            exit 1
        fi

        printf "signed-smoke-password\n" | "${app_binary}" --headless-smoke --password-stdin
    } 2>&1 | tee "${SIGNED_APP_LOG}"
    log_success "Signed app smoke"
}

run_xcode_ui_tests() {
    log_step "Xcode UI tests"
    {
        cd "${ROOT_DIR}"
        local derived_data xctestrun
        derived_data="${ROOT_DIR}/ignore-resources/xcode-ui-derived"
        rm -rf "${derived_data}"

        xcodebuild build-for-testing \
            -project Marcrypt/Marcrypt.xcodeproj \
            -scheme "Marcrypt" \
            -destination 'platform=macOS' \
            "-only-testing:Marcrypt UITests" \
            -derivedDataPath "${derived_data}"

        xctestrun="$(find "${derived_data}/Build/Products" -name '*.xctestrun' -print -quit)"
        if [ -z "${xctestrun}" ]; then
            echo "Missing Xcode UI test run specification"
            exit 1
        fi

        /usr/libexec/PlistBuddy -c "Set :TestConfigurations:0:TestTargets:0:UITargetAppPath __TESTROOT__/Debug/Marcrypt.app" "${xctestrun}"
        /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:MARCRYPT_RUN_UI_TESTS string 1" "${xctestrun}" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :TestConfigurations:0:TestTargets:0:EnvironmentVariables:MARCRYPT_RUN_UI_TESTS 1" "${xctestrun}"

        xcodebuild test-without-building \
            -xctestrun "${xctestrun}" \
            -destination 'platform=macOS'
    } 2>&1 | tee "${XCODE_UI_LOG}"
    if grep -q "Test skipped" "${XCODE_UI_LOG}"; then
        log_error "Xcode UI tests were skipped"
        echo "Log: ${XCODE_UI_LOG}"
        exit 1
    fi
    log_success "Xcode UI tests"
}

run_release_dry_run() {
    log_step "Release dry run"
    {
        cd "${ROOT_DIR}"
        scripts/build_direct_release.sh --skip-notarization
        test -d "ignore-resources/build/Marcrypt.app"
        ls ignore-resources/dist/Marcrypt-v*-Direct.dmg
    } 2>&1 | tee "${RELEASE_DRY_RUN_LOG}"
    log_success "Release dry run"
}

main() {
    cd "${ROOT_DIR}"

    run_logged "git diff whitespace check" "${LOG_DIR}/git-diff-check.log" git diff --check
    run_logged "shell syntax checks" "${LOG_DIR}/shell-syntax.log" bash -n \
        scripts/build_appstore_release.sh \
        scripts/build_direct_release.sh \
        scripts/build_tui.sh \
        scripts/submit_appstore.sh \
        scripts/bundle_app.sh \
        scripts/test_all.sh \
        scripts/release_readiness_gate.sh
    run_logged "release guard checks" "${RELEASE_GUARDS_LOG}" python3 scripts/check_release_guards.py
    run_logged "metadata consistency checks" "${METADATA_LOG}" python3 scripts/check_metadata_consistency.py

    run_logged "swift test" "${SWIFT_TEST_LOG}" swift test --disable-index-store
    run_logged "swift test skip allowlist" "${LOG_DIR}/swift-test-skips.log" python3 scripts/check_test_skips.py "${SWIFT_TEST_LOG}"

    run_logged "CLI harness" "${CLI_LOG}" bash -c 'swift build --product MarcryptCLI --product CLIHarness && .build/debug/CLIHarness'
    run_logged "Core E2E harness" "${CORE_LOG}" bash -c 'swift build --product CoreE2EHarness && .build/debug/CoreE2EHarness'
    run_logged "compliance scan" "${COMPLIANCE_LOG}" python3 scripts/audit_compliance.py \
        Marcrypt/Marcrypt/Marcrypt.entitlements \
        Marcrypt/Marcrypt/Info.plist
    check_bundle_identifier_consistency

    if [ "${RUN_SIGNED_APP_SMOKE:-0}" = "1" ]; then
        run_signed_app_smoke
    else
        log_warning "Skipping signed app smoke. Set RUN_SIGNED_APP_SMOKE=1 to enable."
    fi

    if [ "${RUN_XCODE_UI_TESTS:-0}" = "1" ]; then
        run_xcode_ui_tests
    else
        log_warning "Skipping Xcode UI tests. Set RUN_XCODE_UI_TESTS=1 to enable."
    fi

    if [ "${RUN_RELEASE_DRY_RUN:-0}" = "1" ]; then
        run_release_dry_run
    else
        log_warning "Skipping release dry run. Set RUN_RELEASE_DRY_RUN=1 to enable."
    fi

    log_success "Default public-beta validation gate passed"
    echo "Logs: ${LOG_DIR}"
}

main "$@"

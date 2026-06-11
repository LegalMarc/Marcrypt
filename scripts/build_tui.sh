#!/bin/bash

# build_tui.sh
# Interactive build menu for Marcrypt

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
CD_YELLOW='\033[0;33m'
nc='\033[0m' # No Color

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${ROOT_DIR}/.env"

# Load environment variables if they exist
if [ -f "${ENV_FILE}" ]; then
    set -a
    source "${ENV_FILE}"
    set +a
fi

# Compatibility mapping
if [ -z "${TEAM_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    export TEAM_ID="${APPLE_TEAM_ID}"
fi

print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${nc}"
    echo -e "${CYAN}║                   Marcrypt Build System                      ║${nc}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${nc}"
    echo ""
}

wait_for_enter() {
    echo ""
    # Reset stdin flags to fix "Resource temporarily unavailable"
    # This happens because some commands (like swift build or hdiutil) might leave stdin in non-blocking mode
    if [ -t 0 ]; then
         stty sane < /dev/tty || true
    fi
    echo "Press [Enter] to continue..."
    read -r < /dev/tty
}

check_credentials() {
    if [ -z "${TEAM_ID:-}" ] || [ -z "${NOTARIZATION_PROFILE:-}" ]; then
        echo -e "${RED}Error: Missing credentials.${nc}"
        echo "Please ensure TEAM_ID and NOTARIZATION_PROFILE are set."
        echo "Store notarization credentials with xcrun notarytool store-credentials."
        return 1
    fi
    return 0
}

update_dependencies() {
    echo -e "${BLUE}Updating Swift dependencies...${nc}"
    cd "${ROOT_DIR}"
    swift package resolve
    echo -e "${GREEN}Done.${nc}"
}

increment_and_build_dmg() {
    echo -e "${BLUE}Starting Build Process...${nc}"
    
    # 1. Increment Version
    "${SCRIPT_DIR}/increment_version.sh"
    
    # 2. Build DMG
    # We pass the loaded env vars to the build script
    "${SCRIPT_DIR}/build_direct_release.sh" \
        --skip-notarization \
        --developer-id="${DEVELOPER_ID:-}" \
        --team-id="${TEAM_ID:-}"
        
    echo -e "${GREEN}Build Complete.${nc}"
    
    # Auto-open the app for testing
    APP_PATH="${ROOT_DIR}/Marcrypt.app"
    if [ -d "$APP_PATH" ]; then
        echo -e "${BLUE}Opening App...${nc}"
        open "$APP_PATH"
    fi
}

full_direct_release() {
    if ! check_credentials; then return; fi

    echo -e "${BLUE}Starting Full Direct Release...${nc}"
    
    # 1. Increment Version
    "${SCRIPT_DIR}/increment_version.sh"
    
    # 2. Build, Sign, Notarize using a notarytool Keychain profile.
    
    "${SCRIPT_DIR}/build_direct_release.sh" \
        --developer-id="${DEVELOPER_ID:-}" \
        --team-id="${TEAM_ID:-}"
        
    echo -e "${GREEN}Release build ready. Check output for DMG.${nc}"
}

# ========================================
# Test Runner Functions
# ========================================

run_all_tests() {
    echo -e "${BLUE}Running All Feature Verification Tests...${nc}"
    echo ""
    cd "${ROOT_DIR}"
    
    if scripts/test_all.sh 2>&1 | tee /tmp/marcrypt_test_results.log; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════╗${nc}"
        echo -e "${GREEN}║       ✓ ALL TESTS PASSED             ║${nc}"
        echo -e "${GREEN}╚══════════════════════════════════════╝${nc}"
    else
        echo ""
        echo -e "${RED}╔══════════════════════════════════════╗${nc}"
        echo -e "${RED}║       ✗ SOME TESTS FAILED            ║${nc}"
        echo -e "${RED}╚══════════════════════════════════════╝${nc}"
        echo ""
        echo -e "${CD_YELLOW}Failed tests:${nc}"
        grep -E "failed|error:" /tmp/marcrypt_test_results.log | head -20
    fi
    
    echo ""
    echo -e "${CYAN}Test log saved to: /tmp/marcrypt_test_results.log${nc}"
}

run_unit_tests() {
    echo -e "${BLUE}Running Unit Tests Only...${nc}"
    echo ""
    cd "${ROOT_DIR}"
    
    swift test --filter "UnitTests" 2>&1 | tee /tmp/marcrypt_unit_tests.log
    
    if grep -q "passed" /tmp/marcrypt_unit_tests.log; then
        echo -e "${GREEN}✓ Unit Tests Passed${nc}"
    else
        echo -e "${RED}✗ Unit Tests Failed${nc}"
    fi
}

run_e2e_tests() {
    echo -e "${BLUE}Running End-to-End Tests...${nc}"
    echo ""
    cd "${ROOT_DIR}"
    
    swift test --filter "EndToEndTests" 2>&1 | tee /tmp/marcrypt_e2e_tests.log
    
    if grep -q "passed" /tmp/marcrypt_e2e_tests.log; then
        echo -e "${GREEN}✓ E2E Tests Passed${nc}"
    else
        echo -e "${RED}✗ E2E Tests Failed${nc}"
    fi
}

build_and_run_debug() {
    echo -e "${BLUE}Building and Running (Debug Mode)...${nc}"
    "${SCRIPT_DIR}/bundle_app.sh" --debug
    
    APP_PATH="${ROOT_DIR}/Marcrypt.app"
    if [ -d "$APP_PATH" ]; then
        echo -e "${BLUE}Opening App...${nc}"
        open "$APP_PATH"
    fi
}

# Main Menu Loop

while true; do
    print_header
    echo "1) Update Dependencies (Swift Packages)"
    echo "2) Manually Increment Version"
    echo "3) Build Local Release (DMG, no notarization)"
    echo "4) Build Full Direct Release (DMG + Notarize)"
    echo "5) Upload to App Store (Creates PKG & Uploads)"
    echo "6) Exit"
    echo -e "${CYAN}--- Development ---${nc}"
    echo "10) Build and Run (Debug)"
    echo -e "${CYAN}--- Testing ---${nc}"
    echo "7) Run All Feature Verification Tests"
    echo "8) Run Unit Tests Only"
    echo "9) Run End-to-End Tests Only"
    echo ""
    # Explicitly read from tty to handle potential stdin issues
    if [ -t 0 ]; then stty sane; fi
    printf "Select an option: "
    read -r choice < /dev/tty

    case $choice in
        1)
            update_dependencies
            wait_for_enter
            ;;
        2)
            "${SCRIPT_DIR}/increment_version.sh"
            wait_for_enter
            ;;
        3)
            # Local build logic (increments version automatically per user request)
            increment_and_build_dmg
            wait_for_enter
            ;;
        4)
            full_direct_release
            wait_for_enter
            ;;
        5)
            echo -e "${BLUE}Starting App Store Submission...${nc}"
            "${SCRIPT_DIR}/submit_appstore.sh"
            wait_for_enter
            ;;
        6)
            echo "Goodbye!"
            exit 0
            ;;
        7)
            run_all_tests
            wait_for_enter
            ;;
        8)
            run_unit_tests
            wait_for_enter
            ;;
        9)
            run_e2e_tests
            wait_for_enter
            ;;
        10)
            build_and_run_debug
            wait_for_enter
            ;;
        *)
            echo -e "${RED}Invalid option.${nc}"
            sleep 1
            ;;
    esac
done

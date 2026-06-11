#!/bin/bash
#
# Direct Distribution Build Script for Marcrypt
# Creates a signed and notarized DMG for direct distribution
# Legacy filename retained for existing automation; prefer build_direct_release.sh.
#
set -euo pipefail

# ===== CONFIGURATION =====
APP_NAME="Marcrypt"
BUNDLE_ID="com.marclaw.Marcrypt"

# Signing Configuration - UPDATE THESE WITH YOUR CREDENTIALS
DEVELOPER_ID="Developer ID Application: Marc Mandel (QG85EMCQ75)"
TEAM_ID="QG85EMCQ75"

# Paths (absolute to avoid cwd issues)
# Get the directory of this script, then go up one level to find repo root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}/.."
INFO_PLIST="${ROOT_DIR}/Marcrypt/Marcrypt/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")"

# Load environment variables if .env exists
ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
    source "${ENV_FILE}"
fi

# Default credentials (can be overridden by .env or command line)
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Marc Mandel (QG85EMCQ75)}"
TEAM_ID="${TEAM_ID:-QG85EMCQ75}"

BUILD_DIR="${ROOT_DIR}/ignore-resources/build"
ARCHIVE_DIR="${ROOT_DIR}/ignore-resources/archive"
# SPM builds to .build/release, bundle_app.sh creates Marcrypt.app at root
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
ARCHIVE_PATH="${ARCHIVE_DIR}/${APP_NAME}.xcarchive"
DMG_NAME="${APP_NAME}-v${VERSION}-Direct"
DIST_DIR="${ROOT_DIR}/ignore-resources/dist"
mkdir -p "${DIST_DIR}"
FINAL_DMG="${DIST_DIR}/${DMG_NAME}.dmg"
VOLUME_NAME="${APP_NAME}"
# Entitlements path for SPM structure
ENTITLEMENTS="${ROOT_DIR}/Marcrypt/Marcrypt/Marcrypt.entitlements"
# Fallback if old structure
if [ ! -f "${ENTITLEMENTS}" ]; then
    ENTITLEMENTS="${ROOT_DIR}/Sources/Marcrypt/Marcrypt.entitlements"
fi

# Notarization Configuration. Create with:
# xcrun notarytool store-credentials "${NOTARIZATION_PROFILE}" --apple-id "..." --team-id "${TEAM_ID}" --password "..."
NOTARIZATION_PROFILE="${NOTARIZATION_PROFILE:-marcrypt-notary-profile}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ===== UTILITY FUNCTIONS =====
log_section() {
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}  $1${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo -e "${CYAN}▶️  $1${NC}"
}

# ===== VALIDATION =====
check_prerequisites() {
    log_section "Checking Prerequisites"

    # Check for Swift
    if ! command -v swift &> /dev/null; then
        log_error "Swift not found"
        log_info "Install Xcode or Swift toolchain"
        exit 1
    fi
    log_success "Swift found: $(swift --version | head -n 1)"

    # Check for signing identity. Release builds fail closed; bundle_app.sh is also
    # invoked with REQUIRE_SIGNING_IDENTITY=1 as a second guard.
    if ! security find-identity -v -p codesigning | grep -q "${DEVELOPER_ID}"; then
        log_error "Signing identity '${DEVELOPER_ID}' not found"
        log_info "Available identities:"
        security find-identity -v -p codesigning
        log_info "Set DEVELOPER_ID or SIGNING_IDENTITY to a valid Developer ID Application certificate."
        exit 1
    else
        log_success "Signing identity found"
    fi

    # Check for entitlements file
    if [ ! -f "${ENTITLEMENTS}" ]; then
        log_error "Entitlements file not found: ${ENTITLEMENTS}"
        exit 1
    fi
    log_success "Entitlements file found"

    # Check for Package.swift
    if [ ! -f "${ROOT_DIR}/Package.swift" ]; then
        log_error "Package.swift not found at ${ROOT_DIR}"
        exit 1
    fi
    log_success "Package.swift found"
}

# ===== BUILD (CLI) =====
build_project() {
    log_section "Building Project (CLI)"

    # Clean previous builds
    log_step "Cleaning previous builds..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    # Use the bundle_app.sh script
    log_step "Running bundle_app.sh..."

    # Run bundle_app.sh. Release builds must fail closed if signing is not configured.
    if REQUIRE_SIGNING_IDENTITY=1 SIGNING_IDENTITY="${DEVELOPER_ID}" TEAM_ID="${TEAM_ID}" "${SCRIPT_DIR}/bundle_app.sh"; then
        log_success "Build and Bundle successful"
    else
        log_error "Build failed"
        exit 1
    fi

    # Check if app exists at root (bundle_app.sh default output) or check bundle_app.sh output
    # bundle_app.sh creates or replaces ./Marcrypt.app in CWD (Project Root)

    SOURCE_APP="${ROOT_DIR}/${APP_NAME}.app"

    if [ -d "${SOURCE_APP}" ]; then
        log_step "Moving app to build dir..."
        mv "${SOURCE_APP}" "${APP_BUNDLE}"
    else
        log_error "App bundle not found at ${SOURCE_APP}"
        exit 1
    fi
}

# Export step is no longer needed as bundle_app.sh produces the .app
export_app_from_archive() {
    log_info "Skipping export (handled by bundle_app.sh)"
}

# ===== VERIFY CODE SIGNING =====
verify_code_signing() {
    log_section "Verifying Code Signature"

    # Verify signature
    log_step "Verifying code signature..."
    if codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"; then
        log_success "Code signature verified"
    else
        log_error "Code signature verification failed"
        exit 1
    fi

    # Check signature details
    log_step "Signature details:"
    codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E "(Authority|TeamIdentifier|Timestamp|Identifier)" || true

    if codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -q "Signature=adhoc"; then
        log_error "Release app is ad-hoc signed; refusing to continue."
        exit 1
    fi
}

# ===== CREATE DMG =====
create_dmg() {
    log_section "Creating DMG Installer"

    # Clean previous DMG
    rm -f "${FINAL_DMG}" "${DMG_NAME}-temp.dmg"

    # Create a temporary folder for DMG contents
    DMG_TEMP_DIR="${BUILD_DIR}/dmg_temp"
    rm -rf "${DMG_TEMP_DIR}"
    mkdir -p "${DMG_TEMP_DIR}"

    # Copy app to DMG temp directory
    log_step "Preparing DMG contents..."
    cp -R "${APP_BUNDLE}" "${DMG_TEMP_DIR}/"

    # Create DMG from folder
    log_step "Creating DMG..."
    hdiutil create -volname "${VOLUME_NAME}" \
        -srcfolder "${DMG_TEMP_DIR}" \
        -ov -format UDZO \
        "${DMG_NAME}-temp.dmg"

    # Sign the DMG
    log_step "Signing DMG..."
    codesign --force --sign "${DEVELOPER_ID}" \
        --timestamp \
        "${DMG_NAME}-temp.dmg"

    mv "${DMG_NAME}-temp.dmg" "${FINAL_DMG}"

    log_success "DMG created: ${FINAL_DMG}"
    log_info "Size: $(du -sh "${FINAL_DMG}" | cut -f1)"
}

# ===== NOTARIZATION =====
notarize_dmg() {
    log_section "Notarizing for Distribution"

    if [ -z "${NOTARIZATION_PROFILE}" ]; then
        log_error "Missing NOTARIZATION_PROFILE"
        log_info "Store credentials with xcrun notarytool store-credentials"
        exit 1
    fi

    log_info "Using notarytool keychain profile: ${NOTARIZATION_PROFILE}"

    log_step "Submitting DMG for notarization (this may take a few minutes)..."
    NOTARIZATION_OUTPUT=$(xcrun notarytool submit "${FINAL_DMG}" \
        --keychain-profile "${NOTARIZATION_PROFILE}" \
        --wait 2>&1)

    echo "$NOTARIZATION_OUTPUT"

    SUBMISSION_ID=$(echo "$NOTARIZATION_OUTPUT" | grep -E "id: [a-f0-9-]+" | head -1 | awk '{print $2}')

    if [ -z "$SUBMISSION_ID" ]; then
        log_error "Failed to get submission ID"
        exit 1
    fi

    log_info "Submission ID: ${SUBMISSION_ID}"

    # Staple the notarization ticket
    log_step "Stapling notarization ticket to DMG..."
    if xcrun stapler staple "${FINAL_DMG}"; then
        log_success "Notarization ticket stapled successfully"
    else
        log_error "Failed to staple notarization ticket"
        exit 1
    fi

    # Verify notarization
    log_step "Verifying notarization..."
    if spctl -a -t open --context context:primary-signature -v "${FINAL_DMG}"; then
        log_success "DMG is properly notarized and ready for distribution"
    else
        log_error "Notarization verification failed"
        exit 1
    fi
}

# ===== VALIDATION =====
final_validation() {
    local skip_notarization="${1:-false}"

    log_section "Final Validation"

    log_step "App bundle validation..."
    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

    log_step "DMG validation..."
    hdiutil verify "${FINAL_DMG}"

    if [ "${skip_notarization}" = false ]; then
        log_step "Notarization validation..."
        spctl -a -t open --context context:primary-signature -v "${FINAL_DMG}"
    else
        log_warning "Skipping notarization validation (--skip-notarization flag set)"
    fi

    log_success "All validations complete"
}

# ===== MAIN EXECUTION =====
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  ${APP_NAME} - Direct Distribution Build           ║${NC}"
    echo -e "${CYAN}║                        Version ${VERSION}                          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

    # Parse command line arguments
    SKIP_NOTARIZATION=false
    for arg in "$@"; do
        case $arg in
            --skip-notarization)
                SKIP_NOTARIZATION=true
                shift
                ;;
            --team-id=*)
                TEAM_ID="${arg#*=}"
                shift
                ;;
            --developer-id=*)
                DEVELOPER_ID="${arg#*=}"
                shift
                ;;
            --help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --skip-notarization           Skip the notarization step"
                echo "  --team-id=ID                 Set Team ID for signing"
                echo "  --developer-id=\"CERT NAME\"   Set Developer ID certificate name"
                echo "  --help                       Show this help message"
                echo ""
                echo "Example:"
                echo "  $0 --developer-id=\"Developer ID Application: John Doe (QG85EMCQ75)\""
                exit 0
                ;;
        esac
    done

    # Run build pipeline
    check_prerequisites
    build_project
    # export_app_from_archive  <-- Removed

    verify_code_signing
    create_dmg

    if [ "$SKIP_NOTARIZATION" = false ]; then
        notarize_dmg
    else
        log_warning "Skipping notarization (--skip-notarization flag set)"
    fi

    final_validation "$SKIP_NOTARIZATION"

    # Summary
    log_section "Build Complete! 🎉"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  SUCCESS: ${APP_NAME} v${VERSION} ready for direct distribution${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "📦 Distribution Package: ${FINAL_DMG}"
    echo "📏 Size: $(du -sh "${FINAL_DMG}" | cut -f1)"
    echo "🔐 Team ID: ${TEAM_ID}"
    if [ "$SKIP_NOTARIZATION" = false ]; then
        echo "✅ Notarized and ready for direct distribution"
    fi
    echo ""
    echo "📋 Next Steps:"
    echo "   1. Test the DMG: open \"${FINAL_DMG}\""
    echo "   2. Distribute the notarized DMG"
    echo ""
    echo "🔧 Configuration:"
    echo "   - Developer ID: ${DEVELOPER_ID}"
    echo "   - Notarization Profile: ${NOTARIZATION_PROFILE}"
    echo ""
}

# Run main function
main "$@"

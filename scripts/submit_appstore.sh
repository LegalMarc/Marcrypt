#!/bin/bash
#
# submit_appstore.sh
# Packages and uploads Marcrypt to App Store Connect
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${ROOT_DIR}/.env"

# Load environment
if [ -f "${ENV_FILE}" ]; then
    set -a
    source "${ENV_FILE}"
    set +a
fi

APP_NAME="Marcrypt"
ARCHIVE_ROOT="${ROOT_DIR}/ignore-resources/archive"
# Use the .app from the build directory when present. This script is only for
# App Store submission and rejects direct-distribution Developer ID signatures.
BUILD_DIR="${ROOT_DIR}/ignore-resources/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/ignore-resources/dist"
PKG_PATH="${DIST_DIR}/${APP_NAME}.pkg"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# Check Prerequisites
if ! command -v xcrun &> /dev/null; then
    log_error "xcrun not found (Command Line Tools)"
    exit 1
fi

# Locate the App
if [ ! -d "${APP_BUNDLE}" ]; then
    # Fallback to checking root
    if [ -d "${ROOT_DIR}/${APP_NAME}.app" ]; then
        APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
    else
        log_error "App bundle not found at ${APP_BUNDLE}"
        log_info "Please run the 'Build Full Release' step first."
        exit 1
    fi
fi

log_info "Found App: ${APP_BUNDLE}"

log_info "Validating App Store signature..."
if ! codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"; then
    log_error "App bundle code signature is invalid."
    exit 1
fi

SIGNATURE_DETAILS="$(codesign -dvv "${APP_BUNDLE}" 2>&1 || true)"
if echo "${SIGNATURE_DETAILS}" | grep -q "Signature=adhoc"; then
    log_error "App bundle is ad-hoc signed; refusing App Store packaging."
    exit 1
fi
if echo "${SIGNATURE_DETAILS}" | grep -q "Authority=Developer ID Application"; then
    log_error "App bundle is signed for direct distribution, not the Mac App Store."
    log_info "Build/sign the app with Apple Distribution or 3rd Party Mac Developer Application before upload."
    exit 1
fi
if echo "${SIGNATURE_DETAILS}" | grep -Eq "Authority=(Apple Distribution|3rd Party Mac Developer Application)"; then
    log_success "App Store-compatible app signature found"
else
    log_error "Could not confirm an App Store-compatible app signing authority."
    log_info "Expected Apple Distribution or 3rd Party Mac Developer Application."
    exit 1
fi

# Signing Identity for Installer (Required for App Store PKG)
# Default to common name or use env var
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}"

# Check Identity
log_info "Checking for Installer Certificate..."
if ! security find-identity -v | grep -q "${INSTALLER_IDENTITY}"; then
    log_warning "Partial match for '${INSTALLER_IDENTITY}' check..."
    # Warning only, productbuild will fail if specific cert not found
fi

# Create PKG
log_info "Creating signed installer package..."
mkdir -p "${DIST_DIR}"
rm -f "${PKG_PATH}"

# We use productbuild to create the submission package
# Note: For Mac App Store, components must be usually signed with "Apple Distribution" or "3rd Party Mac Developer Application"
# If the app was signed with "Developer ID Application" (Direct Dist), this might fail validation later.
# But we proceed as requested to implement the upload mechanism.

if productbuild \
    --component "${APP_BUNDLE}" \
    /Applications \
    --sign "${INSTALLER_IDENTITY}" \
    "${PKG_PATH}"; then
    log_success "Package created: ${PKG_PATH}"
else
    log_error "Failed to create installer package."
    log_info "Ensure you have a '${INSTALLER_IDENTITY}' certificate in your Keychain."
    exit 1
fi

# Upload
log_info "Ready to upload to App Store Connect."

# Credentials
# Use App Store Connect API keys. Do not store app-specific passwords in .env.
API_KEY="${ASC_API_KEY_ID:-${APP_STORE_CONNECT_API_KEY_ID:-}}"
API_ISSUER="${ASC_API_ISSUER_ID:-${APP_STORE_CONNECT_API_ISSUER_ID:-}}"

if [[ -z "${API_KEY}" || -z "${API_ISSUER}" ]]; then
    log_error "Missing App Store Connect API key credentials."
    log_info "Set ASC_API_KEY_ID and ASC_API_ISSUER_ID in the environment."
    log_info "Store the private key in the standard App Store Connect private keys location for altool."
    exit 1
fi

log_info "Uploading with App Store Connect API key ${API_KEY}..."
xcrun altool --upload-app --type macos --file "${PKG_PATH}" \
    --apiKey "${API_KEY}" --apiIssuer "${API_ISSUER}"

log_success "Upload Complete!"

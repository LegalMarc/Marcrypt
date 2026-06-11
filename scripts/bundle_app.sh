#!/bin/bash
set -euo pipefail

APP_NAME="Marcrypt"

# Resolve paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}/.."
cd "${ROOT_DIR}" # Ensure we operate from root

# Preserve explicit caller-provided signing values. Local .env defaults are useful
# for developer convenience, but release scripts must be able to force a
# notarizable Developer ID identity.
CALLER_SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
CALLER_DEVELOPER_ID="${DEVELOPER_ID:-}"
CALLER_TEAM_ID="${TEAM_ID:-}"
CALLER_APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

# Load environment variables
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi
if [ -n "${CALLER_SIGNING_IDENTITY}" ]; then
    SIGNING_IDENTITY="${CALLER_SIGNING_IDENTITY}"
fi
if [ -n "${CALLER_DEVELOPER_ID}" ]; then
    DEVELOPER_ID="${CALLER_DEVELOPER_ID}"
fi
if [ -n "${CALLER_TEAM_ID}" ]; then
    TEAM_ID="${CALLER_TEAM_ID}"
fi
if [ -n "${CALLER_APPLE_TEAM_ID}" ]; then
    APPLE_TEAM_ID="${CALLER_APPLE_TEAM_ID}"
fi
# Default to release
CONFIGURATION="release"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --debug) CONFIGURATION="debug" ;;
        --release) CONFIGURATION="release" ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Capture the bin path
BUILD_DIR=$(swift build -c "$CONFIGURATION" --product Marcrypt --arch arm64 --arch x86_64 --show-bin-path | tail -n 1)
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🚀 Building ${APP_NAME} (${CONFIGURATION})..."
swift build -c "$CONFIGURATION" --product Marcrypt --arch arm64 --arch x86_64

echo "📦 Bundling ${APP_NAME}.app..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/"

# Copy/Generate Info.plist
# We will use the existing one but update the version if needed via PlistBuddy
# Assuming Info.plist exists in Marcrypt/Marcrypt/Info.plist
if [ -f "Marcrypt/Marcrypt/Info.plist" ]; then
    cp "Marcrypt/Marcrypt/Info.plist" "${CONTENTS_DIR}/Info.plist"
else
    echo "⚠️ Info.plist not found! Generating basic plist..."
    cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Marcrypt</string>
    <key>CFBundleIdentifier</key>
    <string>com.marclaw.Marcrypt</string>
    <key>CFBundleName</key>
    <string>Marcrypt</string>
    <key>CFBundleShortVersionString</key>
    <string>0.5.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF
fi

# Copy AppIcon (if exists)
if [ -d "Marcrypt/Marcrypt/Assets.xcassets/AppIcon.appiconset" ]; then
    # We need to compile xcassets if we want the actual icon, 
    # OR we can just check if an icns file exists. 
    # For now, let's see if we can find an icns or just warn.
    # actool is needed for xcassets.
    echo "🎨 Compiling Assets..."
    if ! xcrun actool Marcrypt/Marcrypt/Assets.xcassets --compile "${RESOURCES_DIR}" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "${BUILD_DIR}/assetcatalog.plist"; then
        echo "❌ Asset compilation failed!"
        exit 1
    fi
fi

# Force copy pre-made AppIcon.icns if available (to ensure high-res icon)
if [ -f "assets/MacOS_AppIcon_Set/AppIcon.icns" ]; then
    echo "🎨 Copying high-res AppIcon.icns..."
    cp "assets/MacOS_AppIcon_Set/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Copy Entitlements (for signing)
ENTITLEMENTS="Marcrypt/Marcrypt/Marcrypt.entitlements"

echo "🔐 Signing..."
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${DEVELOPER_ID:-}}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-${TEAM_ID:-}}"

if [ -n "${SIGNING_IDENTITY}" ]; then
    codesign --force --options runtime --timestamp --deep --sign "${SIGNING_IDENTITY}" --entitlements "$ENTITLEMENTS" "${APP_BUNDLE}"
    echo "✅ Signed with Identity: ${SIGNING_IDENTITY}"
elif [ -n "${APPLE_TEAM_ID}" ]; then
    codesign --force --options runtime --timestamp --deep --sign "${APPLE_TEAM_ID}" --entitlements "$ENTITLEMENTS" "${APP_BUNDLE}"
    echo "✅ Signed with Team ID: ${APPLE_TEAM_ID}"
else
    if [ "${REQUIRE_SIGNING_IDENTITY:-0}" = "1" ]; then
        echo "❌ No signing identity configured. Set SIGNING_IDENTITY or DEVELOPER_ID."
        exit 1
    fi
    echo "⚠️ No signing identity found. Signing debug bundle with ad-hoc identity..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "✨ Done! App is at ./${APP_BUNDLE}"

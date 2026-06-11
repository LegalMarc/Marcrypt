#!/bin/bash

# increment_version.sh
# Increments the MARKETING_VERSION (patch level) in the Xcode project
# Also increments CURRENT_PROJECT_VERSION (build number)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${SCRIPT_DIR}/../Marcrypt/Marcrypt.xcodeproj"
PROJECT_DIR_PARENT="${SCRIPT_DIR}/../Marcrypt"
INFO_PLIST="${SCRIPT_DIR}/../Marcrypt/Marcrypt/Info.plist"

increment_version_string() {
    local v=$1
    if [[ $v =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        # Standard SemVer x.y.z
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
    elif [[ $v =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        # Short version x.y -> x.y.1
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.1"
    else
        # Fallback: Just append .1 or try to increment last number
        echo "$v.1"
    fi
}

# 1. Increment Build Number (agvtool bump does this well)
if command -v agvtool &> /dev/null; then
    cd "${PROJECT_DIR_PARENT}"
    echo "Incrementing Build Number..."
    agvtool bump -all
else
    echo "Warning: agvtool not found. Changing directory manually."
fi

# 2. Get Current Marketing Version
if command -v agvtool &> /dev/null; then
    cd "${PROJECT_DIR_PARENT}"
    CURRENT_MARKETING=$(agvtool what-marketing-version -terse1)
else
    # Fallback to parsing pbxproj
    CURRENT_MARKETING=$(grep "MARKETING_VERSION =" "${PROJECT_DIR}/project.pbxproj" | head -1 | awk -F'= ' '{print $2}' | tr -d '";')
fi

# 3. Calculate New Marketing Version
NEW_MARKETING=$(increment_version_string "$CURRENT_MARKETING")

echo "Incrementing Marketing Version: $CURRENT_MARKETING -> $NEW_MARKETING"

# 4. Set New Marketing Version
if command -v agvtool &> /dev/null; then
    cd "${PROJECT_DIR_PARENT}"
    agvtool new-marketing-version "$NEW_MARKETING"
else
    # Fallback: sed
    sed -i '' "s/MARKETING_VERSION = ${CURRENT_MARKETING};/MARKETING_VERSION = ${NEW_MARKETING};/g" "${PROJECT_DIR}/project.pbxproj"
fi

CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_MARKETING}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_BUILD}" "${INFO_PLIST}"

echo "Version updated successfully to ${NEW_MARKETING} (${NEW_BUILD})"

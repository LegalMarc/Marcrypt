# Marcrypt Direct Distribution Build Setup

## Overview

This document provides setup instructions for building Marcrypt for direct distribution using the automated build script. App Store submission is a separate path handled by `scripts/submit_appstore.sh`.

## Current Project Configuration

- **App Name**: Marcrypt
- **Bundle ID**: `com.marclaw.Marcrypt`
- **Team ID**: `<YOUR_TEAM_ID>`
- **Current Version**: 1.0
- **Project Type**: Xcode project (SwiftUI macOS app)
- **Minimum macOS**: 14.0

## Required Setup Steps

### 1. Developer Certificates

You'll need to update the `DEVELOPER_ID` used by `scripts/build_direct_release.sh` with your actual Developer ID Application certificate name. To find your certificate:

```bash
# List available signing identities
security find-identity -v -p codesigning
```

Look for a certificate like:
```
"Developer ID Application: Your Name (<YOUR_TEAM_ID>)"
```

Then update the script:
```bash
DEVELOPER_ID="Developer ID Application: Your Name (<YOUR_TEAM_ID>)"
```

### 2. Notarization Setup (Optional but Recommended)

To set up notarization for automatic submission:

```bash
# Create a notarization profile
xcrun notarytool store-credentials "marcrypt-notarization" \
    --apple-id "your-apple-id@example.com" \
    --team-id "<YOUR_TEAM_ID>" \
    --password "your-app-specific-password"
```

Then update the script:
```bash
NOTARIZATION_PROFILE="marcrypt-notarization"
```

### 3. App-Specific Password

If using notarization, you'll need an app-specific password:
1. Go to https://appleid.apple.com
2. Sign in with your Apple ID
3. Generate an app-specific password for notarization
4. Use this password in the notarization setup above

## Usage

### Basic Build (without notarization)
```bash
scripts/build_direct_release.sh --skip-notarization
```

### Full Build with Notarization
```bash
scripts/build_direct_release.sh
```

### Custom Certificate
```bash
scripts/build_direct_release.sh \
    --developer-id="Developer ID Application: Your Name (<YOUR_TEAM_ID>)"
```

### Help
```bash
scripts/build_direct_release.sh --help
```

## Output

The build process will create:
- **Signed app bundle**: `ignore-resources/build/Marcrypt.app`
- **Signed DMG**: `ignore-resources/dist/Marcrypt-v1.0-Direct.dmg`
- **Build artifacts**: `ignore-resources/build/` and `ignore-resources/archive/` directories

## Troubleshooting

### Common Issues

1. **"Signing identity not found"**
   - Ensure your Developer ID certificate is installed in Keychain
   - Update the `DEVELOPER_ID` variable in the script

2. **"Xcode project not found"**
   - Make sure you're running the script from the project root directory
   - Verify the project path in the script

3. **"Release app is ad-hoc signed"**
   - Set `DEVELOPER_ID` or `SIGNING_IDENTITY` to a valid Developer ID Application certificate
   - Re-run the direct release build

4. **"Notarization failed"**
   - Verify your notarization profile is set up correctly
   - Check that all binaries are properly signed
   - Use `--skip-notarization` for testing

### Testing the DMG

After building:
```bash
# Mount and test the DMG
open "ignore-resources/dist/Marcrypt-v1.0-Direct.dmg"

# Verify code signature
codesign --verify --deep --strict ignore-resources/build/Marcrypt.app

# Test the app
open ignore-resources/build/Marcrypt.app
```

## Next Steps For Distribution

1. **Test thoroughly**: Install and test the app from the DMG
2. **Distribute the notarized DMG**: Publish only the direct-distribution DMG
3. **For App Store submission**: Build/sign an App Store-compatible app bundle and use `scripts/submit_appstore.sh`

## Files Modified/Created

- `scripts/build_direct_release.sh` - Preferred direct-distribution build entrypoint
- `scripts/build_appstore_release.sh` - Legacy compatibility entrypoint for the same direct-distribution build
- `scripts/submit_appstore.sh` - App Store upload packaging path
- `Marcrypt/Marcrypt/Marcrypt.entitlements` - App entitlements
- `docs/BUILD_SETUP.md` - This documentation

## Project Structure

```
Marcrypt/
├── scripts/
│   ├── build_direct_release.sh       # Direct-distribution build entrypoint
│   ├── build_appstore_release.sh     # Legacy direct-distribution alias
│   └── submit_appstore.sh            # App Store upload path
├── docs/
│   ├── BUILD_SETUP.md                # Setup documentation
│   └── APP_STORE_BUILD_GUIDE.md      # Release-path notes
├── Marcrypt/                          # Xcode project directory
│   ├── Marcrypt.xcodeproj/           # Xcode project
│   ├── Marcrypt/                     # Source code
│   │   ├── Marcrypt.swift           # Main app file
│   │   ├── ContentView.swift        # Main view
│   │   ├── AboutView.swift          # About view
│   │   └── Marcrypt.entitlements    # App entitlements
│   └── Assets.xcassets/             # App icons and assets
└── ignore-resources/                # Build output (created during build)
```

The build script is ready to use once you update it with your signing certificate information!

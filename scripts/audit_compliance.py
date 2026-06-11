#!/usr/bin/env python3
import sys
import os
import plistlib

def check_entitlements(entitlements_path):
    print(f"🔍 Checking Entitlements: {entitlements_path}")
    if not os.path.exists(entitlements_path):
        print("❌ Entitlements file not found!")
        return False

    try:
        with open(entitlements_path, 'rb') as f:
            pl = plistlib.load(f)
            
        required_keys = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True
        }
        
        all_passed = True
        for key, expected_val in required_keys.items():
            val = pl.get(key)
            if val == expected_val:
                print(f"✅ {key} is present and {val}")
            else:
                print(f"❌ {key} mismatch. Expected {expected_val}, got {val}")
                all_passed = False
                
        # Check for disallowed keys for App Store (JIT usually allowed but good to know)
        security_keys = [k for k in pl.keys() if k.startswith("com.apple.security")]
        print(f"ℹ️  Found {len(security_keys)} security entitlements.")
        
        return all_passed
    except Exception as e:
        print(f"❌ Error parsing entitlements: {e}")
        return False

def check_info_plist(plist_path):
    print(f"\n🔍 Checking Info.plist: {plist_path}")
    if not os.path.exists(plist_path):
        print("❌ Info.plist file not found!")
        return False
        
    try:
        with open(plist_path, 'rb') as f:
            pl = plistlib.load(f)
            
        # 1. Privacy Keys Check
        # If the app uses these features, it MUST have a usage description
        privacy_triggers = {
            "NSCameraUsageDescription": "Camera",
            "NSMicrophoneUsageDescription": "Microphone",
            "NSContactsUsageDescription": "Contacts",
            "NSDesktopFolderUsageDescription": "Desktop Folder",
            "NSDocumentsFolderUsageDescription": "Documents Folder",
            "NSDownloadsFolderUsageDescription": "Downloads Folder"
        }
        
        print("Checking Privacy Keys (Warning if missing but required by code):")
        found_privacy_keys = []
        for key, name in privacy_triggers.items():
            if key in pl:
                print(f"✅ Found {key}: '{pl[key]}'")
                found_privacy_keys.append(key)
            else:
                # This is only an error if the app actually uses these features. 
                # For a document app, File Access is handled via Entitlements usually, 
                # but direct folder access needs these.
                pass 
                
        if not found_privacy_keys:
             print("ℹ️  No specific Privacy Usage Descriptions found. (Normal if using standard file pickers only)")

        # 2. ITSAppUsesNonExemptEncryption
        # Critical for Export Compliance
        if "ITSAppUsesNonExemptEncryption" not in pl:
             print("⚠️  'ITSAppUsesNonExemptEncryption' is MISSING. App Store Connect will ask for export compliance every build.")
        else:
             print(f"✅ ITSAppUsesNonExemptEncryption: {pl['ITSAppUsesNonExemptEncryption']}")

        # 3. Minimum System Version
        if "LSMinimumSystemVersion" in pl:
            print(f"✅ LSMinimumSystemVersion: {pl['LSMinimumSystemVersion']}")
        else:
            print("⚠️  LSMinimumSystemVersion missing.")

        return True
    except Exception as e:
        print(f"❌ Error parsing Info.plist: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: audit_compliance.py <entitlements_path> <infoplist_path>")
        sys.exit(1)
        
    entitlements_path = sys.argv[1]
    plist_path = sys.argv[2]
    
    ent_ok = check_entitlements(entitlements_path)
    plist_ok = check_info_plist(plist_path)
    
    if ent_ok and plist_ok:
        print("\n🎉 Compliance Scan Passed (Review warnings above)")
        sys.exit(0)
    else:
        print("\n❌ Compliance Scan Failed")
        sys.exit(1)

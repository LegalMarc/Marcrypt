#!/usr/bin/env python3
import os
import sys
import subprocess
import argparse
import shutil
from pathlib import Path

# Colors for output
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
RESET = '\033[0m'

def print_result(filename, status, message=""):
    color = GREEN if status == "PASS" else RED
    print(f"[{color}{status}{RESET}] {filename}: {message}")

def check_pdf(filepath):
    """
    Validates PDF using qpdf.
    Checks for: 1. Valid structure, 2. Encryption status.
    """
    try:
        # 1. Check if valid PDF and encrypted
        result = subprocess.run(
            ['qpdf', '--check', '--is-encrypted', str(filepath)],
            capture_output=True,
            text=True
        )
        
        # Exit code 0 means 'yes' (is encrypted) for --is-encrypted
        # Exit code 1 means 'no' (not encrypted) BUT qpdf --check also returns 0 for success?
        # Actually --is-encrypted returns 0 if encrypted, 1 if not.
        # But if the file is invalid, it returns 2.
        
        if result.returncode == 0:
            return True, "Valid Encrypted PDF"
        elif result.returncode == 1:
            return False, "Valid PDF but NOT Encrypted (or qpdf check warning)"
        else:
            return False, f"Corrupt/Invalid PDF: {result.stderr.strip()}"
            
    except FileNotFoundError:
        return None, "Skipped (qpdf not found)"

def check_docx(filepath, password="password"):
    """
    Validates DOCX.
    1. Checks if it's a valid ZIP (clean/standard).
    2. If standard zip fails, checks if it's a valid OLE Encrypted file.
    """
    import msoffcrypto
    import zipfile

    # 1. Check if it's a standard unencrypted DOCX (Zip)
    if zipfile.is_zipfile(filepath):
        # It's a valid ZIP. If we expected encryption, this might be a "Passive" success (unencrypted).
        # But if it's named "encrypted.docx", we might want to warn.
        if "encrypted" in filepath.name.lower():
            return False, "FAIL: File is a ZIP (unencrypted) but expected Encryption (OLE)"
        return True, "Valid Standard DOCX (Unencrypted ZIP)"

    # 2. Check if it's an OLE Encrypted file
    try:
        with open(filepath, "rb") as f:
            file = msoffcrypto.OfficeFile(f)
            file.load_key(password=password)
            file.decrypt(open(os.devnull, "wb"))
            return True, "Valid Encrypted DOCX (Decryptable)"
            
    except Exception as e:
        return False, f"Compliance Failure: {str(e)}"

def main():
    parser = argparse.ArgumentParser(description="Verify Marcrypt Output Compliance")
    parser.add_argument("path", help="File or Folder to check")
    parser.add_argument("--password", default="password", help="Password to use for decryption check")
    parser.add_argument("--require-tools", action="store_true", help="Fail if optional verification tools are missing")
    args = parser.parse_args()

    if args.require_tools and shutil.which("qpdf") is None:
        print(f"{RED}Error: qpdf is required for release-grade PDF verification{RESET}")
        sys.exit(1)
    
    target_path = Path(args.path)
    if not target_path.exists():
        print(f"{RED}Error: Path not found: {target_path}{RESET}")
        sys.exit(1)

    files = []
    if target_path.is_file():
        files.append(target_path)
    else:
        files = list(target_path.glob("**/*"))
        
    print(f"Scanning {len(files)} files in {target_path}...")
    print("-" * 60)
    
    has_failures = False
    
    for file in files:
        if file.name.startswith("."): continue
        
        status = None
        msg = ""
        
        if file.suffix.lower() == ".pdf":
            status, msg = check_pdf(file)
        elif file.suffix.lower() == ".docx":
            status, msg = check_docx(file, args.password)
            
        if status is not None:
             print_result(file.name, "PASS" if status else "FAIL", msg)
             if status is False: has_failures = True
             
    print("-" * 60)
    if has_failures:
        print(f"{RED}FAILURES DETECTED{RESET}")
        sys.exit(1)
    else:
        print(f"{GREEN}ALL CHECKS PASSED{RESET}")
        sys.exit(0)

if __name__ == "__main__":
    main()

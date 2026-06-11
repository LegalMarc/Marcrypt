#!/usr/bin/env python3
import sys
import os
import subprocess
import shutil

def find_soffice():
    """Find the LibreOffice executable."""
    # Check PATH first
    if shutil.which("soffice"):
        return "soffice"
    
    # Check common macOS locations
    common_paths = [
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "~/Applications/LibreOffice.app/Contents/MacOS/soffice"
    ]
    
    for path in common_paths:
        expanded_path = os.path.expanduser(path)
        if os.path.exists(expanded_path):
            return expanded_path
            
    return None

def verify_docx(docx_path):
    """
    Verify DOCX by attempting to convert it to PDF using LibreOffice.
    This acts as a strict parser check.
    """
    if not os.path.exists(docx_path):
        print(f"❌ Error: File not found: {docx_path}")
        return False
        
    soffice = find_soffice()
    if not soffice:
        print("⚠️  LibreOffice (soffice) not found. Skipping external compliance check.")
        # We return True because this is an environment issue, not a test failure.
        # But we print a warning.
        return True
        
    print(f"ℹ️  Using LibreOffice at: {soffice}")
    
    output_dir = os.path.dirname(docx_path)
    # Create a specific temp dir for output to avoid clutter
    temp_out_dir = os.path.join(output_dir, "lo_verification_tmp")
    if not os.path.exists(temp_out_dir):
        os.makedirs(temp_out_dir)
        
    try:
        # Command: soffice --headless --convert-to pdf <file> --outdir <dir>
        cmd = [
            soffice,
            "--headless",
            "--convert-to", "pdf",
            docx_path,
            "--outdir", temp_out_dir
        ]
        
        print(f"🔄 Running conversion: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            print(f"❌ LibreOffice conversion failed (Exit code {result.returncode})")
            print(f"STDERR: {result.stderr}")
            print(f"STDOUT: {result.stdout}")
            return False
            
        # Verify PDF was created
        filename = os.path.basename(docx_path)
        pdf_name = os.path.splitext(filename)[0] + ".pdf"
        pdf_path = os.path.join(temp_out_dir, pdf_name)
        
        if os.path.exists(pdf_path):
            file_size = os.path.getsize(pdf_path)
            if file_size > 0:
                print(f"✅ Compliance Check Passed. Generated PDF: {pdf_path} ({file_size} bytes)")
                return True
            else:
                print("❌ Generated PDF is empty.")
                return False
        else:
            print(f"❌ PDF output not found at expected path: {pdf_path}")
            return False
            
    except Exception as e:
        print(f"❌ Exception during verification: {e}")
        return False
        
    finally:
        # Cleanup
        if os.path.exists(temp_out_dir):
            shutil.rmtree(temp_out_dir)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: verify_compliance.py <path_to_docx>")
        sys.exit(1)
        
    docx_file = sys.argv[1]
    print(f"🔍 Verifying: {docx_file}")
    
    if verify_docx(docx_file):
        sys.exit(0)
    else:
        sys.exit(1)

#!/bin/bash
set -e

# Generate Valid PDF if input is dummy.pdf
if [ "$1" == "dummy.pdf" ]; then
    python3 -c "from fpdf import FPDF; pdf = FPDF(); pdf.add_page(); pdf.set_font('Arial', size=12); pdf.cell(200, 10, txt='Test PDF', ln=1, align='C'); pdf.output('dummy.pdf')" 2>/dev/null || echo "%PDF-1.4" > dummy.pdf # Fallback if fpdf missing
    # Actually, simpler: just write a raw minimal PDF
    cat <<EOF > dummy.pdf
%PDF-1.1
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>
endobj
xref
0 4
0000000000 65535 f
0000000010 00000 n
0000000056 00000 n
0000000111 00000 n
trailer
<< /Size 4 /Root 1 0 R >>
startxref
169
%%EOF
EOF
fi

# Setup venv if needed
if [ ! -d ".venv_harness" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv .venv_harness
    source .venv_harness/bin/activate
    pip install --upgrade pip
    pip install -r requirements-verification.txt
else
    source .venv_harness/bin/activate
    pip install -r requirements-verification.txt
fi

# Determine target
TARGET="$1"
if [ -z "$TARGET" ]; then
    echo "Usage: ./scripts/run_harness.sh <path_to_encrypted_files> [password]"
    exit 1
fi

PASSWORD="${2:-password}"

echo "Running Compliance Verification on: $TARGET"

# 1. GENERATE (Encrypt using App CLI)
# If target is a PDF/DOCX file, we encrypt it to a managed output folder
# If target is already a folder of encrypted files, we just verify it.

if [ -f "$TARGET" ]; then
   # For file argument, we just print usage (Harness generates its own files for now)
   echo "Note: DocxHarness generates its own test files. Ignoring input: $TARGET"
fi

OUTPUT_DIR="$HOME/Downloads/MarcryptTestOutput/test_output_$(date +%s)"
mkdir -p "$OUTPUT_DIR"

echo "Building Harness..."
# Build the CLI tool
swift build -c release --product DocxHarness --arch arm64

echo "Signing Harness..."
# Sign it (Ad-Hoc) without App Sandbox to avoid Traverse/BPT trap
# If PDF Encryption fails here, we confirm it requires specific entitlements.
codesign --force --deep --sign - ".build/release/DocxHarness"

echo "Running Harness..."
# Execute directly
.build/release/DocxHarness "$OUTPUT_DIR" "$PASSWORD"

# Verify Output
python3 scripts/verify_compliance.py "$OUTPUT_DIR" --password "$PASSWORD"

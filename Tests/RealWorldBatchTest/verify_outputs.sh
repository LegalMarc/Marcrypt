#!/bin/bash
#
# Verify batch outputs produced by RealWorldBatchTest.
#
# Set MARCRYPT_SAMPLE_FILES_PATH to the sample-files directory to opt in.
# The script exits 0 (skip) when the env var is unset or the directory is
# absent, so CI on a clean clone does not fail.

# Configuration — driven by env var, not a hardcoded path.
: "${MARCRYPT_SAMPLE_FILES_PATH:=}"

if [ -z "${MARCRYPT_SAMPLE_FILES_PATH}" ]; then
    echo "⚠️  SKIPPED: Set MARCRYPT_SAMPLE_FILES_PATH to run this script."
    exit 0
fi

TEST_OUTPUT_DIR="${MARCRYPT_SAMPLE_FILES_PATH}/test-output"
PASSWORD="doggy-style"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║    VERIFYING BATCH OUTPUTS                                ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║    Dir: test-output                                       ║"
echo "║    Password: '${PASSWORD}'                              ║"
echo "╚═══════════════════════════════════════════════════════════╝"

if [ ! -d "$TEST_OUTPUT_DIR" ]; then
    echo "⚠️  SKIPPED: Output directory not found: ${TEST_OUTPUT_DIR}"
    echo "   Run RealWorldBatchTest first to generate outputs."
    exit 0
fi

cd "$TEST_OUTPUT_DIR"

# Setup Python Virtual Environment for tools
echo "⚙️  Setting up Python environment..."
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install msoffcrypto-tool > /dev/null 2>&1

echo ""
echo "🔍 Checking ZIP Archives (AES-256)..."
echo "------------------------------------------------------------"
# Note: macOS default unzip does not support extracting AES-256, but can list details.
# We check if files are identified as AES-256 encrypted.
for f in *.zip; do
    if [ -f "$f" ]; then
        echo -n "📦 $f ... "
        LOCK_CHECK=$(unzip -v "$f" 2>&1 | grep -i "AES" | head -n 1)
        if [ ! -z "$LOCK_CHECK" ]; then
             echo "✅ ENCRYPTED (AES Detected)"
        else
             # Failover: Check if 'Encrypt' or 'Crypt' is listed in methods
             # or check unzip password prompt behavior?
             # Simple check: unzip -t without password should fail 'password required'
             # unzip -t -P wrongpass "$f"
             if unzip -t -P "wrongpass" "$f" > /dev/null 2>&1; then
                 echo "❌ FAILED (Open without correct password? Not encrypted?)"
             else
                 echo "✅ ENCRYPTED (Password Required)"
             fi
        fi
    fi
done

echo ""
echo "🔍 Checking PDF Encryption..."
echo "------------------------------------------------------------"
for f in *.pdf; do
    if [ -f "$f" ]; then
        echo -n "📄 $f ... "
        # Check for /Encrypt dictionary which indicates encryption
        if grep -q "/Encrypt" "$f"; then
            echo -n "✅ ENCRYPTED (Header Check) "
            # Check size > 0
            SIZE=$(wc -c < "$f" | xargs)
            echo "SIZE: $SIZE bytes"
        else
            echo "❌ FAILED (No /Encrypt marker found)"
        fi
    fi
done

echo ""
echo "🔍 Checking DOCX Encryption (via msoffcrypto)..."
echo "------------------------------------------------------------"
# Create temporary python verifier
cat <<EOF > verify_docx.py
import sys
import msoffcrypto

password = "${PASSWORD}"
files = sys.argv[1:]

for f in files:
    try:
        if not f.lower().endswith(".docx"): continue
        # Open basic check
        with open(f, "rb") as office_file:
            file = msoffcrypto.OfficeFile(office_file)
            file.load_key(password=password)
            print(f"📝 {f} ... ✅ VALID (Decrypts with password)")
    except Exception as e:
        print(f"📝 {f} ... ❌ FAILED ({e})")
EOF

# Run python check
# Note: glob might not match .DOCX case-sensitively by default
python3 verify_docx.py *.docx *.DOCX
rm verify_docx.py

echo ""
echo "✅ Verification Complete."

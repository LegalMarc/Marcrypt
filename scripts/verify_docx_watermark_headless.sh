#!/bin/bash
set -e

# verify_docx_watermark_headless.sh

# Directory setup
OUTPUT_DIR="/tmp/marcrypt_visual_verify"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "🧪 Starting Headerless Visualization Pipeline..."
echo "📂 Output Directory: $OUTPUT_DIR"

# 1. Run DocxHarness with Watermark Enabled
echo ""
echo "🔹 Step 1: Generating Watermarked DOCX..."
export ENABLE_WATERMARK=1
cd "$(dirname "$0")/.."
swift run DocxHarness "$OUTPUT_DIR" "password" "/tmp/harness_source.docx"

# 2. Convert Decrypted DOCX to PDF (using LibreOffice)
DECRYPTED_DOCX="$OUTPUT_DIR/decrypted.docx"
if [ -f "$DECRYPTED_DOCX" ]; then
    echo ""
    echo "🔹 Step 2: Converting to PDF for Verification..."
    # soffice --headless --convert-to pdf --outdir $OUTPUT_DIR $DECRYPTED_DOCX
    /Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf --outdir "$OUTPUT_DIR" "$DECRYPTED_DOCX"
    
    PDF_FILE="$OUTPUT_DIR/decrypted.pdf"
    if [ -f "$PDF_FILE" ]; then
        echo "✅ PDF Created: $PDF_FILE"
        
        # 3. Split PDF into pages for verification
        echo ""
        echo "🔹 Step 3: Splitting PDF into pages..."
        export SPLIT_ONLY=1
        cd "$(dirname "$0")/.."
        swift run DocxHarness "$OUTPUT_DIR" "password" "/tmp/harness_source.docx"
        unset SPLIT_ONLY
        
        # 4. Generate Thumbnails for All Pages
        echo ""
        echo "🔹 Step 4: Generating Visual Thumbnails for All Pages..."
        for pdf in "$OUTPUT_DIR"/page_*.pdf; do
            [ -e "$pdf" ] || continue
            echo "   Thumbnailing $(basename "$pdf")..."
            qlmanage -t -s 1000 -o "$OUTPUT_DIR" "$pdf" >/dev/null 2>&1
        done
        
        echo "✅ Thumbnails Created in $OUTPUT_DIR"
        open "$OUTPUT_DIR"
        
        # Also open PDF
        open "$PDF_FILE"
    else
        echo "❌ PDF Conversion Failed."
    fi
else
    echo "❌ Decrypted DOCX not found."
    exit 1
fi

echo ""
echo "🎉 Verification Pipeline Complete."
echo "Inspect artifacts at: $OUTPUT_DIR"

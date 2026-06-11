import msoffcrypto
import sys
import io

password = "doggy-style"
# Filter for docx args only
files = [f for f in sys.argv[1:] if f.lower().endswith(".docx")]

print(f"🕵️‍♀️ Deep Verifying {len(files)} DOCX files...")

for f in files:
    try:
        with open(f, "rb") as office_file:
            file = msoffcrypto.OfficeFile(office_file)
            file.load_key(password=password)
            
            # Decrypt to memory
            decrypted = io.BytesIO()
            file.decrypt(decrypted)
            
            # Check Magic Bytes (PK\x03\x04)
            decrypted.seek(0)
            magic = decrypted.read(4)
            
            if magic == b'PK\x03\x04':
                print(f"📝 {f} ... ✅ VALID ZIP PAYLOAD (Matches PK Header)")
            else:
                formatted_magic = " ".join(["{:02x}".format(x) for x in magic])
                print(f"📝 {f} ... ❌ INVALID PAYLOAD (Magic: {formatted_magic})")
                
    except Exception as e:
        print(f"📝 {f} ... ❌ FAILED ({e})")

import zipfile
import xml.etree.ElementTree as ET
import sys

def analyze(docx_path):
    with zipfile.ZipFile(docx_path, 'r') as z:
        xml_content = z.read('word/document.xml')
    
    # Namespaces
    ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
    
    root = ET.fromstring(xml_content)
    body = root.find('w:body', ns)
    
    print(f"Analyzing {docx_path}...")
    
    # Function to find all sectPr (including nested in pPr)
    def find_sectPrs(element):
        sectPrs = []
        for child in element.findall('.//w:sectPr', ns):
            sectPrs.append(child)
        # Also check direct children if not covered by .//
        return sectPrs

    all_sectPrs = find_sectPrs(body)
    print(f"Found {len(all_sectPrs)} w:sectPr elements.")
    
    for i, sectPr in enumerate(all_sectPrs):
        print(f"\n--- Section Property #{i+1} ---")
        titlePg = sectPr.find('w:titlePg', ns)
        if titlePg is not None:
            print("  [x] Has <w:titlePg/> (Different First Page)")
        else:
            print("  [ ] No <w:titlePg/>")
            
        headerRefs = sectPr.findall('w:headerReference', ns)
        if not headerRefs:
            print("  [ ] No Header References")
        for ref in headerRefs:
            r_type = ref.get(f"{{{ns['w']}}}type")
            r_id = ref.get(f"{{http://schemas.openxmlformats.org/officeDocument/2006/relationships}}id") # r:id
            print(f"  - HeaderReference: type='{r_type}', id='{r_id}'")

if __name__ == "__main__":
    analyze(sys.argv[1])

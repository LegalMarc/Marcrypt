import AppKit

func checkRed(path: String) {
    guard let image = NSImage(contentsOfFile: path) else {
        print("❌ Could not load image at \(path)")
        exit(1)
    }
    
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
        print("❌ Could not get bitmap representation")
        exit(1)
    }
    
    var redPixelCount = 0
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    
    // Scan a subset of pixels for performance (every 2nd pixel)
    for x in stride(from: 0, to: width, by: 2) {
        for y in stride(from: 0, to: height, by: 2) {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            
            // NSColor components are 0.0-1.0
            // Red watermark is high red, lower green/blue
            // Standard red: 1.0, 0.0, 0.0
            // With 0.5 opacity on white: 0.5*1 + 0.5*1 = 1.0 Red?
            // Wait. 
            // VML Fill Color #FF0000 (Red). 
            // Opacity 0.5.
            // On White Background (#FFFFFF).
            // Result = 0.5 * Red + 0.5 * White
            // R = 0.5(255) + 0.5(255) = 255.
            // G = 0.5(0) + 0.5(255) = 127.
            // B = 0.5(0) + 0.5(255) = 127.
            // So pixel should be roughly (1.0, 0.5, 0.5).
            // A non-watermark pixel (Black text on white) is (0,0,0) or (1,1,1).
            // A non-watermark pixel (Blue link) is (0,0,1).
            
            // We look for pixels where G and B are significantly LOWER than R.
            // But if it's pink (1, 0.5, 0.5), R is 1.0, G is 0.5. Difference 0.5.
            // White is (1, 1, 1). Difference 0.
            
            if color.redComponent > (color.greenComponent + 0.2) && 
               color.redComponent > (color.blueComponent + 0.2) {
                redPixelCount += 1
            }
        }
    }
    
    print("Found \(redPixelCount) red-dominant pixels in \(path).")
    
    if redPixelCount > 100 { // Threshold (since we skip pixels, 100 is significant)
        print("✅ Watermark DETECTED (Likely)")
        exit(0)
    } else {
        print("❌ Watermark MISSING (No significant red detected)")
        exit(1)
    }
}

let args = CommandLine.arguments
if args.count < 2 {
    print("Usage: swift verify_pixels.swift <image_path>")
    exit(1)
}

checkRed(path: args[1])

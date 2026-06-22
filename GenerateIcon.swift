import Cocoa
import Foundation

func drawIcon(size: NSSize) -> NSImage {
    let image = NSImage(size: size)
    
    image.lockFocus()
    
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    
    let w = size.width
    let h = size.height
    let scale = w / 512.0 // Scale drawing parameters relative to 512x512 reference
    
    // Clear canvas to transparent
    ctx.clear(CGRect(origin: .zero, size: size))
    
    // 1. Draw soft drop shadow for the main squircle
    ctx.saveGState()
    let shadowColor = NSColor.black.withAlphaComponent(0.40).cgColor
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 18 * scale, color: shadowColor)
    
    // 2. Main Squircle bounds (macOS standard icon is 424x424 centered inside 512x512)
    let squircleRect = CGRect(x: 44 * scale, y: 44 * scale, width: 424 * scale, height: 424 * scale)
    let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: 92 * scale, yRadius: 92 * scale)
    
    // Fill squircle with deep metallic blue-to-violet gradient
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.05, green: 0.08, blue: 0.22, alpha: 1.0).cgColor,
        NSColor(red: 0.16, green: 0.05, blue: 0.32, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
    
    squirclePath.addClip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 44 * scale, y: 468 * scale), end: CGPoint(x: 44 * scale, y: 44 * scale), options: [])
    ctx.restoreGState() // Removes shadow and clip
    
    // Re-apply clip for inner drawings
    ctx.saveGState()
    squirclePath.addClip()
    
    // 3. Draw Treemap Grid in the lower/right half
    // Dynamic glass-morphic colorful grid blocks representing file types
    let rawRects: [(CGRect, NSColor)] = [
        // Huge file 1 (Magenta/Crimson - system/dmg)
        (CGRect(x: 230, y: 60, width: 140, height: 200), NSColor(red: 0.90, green: 0.10, blue: 0.45, alpha: 0.85)),
        // Huge file 2 (Cyan/Teal - video/audio)
        (CGRect(x: 375, y: 60, width: 75, height: 110), NSColor(red: 0.05, green: 0.70, blue: 0.90, alpha: 0.85)),
        // File 3 (Swift Orange - developer/code)
        (CGRect(x: 375, y: 175, width: 75, height: 85), NSColor(red: 0.98, green: 0.35, blue: 0.15, alpha: 0.85)),
        // File 4 (Vibrant Green - images)
        (CGRect(x: 230, y: 265, width: 90, height: 100), NSColor(red: 0.15, green: 0.75, blue: 0.15, alpha: 0.85)),
        // File 5 (Yellow - zip archives)
        (CGRect(x: 325, y: 265, width: 125, height: 100), NSColor(red: 0.88, green: 0.73, blue: 0.05, alpha: 0.85)),
        // Top smaller file (Royal Purple - apps)
        (CGRect(x: 230, y: 370, width: 220, height: 50), NSColor(red: 0.58, green: 0.11, blue: 0.91, alpha: 0.85))
    ]
    
    for (rect, color) in rawRects {
        // Scale rect
        let scaledRect = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale, width: rect.size.width * scale, height: rect.size.height * scale)
        
        // Fill
        ctx.setFillColor(color.cgColor)
        let rectPath = CGPath(roundedRect: scaledRect, cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
        ctx.addPath(rectPath)
        ctx.fillPath()
        
        // Stroke/Border
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1.5 * scale)
        let strokePath = CGPath(roundedRect: scaledRect, cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
        ctx.addPath(strokePath)
        ctx.strokePath()
        
        // Inner Gloss highlight
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        let glossRect = CGRect(
            x: scaledRect.origin.x + 1 * scale,
            y: scaledRect.origin.y + scaledRect.size.height / 2,
            width: scaledRect.size.width - 2 * scale,
            height: scaledRect.size.height / 2 - 1 * scale
        )
        let glossPath = CGPath(roundedRect: glossRect, cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil)
        ctx.addPath(glossPath)
        ctx.fillPath()
    }
    
    // 4. Draw glossy silver Disk Platter (Circle) in upper-left
    let platterCenter = CGPoint(x: 170 * scale, y: 310 * scale)
    let platterRadius: CGFloat = 110 * scale
    
    ctx.saveGState()
    // Shadow for platter
    ctx.setShadow(offset: CGSize(width: -4 * scale, height: -4 * scale), blur: 8 * scale, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    
    // Draw platter base circle
    ctx.setFillColor(NSColor(white: 0.85, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: platterCenter.x - platterRadius, y: platterCenter.y - platterRadius, width: platterRadius*2, height: platterRadius*2))
    ctx.restoreGState()
    
    // Draw concentric brushed-metal metallic lines on platter
    ctx.saveGState()
    let platterPath = NSBezierPath(ovalIn: CGRect(x: platterCenter.x - platterRadius, y: platterCenter.y - platterRadius, width: platterRadius*2, height: platterRadius*2))
    platterPath.addClip()
    
    // Draw radial metallic gradient
    let platterColors = [
        NSColor(white: 0.95, alpha: 1.0).cgColor,
        NSColor(white: 0.75, alpha: 1.0).cgColor,
        NSColor(white: 0.90, alpha: 1.0).cgColor,
        NSColor(white: 0.60, alpha: 1.0).cgColor,
        NSColor(white: 0.95, alpha: 1.0).cgColor
    ] as CFArray
    let platterLocations: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
    let platterGradient = CGGradient(colorsSpace: colorSpace, colors: platterColors, locations: platterLocations)!
    ctx.drawRadialGradient(platterGradient, startCenter: platterCenter, startRadius: 0, endCenter: platterCenter, endRadius: platterRadius, options: [])
    
    // Concentric metallic grooves
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
    ctx.setLineWidth(1.0 * scale)
    for r in stride(from: 20 * scale, to: platterRadius, by: 12 * scale) {
        ctx.addEllipse(in: CGRect(x: platterCenter.x - r, y: platterCenter.y - r, width: r*2, height: r*2))
        ctx.strokePath()
    }
    ctx.restoreGState()
    
    // Platter center spindle
    ctx.setFillColor(NSColor(white: 0.35, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: platterCenter.x - 14 * scale, y: platterCenter.y - 14 * scale, width: 28 * scale, height: 28 * scale))
    
    ctx.setFillColor(NSColor(white: 0.90, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: platterCenter.x - 8 * scale, y: platterCenter.y - 8 * scale, width: 16 * scale, height: 16 * scale))
    
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillEllipse(in: CGRect(x: platterCenter.x - 3 * scale, y: platterCenter.y - 3 * scale, width: 6 * scale, height: 6 * scale))
    
    // 5. Draw Hard Drive Reader Arm
    // Pivot base in lower-left
    let armPivot = CGPoint(x: 100 * scale, y: 120 * scale)
    
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 4 * scale, height: -4 * scale), blur: 6 * scale, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    
    // Pivot base circle
    ctx.setFillColor(NSColor(white: 0.30, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: armPivot.x - 18 * scale, y: armPivot.y - 18 * scale, width: 36 * scale, height: 36 * scale))
    ctx.setFillColor(NSColor(white: 0.75, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: armPivot.x - 10 * scale, y: armPivot.y - 10 * scale, width: 20 * scale, height: 20 * scale))
    
    // Reader Arm bar (Pivot to Platter read point)
    let armTarget = CGPoint(x: 185 * scale, y: 250 * scale)
    
    let armPath = CGMutablePath()
    armPath.move(to: armPivot)
    armPath.addLine(to: armTarget)
    
    ctx.setStrokeColor(NSColor(white: 0.80, alpha: 1.0).cgColor)
    ctx.setLineWidth(8.0 * scale)
    ctx.setLineCap(.round)
    ctx.addPath(armPath)
    ctx.strokePath()
    
    // Reader head accent (small rectangle at the target)
    let headRect = CGRect(x: armTarget.x - 6 * scale, y: armTarget.y - 6 * scale, width: 12 * scale, height: 12 * scale)
    ctx.setFillColor(NSColor(white: 0.20, alpha: 1.0).cgColor)
    let headPath = CGPath(roundedRect: headRect, cornerWidth: 2 * scale, cornerHeight: 2 * scale, transform: nil)
    ctx.addPath(headPath)
    ctx.fillPath()
    
    // Orange glowing scanning laser dot indicator
    ctx.setFillColor(NSColor.orange.cgColor)
    ctx.fillEllipse(in: CGRect(x: armTarget.x - 2 * scale, y: armTarget.y - 2 * scale, width: 4 * scale, height: 4 * scale))
    
    ctx.restoreGState()
    
    // 6. Subtle glassmorphic reflection overlay on the entire squircle
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.04).cgColor)
    let reflectionPath = CGMutablePath()
    reflectionPath.move(to: CGPoint(x: 44 * scale, y: 468 * scale))
    reflectionPath.addLine(to: CGPoint(x: 468 * scale, y: 468 * scale))
    reflectionPath.addLine(to: CGPoint(x: 44 * scale, y: 44 * scale))
    reflectionPath.closeSubpath()
    ctx.addPath(reflectionPath)
    ctx.fillPath()
    
    // Inner border highlight
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
    ctx.setLineWidth(2.5 * scale)
    ctx.addPath(squirclePath.cgPath)
    ctx.strokePath()
    
    ctx.restoreGState() // Restore from squircle clip
    
    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to convert image to PNG for \(url.lastPathComponent)")
        return
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        print("Failed to write PNG file to \(url.path): \(error.localizedDescription)")
    }
}

// Main execution block
let fileManager = FileManager.default
let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset")

// Create clean .iconset directory
try? fileManager.removeItem(at: iconsetURL)
try! fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

print("=== Generating Vector-Sharp CoreGraphics Master App Icon (1024x1024) ===")
let masterImage = drawIcon(size: NSSize(width: 1024, height: 1024))

// Standard macOS app icon size configuration mapping
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

print("=== Generating scaled PNG icon set sizes ===")
for (filename, dimension) in sizes {
    let size = NSSize(width: dimension, height: dimension)
    
    // For smaller files, render directly at that size to get mathematically crisp vector lines!
    let scaledImage = drawIcon(size: size)
    let fileURL = iconsetURL.appendingPathComponent(filename)
    savePNG(image: scaledImage, to: fileURL)
}

print("=== AppIcon.iconset generated successfully! ===")

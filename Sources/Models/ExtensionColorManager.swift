import Foundation
import SwiftUI

public final class ExtensionColorManager: @unchecked Sendable {
    public static let shared = ExtensionColorManager()
    
    private let lock = NSLock()
    private var dynamicColors: [String: Color] = [:]
    
    // Modern high-contrast color palette for specific extension categories
    private let predefinedColors: [String: Color] = [
        // Applications & Packages
        "app": Color(.sRGB, red: 0.58, green: 0.11, blue: 0.91, opacity: 1.0), // Royal Purple
        "framework": Color(.sRGB, red: 0.44, green: 0.19, blue: 0.63, opacity: 1.0),
        "plugin": Color(.sRGB, red: 0.31, green: 0.12, blue: 0.48, opacity: 1.0),
        
        // Disk Images & Installers
        "dmg": Color(.sRGB, red: 0.90, green: 0.10, blue: 0.20, opacity: 1.0), // Bright Crimson
        "pkg": Color(.sRGB, red: 0.75, green: 0.08, blue: 0.17, opacity: 1.0),
        "iso": Color(.sRGB, red: 0.60, green: 0.05, blue: 0.12, opacity: 1.0),
        
        // Archives & Compressed Files
        "zip": Color(.sRGB, red: 0.95, green: 0.50, blue: 0.05, opacity: 1.0), // Vibrant Orange
        "tar": Color(.sRGB, red: 0.82, green: 0.42, blue: 0.04, opacity: 1.0),
        "gz": Color(.sRGB, red: 0.70, green: 0.35, blue: 0.03, opacity: 1.0),
        "rar": Color(.sRGB, red: 0.55, green: 0.27, blue: 0.02, opacity: 1.0),
        "7z": Color(.sRGB, red: 0.90, green: 0.60, blue: 0.15, opacity: 1.0),
        
        // Video / Media
        "mp4": Color(.sRGB, red: 0.10, green: 0.60, blue: 0.95, opacity: 1.0), // Deep Sky Blue
        "mkv": Color(.sRGB, red: 0.08, green: 0.50, blue: 0.80, opacity: 1.0),
        "mov": Color(.sRGB, red: 0.05, green: 0.40, blue: 0.65, opacity: 1.0),
        "avi": Color(.sRGB, red: 0.03, green: 0.30, blue: 0.50, opacity: 1.0),
        "webm": Color(.sRGB, red: 0.12, green: 0.68, blue: 0.98, opacity: 1.0),
        
        // Audio
        "mp3": Color(.sRGB, red: 0.05, green: 0.80, blue: 0.70, opacity: 1.0), // Cyan/Teal
        "wav": Color(.sRGB, red: 0.04, green: 0.65, blue: 0.57, opacity: 1.0),
        "flac": Color(.sRGB, red: 0.03, green: 0.50, blue: 0.44, opacity: 1.0),
        "m4a": Color(.sRGB, red: 0.06, green: 0.90, blue: 0.78, opacity: 1.0),
        
        // Images
        "jpg": Color(.sRGB, red: 0.15, green: 0.80, blue: 0.15, opacity: 1.0), // Rich Green
        "jpeg": Color(.sRGB, red: 0.15, green: 0.80, blue: 0.15, opacity: 1.0),
        "png": Color(.sRGB, red: 0.12, green: 0.68, blue: 0.12, opacity: 1.0),
        "gif": Color(.sRGB, red: 0.20, green: 0.90, blue: 0.20, opacity: 1.0),
        "heic": Color(.sRGB, red: 0.10, green: 0.55, blue: 0.10, opacity: 1.0),
        "tiff": Color(.sRGB, red: 0.08, green: 0.45, blue: 0.08, opacity: 1.0),
        "svg": Color(.sRGB, red: 0.25, green: 0.95, blue: 0.25, opacity: 1.0),
        
        // Developer & Code
        "swift": Color(.sRGB, red: 0.98, green: 0.35, blue: 0.15, opacity: 1.0), // Swift Orange-Red
        "c": Color(.sRGB, red: 0.35, green: 0.52, blue: 0.85, opacity: 1.0),
        "cpp": Color(.sRGB, red: 0.00, green: 0.35, blue: 0.70, opacity: 1.0),
        "h": Color(.sRGB, red: 0.50, green: 0.70, blue: 0.90, opacity: 1.0),
        "py": Color(.sRGB, red: 0.20, green: 0.45, blue: 0.65, opacity: 1.0),
        "js": Color(.sRGB, red: 0.85, green: 0.70, blue: 0.05, opacity: 1.0),
        "ts": Color(.sRGB, red: 0.18, green: 0.47, blue: 0.76, opacity: 1.0),
        "html": Color(.sRGB, red: 0.88, green: 0.32, blue: 0.12, opacity: 1.0),
        "css": Color(.sRGB, red: 0.10, green: 0.44, blue: 0.74, opacity: 1.0),
        "rs": Color(.sRGB, red: 0.80, green: 0.25, blue: 0.10, opacity: 1.0),
        
        // Documents & Books
        "pdf": Color(.sRGB, red: 0.88, green: 0.12, blue: 0.12, opacity: 1.0), // PDF Red
        "epub": Color(.sRGB, red: 0.20, green: 0.60, blue: 0.40, opacity: 1.0),
        "docx": Color(.sRGB, red: 0.10, green: 0.35, blue: 0.70, opacity: 1.0),
        "xlsx": Color(.sRGB, red: 0.10, green: 0.50, blue: 0.25, opacity: 1.0),
        "pptx": Color(.sRGB, red: 0.80, green: 0.30, blue: 0.10, opacity: 1.0),
        "txt": Color(.sRGB, red: 0.50, green: 0.50, blue: 0.50, opacity: 1.0), // Neutral Gray
        "json": Color(.sRGB, red: 0.60, green: 0.50, blue: 0.20, opacity: 1.0),
        "yaml": Color(.sRGB, red: 0.60, green: 0.40, blue: 0.10, opacity: 1.0),
        "md": Color(.sRGB, red: 0.40, green: 0.50, blue: 0.70, opacity: 1.0),
        
        // System / Database / Other
        "sqlite": Color(.sRGB, red: 0.22, green: 0.44, blue: 0.66, opacity: 1.0),
        "db": Color(.sRGB, red: 0.30, green: 0.40, blue: 0.50, opacity: 1.0),
        "log": Color(.sRGB, red: 0.65, green: 0.65, blue: 0.60, opacity: 1.0),
        "tmp": Color(.sRGB, red: 0.70, green: 0.70, blue: 0.10, opacity: 1.0),
    ]
    
    private init() {}
    
    /// Get the color for a specific file extension
    public func color(for fileExtension: String) -> Color {
        let ext = fileExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ext.isEmpty {
            return Color.gray // Default for folders or extensionless files
        }
        
        if let color = predefinedColors[ext] {
            return color
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        if let color = dynamicColors[ext] {
            return color
        }
        
        // Generate a stable color based on the hash of the extension
        let generatedColor = generateStableColor(for: ext)
        dynamicColors[ext] = generatedColor
        return generatedColor
    }
    
    private func generateStableColor(for str: String) -> Color {
        var hash: UInt64 = 5381
        for char in str.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        
        // Convert hash to HSL or RGB to ensure beautiful, bright colors (avoid too dark/light)
        // We'll use HSB/HSL logic:
        let hue = Double(hash % 360) / 360.0
        // Keep saturation high (0.6 - 0.85) and brightness high (0.5 - 0.8) for nice visibility in treemap
        let saturation = 0.65 + Double((hash >> 8) % 20) / 100.0 // 0.65 - 0.85
        let brightness = 0.55 + Double((hash >> 16) % 25) / 100.0 // 0.55 - 0.80
        
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

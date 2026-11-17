import SwiftUI
import AppKit

extension Color {
    /// Create a Color from a "#RRGGBB" hex string. Falls back to black on malformed input.
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6, let value = UInt32(hexString, radix: 16) else {
            self = .black
            return
        }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// Convert this color to a "#RRGGBB" hex string using its sRGB components.
    /// Alpha is intentionally dropped — opacity is tracked as a separate setting.
    func toHex() -> String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Perceived (relative) luminance in 0...1 using standard sRGB weights.
    /// Values above 0.5 are generally considered "light" backgrounds.
    var perceivedLuminance: Double {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Double(nsColor.redComponent)
        let g = Double(nsColor.greenComponent)
        let b = Double(nsColor.blueComponent)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

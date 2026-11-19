import SwiftUI
import AppKit

/// RGB selection with a remembered hue, even while the selected color is grey.
struct ColorSelection {
    var hue: Double = 0
    var saturation: Double = 0
    var brightness: Double = 0

    init(color: Color) {
        update(color: color)
    }

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    mutating func update(color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        let r = Double(rgb.redComponent)
        let g = Double(rgb.greenComponent)
        let b = Double(rgb.blueComponent)
        let maximum = max(r, g, b)
        let delta = maximum - min(r, g, b)
        brightness = maximum
        // At black, preserve saturation too, so raising brightness restores the hue.
        if maximum > 0 { saturation = delta / maximum }
        guard delta > 0 else { return }
        let sector: Double
        if maximum == r {
            sector = (g - b) / delta
        } else if maximum == g {
            sector = (b - r) / delta + 2
        } else {
            sector = (r - g) / delta + 4
        }
        hue = (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
    }

    static func normalizedHex(_ text: String) -> String? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return "#" + digits.uppercased()
    }

    @discardableResult
    mutating func applyHex(_ text: String) -> Bool {
        guard let hex = Self.normalizedHex(text) else { return false }
        update(color: Color(hex: hex))
        return true
    }
}

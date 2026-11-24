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

    /// Legacy encoded-RGB brightness estimate, not WCAG relative luminance.
    var perceivedLuminance: Double {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Double(nsColor.redComponent)
        let g = Double(nsColor.greenComponent)
        let b = Double(nsColor.blueComponent)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// WCAG relative luminance after linearizing the sRGB components.
    var relativeLuminance: Double {
        let rgb = NSColor(self).usingColorSpace(.sRGB)!
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    /// Both colors must be opaque rendered surfaces, not uncomposited tints.
    func contrastRatio(against background: Color) -> Double {
        let a = relativeLuminance
        let b = background.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Composite this RGB at an explicit opacity over an opaque RGB background.
    /// Alpha is supplied separately because appearance settings store RGB and opacity independently.
    func composited(over background: Color, opacity: Double) -> Color {
        let rgb = NSColor(self).usingColorSpace(.sRGB)!
        let backing = NSColor(background).usingColorSpace(.sRGB)!
        let alpha = min(max(opacity, 0), 1)
        return Color(
            .sRGB,
            red: Double(rgb.redComponent) * alpha + Double(backing.redComponent) * (1 - alpha),
            green: Double(rgb.greenComponent) * alpha + Double(backing.greenComponent) * (1 - alpha),
            blue: Double(rgb.blueComponent) * alpha + Double(backing.blueComponent) * (1 - alpha),
            opacity: 1
        )
    }

    /// Choose only pure black or white, whichever contrasts more with this surface.
    var blackOrWhiteForeground: Color {
        Color.black.contrastRatio(against: self) >= Color.white.contrastRatio(against: self) ? .black : .white
    }
}

/// Independent user-selected backgrounds; only black/white foregrounds are automatic.
struct TabBarPalette {
    /// Best-effort toolbar reference. Transparent bars may reveal unknown wallpaper.
    let barReference: Color
    let surface: Color
    /// Opaque estimate of the tab fill composited over the bar, used only for contrast.
    let tabReference: Color
    let foreground: Color
    let toolbarForeground: Color
    private let idleAppearance: Appearance
    private let hoveredAppearance: Appearance

    struct Appearance {
        let surface: Color
        let referenceBackground: Color
        let foreground: Color
        let showsSelectionIndicator: Bool
    }

    init(barColor: Color, tabColor: Color, opacity: Double, tabOpacity: Double = 1) {
        let barReference = Color(hex: barColor.toHex()).composited(over: Color(hex: "#141414"), opacity: opacity)
        let tabRGB = Color(hex: tabColor.toHex())
        let alpha = min(max(tabOpacity, 0), 1)
        let tabReference = tabRGB.composited(over: barReference, opacity: alpha)
        self.barReference = barReference
        self.tabReference = tabReference
        // Apply alpha to the fill only; text and icons must remain fully opaque.
        surface = tabRGB.opacity(alpha)
        foreground = tabReference.blackOrWhiteForeground
        toolbarForeground = barReference.blackOrWhiteForeground
        let idleAlpha = alpha * 0.75
        let idleReference = tabRGB.composited(over: barReference, opacity: idleAlpha)
        idleAppearance = Appearance(
            surface: tabRGB.opacity(idleAlpha),
            referenceBackground: idleReference,
            foreground: idleReference.blackOrWhiteForeground,
            showsSelectionIndicator: false
        )
        // Hover changes brightness, not opacity or selection styling.
        let hoverAccent = tabRGB.relativeLuminance > 0.5 ? Color.black : Color.white
        let hoverRGB = hoverAccent.composited(over: tabRGB, opacity: 0.1)
        let hoverReference = hoverRGB.composited(over: barReference, opacity: idleAlpha)
        hoveredAppearance = Appearance(
            surface: hoverRGB.opacity(idleAlpha),
            referenceBackground: hoverReference,
            foreground: hoverReference.blackOrWhiteForeground,
            showsSelectionIndicator: false
        )
    }

    /// Inactive fills track 75% of the chosen opacity, including during hover.
    func appearance(isActive: Bool, isHovered: Bool = false, isEditing: Bool = false) -> Appearance {
        guard isActive || isEditing else { return isHovered ? hoveredAppearance : idleAppearance }
        return Appearance(
            surface: surface,
            referenceBackground: tabReference,
            foreground: foreground,
            showsSelectionIndicator: isActive
        )
    }
}

private struct TabBarPaletteKey: EnvironmentKey {
    static let defaultValue = TabBarPalette(barColor: .black, tabColor: Color(hex: "#262626"), opacity: 0.85)
}

extension EnvironmentValues {
    var tabBarPalette: TabBarPalette {
        get { self[TabBarPaletteKey.self] }
        set { self[TabBarPaletteKey.self] = newValue }
    }
}

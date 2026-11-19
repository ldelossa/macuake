import Testing
import SwiftUI
import AppKit
@testable import Macuake

@Suite
struct TabBarPaletteTests {
    @Test func linearSRGBLuminance() {
        #expect(abs(Color.black.relativeLuminance) < 0.000001)
        #expect(abs(Color.white.relativeLuminance - 1) < 0.000001)
        #expect(abs(Color(hex: "#808080").relativeLuminance - 0.21586) < 0.00001)
        #expect(abs(Color(hex: "#FF0000").relativeLuminance - 0.2126) < 0.00001)
        #expect(abs(Color(hex: "#00FF00").relativeLuminance - 0.7152) < 0.00001)
        #expect(abs(Color(hex: "#0000FF").relativeLuminance - 0.0722) < 0.00001)
    }

    @Test func contrastIsSymmetric() {
        #expect(abs(Color.black.contrastRatio(against: .white) - 21) < 0.00001)
        #expect(Color.white.contrastRatio(against: .black) == Color.black.contrastRatio(against: .white))
        #expect(Color.red.contrastRatio(against: .red) == 1)
    }

    @Test func textChoosesOnlyBlackOrWhiteAgainstTabBackground() {
        #expect(Color.black.blackOrWhiteForeground.toHex() == "#FFFFFF")
        #expect(Color.white.blackOrWhiteForeground.toHex() == "#000000")
        #expect(Color(hex: "#FF0000").blackOrWhiteForeground.toHex() == "#000000")
        #expect(Color(hex: "#0000FF").blackOrWhiteForeground.toHex() == "#FFFFFF")
    }

    @Test func barOpacityOnlyChangesToolbarReference() {
        let tab = Color(hex: "#AD3657")
        let transparent = TabBarPalette(barColor: .white, tabColor: tab, opacity: 0)
        let opaque = TabBarPalette(barColor: .white, tabColor: tab, opacity: 1)
        #expect(transparent.barReference.toHex() == "#141414")
        #expect(opaque.barReference.toHex() == "#FFFFFF")
        #expect(transparent.toolbarForeground.toHex() == "#FFFFFF")
        #expect(opaque.toolbarForeground.toHex() == "#000000")
        #expect(transparent.surface.toHex() == tab.toHex())
        #expect(opaque.surface.toHex() == tab.toHex())
        #expect(transparent.foreground.toHex() == opaque.foreground.toHex())
        let halfway = NSColor(TabBarPalette(barColor: .white, tabColor: tab, opacity: 0.5).barReference).usingColorSpace(.sRGB)!
        #expect(abs(Double(halfway.redComponent) - 137.5 / 255) < 0.000001)
        #expect(TabBarPalette(barColor: .white, tabColor: tab, opacity: -1).barReference.toHex() == "#141414")
        #expect(TabBarPalette(barColor: .white, tabColor: tab, opacity: 2).barReference.toHex() == "#FFFFFF")
    }

    @Test(arguments: ["#000000", "#FFFFFF", "#237E71", "#FF0000", "#0000FF", "#E0B83F"])
    func selectedTabColorIsExactAndIndependentOfBar(hex: String) {
        let tab = Color(hex: hex)
        for bar in [Color.black, .white, Color(hex: "#AD3657")] {
            for opacity in [0.0, 0.25, 0.85, 1.0] {
                let palette = TabBarPalette(barColor: bar, tabColor: tab, opacity: opacity)
                #expect(palette.surface.toHex() == hex)
                #expect(NSColor(palette.surface).alphaComponent == 1)
                #expect(palette.foreground.toHex() == tab.blackOrWhiteForeground.toHex())
            }
        }
    }

    @Test func toolbarContrastIsIndependentOfTabColor() {
        let darkTabs = TabBarPalette(barColor: .white, tabColor: .black, opacity: 1, tabOpacity: 0.85)
        let lightTabs = TabBarPalette(barColor: .white, tabColor: .white, opacity: 1, tabOpacity: 0.25)
        #expect(darkTabs.toolbarForeground.toHex() == "#000000")
        #expect(lightTabs.toolbarForeground.toHex() == darkTabs.toolbarForeground.toHex())
        #expect(darkTabs.foreground.toHex() == "#FFFFFF")
        #expect(lightTabs.foreground.toHex() == "#000000")
    }

    @Test func tabAlphaUsesIndependentSettingNotRGBColorAlpha() {
        let palette = TabBarPalette(barColor: .white, tabColor: Color(hex: "#355B84").opacity(0.2), opacity: 0, tabOpacity: 0.5)
        #expect(palette.surface.toHex() == "#355B84")
        #expect(NSColor(palette.surface).alphaComponent == 0.5)
    }

    @Test func transparentTabsUseBarForTextContrast() {
        let palette = TabBarPalette(barColor: .white, tabColor: .black, opacity: 1, tabOpacity: 0)
        #expect(NSColor(palette.surface).alphaComponent == 0)
        #expect(palette.tabReference.toHex() == palette.barReference.toHex())
        #expect(palette.foreground.toHex() == "#000000")
        #expect(NSColor(palette.foreground).alphaComponent == 1)
    }

    @Test func tabReferenceBlendsBothBackgroundLayers() {
        let palette = TabBarPalette(barColor: .white, tabColor: Color(hex: "#FF0000"), opacity: 0.5, tabOpacity: 0.25)
        let rgb = NSColor(palette.tabReference).usingColorSpace(.sRGB)!
        let barComponent = 0.5 + (20.0 / 255) * 0.5
        #expect(abs(Double(rgb.redComponent) - (0.25 + barComponent * 0.75)) < 0.000001)
        #expect(abs(Double(rgb.greenComponent) - barComponent * 0.75) < 0.000001)
        #expect(abs(Double(rgb.blueComponent) - barComponent * 0.75) < 0.000001)
        #expect(rgb.alphaComponent == 1)
        let grey = TabBarPalette(barColor: .white, tabColor: .black, opacity: 1, tabOpacity: 0.5)
        #expect(grey.foreground.toHex() == "#000000")
    }

    @Test func tabAlphaIsClampedWithoutFadingForegrounds() {
        for (input, expected) in [(-0.5, 0.0), (0.5, 0.5), (2.0, 1.0)] {
            let palette = TabBarPalette(barColor: .black, tabColor: .white, opacity: 1, tabOpacity: input)
            #expect(abs(Double(NSColor(palette.surface).alphaComponent) - expected) < 0.000001)
            #expect(NSColor(palette.foreground).alphaComponent == 1)
            #expect(NSColor(palette.toolbarForeground).alphaComponent == 1)
        }
    }

    @Test func compositingEndpointsAreOpaqueAndClampOpacity() {
        #expect(Color.red.composited(over: .blue, opacity: 0).toHex() == Color.blue.toHex())
        #expect(Color.red.composited(over: .blue, opacity: 1).toHex() == Color.red.toHex())
        #expect(Color.red.composited(over: .blue, opacity: -1).toHex() == Color.blue.toHex())
        #expect(Color.red.composited(over: .blue, opacity: 2).toHex() == Color.red.toHex())
        #expect(NSColor(Color.red.composited(over: .blue, opacity: 0.5)).alphaComponent == 1)
    }

    @Test func gridPreservesChosenTabRGBWithOpaqueBlackOrWhiteContrast() {
        let allowed = ["#FFFFFF", "#000000"]
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 51) {
                    let tab = Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
                    for bar in [Color.black, .white, Color(hex: "#237E71")] {
                        for opacity in [0.0, 0.05, 0.25, 0.5, 0.85, 1.0] {
                            for tabOpacity in [0.0, 0.25, 0.5, 1.0] {
                                let palette = TabBarPalette(barColor: bar, tabColor: tab, opacity: opacity, tabOpacity: tabOpacity)
                                if tabOpacity > 0 { #expect(palette.surface.toHex() == tab.toHex()) }
                                #expect(abs(Double(NSColor(palette.surface).alphaComponent) - tabOpacity) < 0.000001)
                                #expect(NSColor(palette.tabReference).alphaComponent == 1)
                                for color in [palette.foreground, palette.toolbarForeground] {
                                    #expect(allowed.contains(color.toHex()))
                                    #expect(NSColor(color).alphaComponent == 1)
                                }
                                #expect(palette.foreground.contrastRatio(against: palette.tabReference) >= 4.5)
                                #expect(palette.toolbarForeground.contrastRatio(against: palette.barReference) >= 4.5)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Suite
struct ColorSelectionTests {
    @Test(arguments: ["#000000", "#FFFFFF", "#808080", "#FF0000", "#00FF00", "#0000FF", "#355B84", "#AD3657"])
    func rgbHSVRoundTrip(hex: String) {
        #expect(ColorSelection(color: Color(hex: hex)).color.toHex() == hex)
    }

    @Test func achromaticSelectionsRememberHue() {
        var selection = ColorSelection(color: Color(hex: "#0000FF"))
        let hue = selection.hue
        selection.update(color: .black)
        #expect(selection.hue == hue)
        #expect(selection.saturation == 1)
        selection.brightness = 1
        #expect(selection.color.toHex() == "#0000FF")
        selection.update(color: .white)
        #expect(selection.hue == hue)
        #expect(selection.saturation == 0)
        selection.saturation = 1
        #expect(selection.color.toHex() == "#0000FF")
    }

    @Test func hexAcceptsCaseWhitespaceAndOptionalHash() {
        #expect(ColorSelection.normalizedHex("  aBcD09\n") == "#ABCD09")
        #expect(ColorSelection.normalizedHex("#abcdef") == "#ABCDEF")
    }

    @Test(arguments: ["", "#", "#FFF", "#FFFFFFF", "#GG0000", "0x123456", "12 456", "１２３４５６"])
    func invalidHexDoesNotChangeSelection(text: String) {
        var selection = ColorSelection(color: Color(hex: "#355B84"))
        let applied = selection.applyHex(text)
        #expect(!applied)
        #expect(selection.color.toHex() == "#355B84")
    }

    @Test func externalUpdatesAndResetReplaceRGB() {
        var selection = ColorSelection(color: .red)
        let applied = selection.applyHex("355b84")
        #expect(applied)
        #expect(selection.color.toHex() == "#355B84")
        selection.update(color: .black)
        #expect(selection.color.toHex() == "#000000")
        selection.update(color: .white)
        #expect(selection.color.toHex() == "#FFFFFF")
    }
}

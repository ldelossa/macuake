import Testing
import SwiftUI
import AppKit
@testable import Macuake

@Suite
struct TabAppearanceTests {
    private func makePalette(tabOpacity: Double = 1) -> TabBarPalette {
        TabBarPalette(barColor: .white, tabColor: .black, opacity: 1, tabOpacity: tabOpacity)
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func idleTabsTrackSeventyFivePercentOfChosenOpacity(opacity: Double) {
        let palette = makePalette(tabOpacity: opacity)
        let idle = palette.appearance(isActive: false)
        let expectedAlpha = opacity * 0.75
        let expectedReference = Color.black.composited(over: palette.barReference, opacity: expectedAlpha)
        #expect(abs(Double(NSColor(idle.surface).alphaComponent) - expectedAlpha) < 0.000001)
        if opacity > 0 { #expect(idle.surface.toHex() == "#000000") }
        #expect(idle.referenceBackground.toHex() == expectedReference.toHex())
        #expect(idle.foreground.toHex() == expectedReference.blackOrWhiteForeground.toHex())
        #expect(NSColor(idle.foreground).alphaComponent == 1)
        #expect(!idle.showsSelectionIndicator)
    }

    @Test func idleOpacityIsScaledAfterClamping() {
        for (input, expectedAlpha) in [(-0.5, 0.0), (0.5, 0.375), (2.0, 0.75)] {
            let idle = makePalette(tabOpacity: input).appearance(isActive: false)
            #expect(abs(Double(NSColor(idle.surface).alphaComponent) - expectedAlpha) < 0.000001)
        }
    }

    @Test func idleTextUsesItsOwnCompositedFillInsteadOfToolbarContrast() {
        let palette = TabBarPalette(barColor: Color(hex: "#666666"), tabColor: .white, opacity: 1, tabOpacity: 1)
        let idle = palette.appearance(isActive: false)
        #expect(palette.toolbarForeground.toHex() == "#FFFFFF")
        #expect(idle.foreground.toHex() == "#000000")
        #expect(idle.foreground.contrastRatio(against: idle.referenceBackground) >= 4.5)
        #expect(NSColor(idle.foreground).alphaComponent == 1)
    }

    @Test(arguments: [0.0, 0.4, 1.0])
    func selectedTabsKeepExactChosenFillAndOpacity(opacity: Double) {
        let palette = makePalette(tabOpacity: opacity)
        let selected = palette.appearance(isActive: true)
        #expect(abs(Double(NSColor(selected.surface).alphaComponent) - opacity) < 0.000001)
        if opacity > 0 { #expect(selected.surface.toHex() == "#000000") }
        #expect(selected.referenceBackground.toHex() == palette.tabReference.toHex())
        #expect(selected.foreground.toHex() == palette.foreground.toHex())
        #expect(selected.showsSelectionIndicator)
    }

    @Test(arguments: [0.0, 0.4, 1.0])
    func hoverOnlyChangesBrightnessAtTheSameInactiveOpacity(opacity: Double) {
        for (tabHex, expectedHoverHex) in [
            ("#000000", "#1A1A1A"), ("#FFFFFF", "#E6E6E6"), ("#4C879E", "#5E93A8")
        ] {
            let palette = TabBarPalette(
                barColor: .black, tabColor: Color(hex: tabHex), opacity: 1, tabOpacity: opacity
            )
            let idle = palette.appearance(isActive: false)
            let hovered = palette.appearance(isActive: false, isHovered: true)
            #expect(NSColor(hovered.surface).alphaComponent == NSColor(idle.surface).alphaComponent)
            #expect(abs(Double(NSColor(hovered.surface).alphaComponent) - opacity * 0.75) < 0.000001)
            if opacity > 0 {
                let actual = NSColor(hovered.surface).usingColorSpace(.sRGB)!
                let expected = NSColor(Color(hex: expectedHoverHex)).usingColorSpace(.sRGB)!
                // Allow one RGB step at half-step rounding boundaries (e.g. 10% of 255).
                let tolerance = 1.0 / 255
                #expect(abs(Double(actual.redComponent - expected.redComponent)) <= tolerance)
                #expect(abs(Double(actual.greenComponent - expected.greenComponent)) <= tolerance)
                #expect(abs(Double(actual.blueComponent - expected.blueComponent)) <= tolerance)
            }
            #expect(!hovered.showsSelectionIndicator)
            #expect(hovered.foreground.contrastRatio(against: hovered.referenceBackground) >= 4.5)
        }
    }

    @MainActor
    @Test func renderedFillsMatchCompositedReferences() throws {
        for tabHex in ["#000000", "#FFFFFF", "#4C879E"] {
            for opacity in [0.0, 0.5, 1.0] {
                let palette = TabBarPalette(
                    barColor: .black, tabColor: Color(hex: tabHex), opacity: 1, tabOpacity: opacity
                )
                for appearance in [
                    palette.appearance(isActive: false),
                    palette.appearance(isActive: false, isHovered: true),
                    palette.appearance(isActive: true)
                ] {
                    let renderer = ImageRenderer(content:
                        Rectangle().fill(appearance.surface)
                            .frame(width: 16, height: 16)
                            .background(Color.black)
                    )
                    renderer.scale = 1
                    let image = try #require(renderer.cgImage)
                    // Read explicit sRGB bytes, avoiding NSColor's display/HDR interpretation.
                    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                    let context = try #require(CGContext(
                        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: space,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
                    let expected = try #require(NSColor(appearance.referenceBackground).usingColorSpace(.sRGB))
                    let tolerance = 2.0 / 255
                    #expect(abs(Double(pixel[0]) / 255 - Double(expected.redComponent)) < tolerance)
                    #expect(abs(Double(pixel[1]) / 255 - Double(expected.greenComponent)) < tolerance)
                    #expect(abs(Double(pixel[2]) / 255 - Double(expected.blueComponent)) < tolerance)
                    #expect(pixel[3] == 255)
                }
            }
        }
    }

    @Test func renameUsesReadableFaceWithoutInventingSelection() {
        let palette = makePalette(tabOpacity: 0.4)
        let editing = palette.appearance(isActive: false, isEditing: true)
        #expect(abs(Double(NSColor(editing.surface).alphaComponent) - 0.4) < 0.000001)
        #expect(editing.referenceBackground.toHex() == palette.tabReference.toHex())
        #expect(editing.foreground.contrastRatio(against: editing.referenceBackground) >= 4.5)
        #expect(!editing.showsSelectionIndicator)
    }

    @Test func hoveringSelectedTabKeepsSelectionMarkerAndAppearance() {
        let palette = makePalette(tabOpacity: 0.4)
        let selected = palette.appearance(isActive: true)
        let hovered = palette.appearance(isActive: true, isHovered: true)
        #expect(hovered.surface.toHex() == selected.surface.toHex())
        #expect(NSColor(hovered.surface).alphaComponent == NSColor(selected.surface).alphaComponent)
        #expect(hovered.foreground.toHex() == selected.foreground.toHex())
        #expect(hovered.showsSelectionIndicator)
    }

    @Test func zeroOpacityStillHasOpaqueSelectionCueAndLabels() {
        let selected = makePalette(tabOpacity: 0).appearance(isActive: true)
        #expect(NSColor(selected.surface).alphaComponent == 0)
        #expect(NSColor(selected.foreground).alphaComponent == 1)
        #expect(selected.showsSelectionIndicator)
        #expect(selected.foreground.contrastRatio(against: selected.referenceBackground) >= 4.5)
    }

    @Test func allStateCombinationsKeepOpaqueBlackOrWhiteTextWithContrast() {
        for tabHex in ["#000000", "#FFFFFF", "#777777", "#0000FF", "#4A997A", "#E4DED2"] {
            for barHex in ["#000000", "#FFFFFF", "#1286B1"] {
                for barOpacity in [0.0, 0.4, 1.0] {
                    for tabOpacity in [0.0, 0.4, 1.0] {
                        let palette = TabBarPalette(
                            barColor: Color(hex: barHex), tabColor: Color(hex: tabHex),
                            opacity: barOpacity, tabOpacity: tabOpacity
                        )
                        for flags in 0..<8 {
                            let isActive = flags & 1 != 0
                            let appearance = palette.appearance(
                                isActive: isActive, isHovered: flags & 2 != 0, isEditing: flags & 4 != 0
                            )
                            let hasFullFill = isActive || flags & 4 != 0
                            let isHoverOnly = !hasFullFill && flags & 2 != 0
                            let expectedAlpha = tabOpacity * (hasFullFill ? 1 : 0.75)
                            let tabRGB = Color(hex: tabHex)
                            let accent = tabRGB.relativeLuminance > 0.5 ? Color.black : Color.white
                            let expectedRGB = isHoverOnly ? accent.composited(over: tabRGB, opacity: 0.1) : tabRGB
                            let expectedReference = expectedRGB.composited(
                                over: palette.barReference, opacity: expectedAlpha
                            )
                            #expect(abs(Double(NSColor(appearance.surface).alphaComponent) - expectedAlpha) < 0.000001)
                            if tabOpacity > 0 { #expect(appearance.surface.toHex() == expectedRGB.toHex()) }
                            #expect(appearance.referenceBackground.toHex() == expectedReference.toHex())
                            #expect(appearance.showsSelectionIndicator == isActive)
                            #expect(["#000000", "#FFFFFF"].contains(appearance.foreground.toHex()))
                            #expect(NSColor(appearance.foreground).alphaComponent == 1)
                            #expect(NSColor(appearance.referenceBackground).alphaComponent == 1)
                            #expect(appearance.foreground.contrastRatio(against: appearance.referenceBackground) >= 4.5)
                        }
                    }
                }
            }
        }
    }
}

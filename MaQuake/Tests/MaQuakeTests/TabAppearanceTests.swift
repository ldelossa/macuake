import Testing
import SwiftUI
import AppKit
@testable import Macuake

@Suite
struct TabAppearanceTests {
    private func makePalette(tabOpacity: Double = 1) -> TabBarPalette {
        TabBarPalette(barColor: .white, tabColor: .black, opacity: 1, tabOpacity: tabOpacity)
    }

    @Test func idleTabsSitFlatOnBarWithReadableText() {
        let palette = makePalette()
        let idle = palette.appearance(isActive: false)
        #expect(NSColor(idle.surface).alphaComponent == 0)
        #expect(idle.referenceBackground.toHex() == palette.barReference.toHex())
        #expect(idle.foreground.toHex() == "#000000")
        #expect(!idle.showsSelectionIndicator)
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

    @Test func hoverRevealsFaceButDoesNotMarkSelection() {
        let palette = makePalette()
        let hovered = palette.appearance(isActive: false, isHovered: true)
        #expect(hovered.surface.toHex() == "#000000")
        #expect(NSColor(hovered.surface).alphaComponent == 1)
        #expect(hovered.foreground.toHex() == "#FFFFFF")
        #expect(hovered.referenceBackground.toHex() == palette.tabReference.toHex())
        #expect(!hovered.showsSelectionIndicator)
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
                            let hasFace = flags != 0
                            #expect(abs(Double(NSColor(appearance.surface).alphaComponent) - (hasFace ? tabOpacity : 0)) < 0.000001)
                            if hasFace && tabOpacity > 0 { #expect(appearance.surface.toHex() == tabHex) }
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

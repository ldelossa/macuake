import Testing
import SwiftUI
@testable import Macuake

/// Tests for the Color hex/luminance helpers and the WindowController appearance
/// setters (corner radius, tab bar color, tab bar opacity).
@Suite
struct ColorHexTests {

    // MARK: - Hex round-trip

    @Test func blackRoundTrips() {
        let hex = Color.black.toHex()
        #expect(hex == "#000000")
        #expect(Color(hex: hex).toHex() == hex)
    }

    @Test func whiteRoundTrips() {
        let hex = Color.white.toHex()
        #expect(hex == "#FFFFFF")
        #expect(Color(hex: hex).toHex() == hex)
    }

    @Test func midToneRoundTrips() {
        let original = Color(red: 0.2, green: 0.5, blue: 0.8)
        let hex = original.toHex()
        #expect(Color(hex: hex).toHex() == hex)
    }

    // MARK: - Malformed input

    @Test func malformedHex_fallsBackToBlack() {
        #expect(Color(hex: "not-a-color").toHex() == "#000000")
    }

    @Test func emptyHex_fallsBackToBlack() {
        #expect(Color(hex: "").toHex() == "#000000")
    }

    @Test func shortHex_fallsBackToBlack() {
        #expect(Color(hex: "#FFF").toHex() == "#000000")
    }

    // MARK: - Perceived luminance

    @Test func black_hasLowLuminance() {
        #expect(Color.black.perceivedLuminance < 0.5)
    }

    @Test func white_hasHighLuminance() {
        #expect(Color.white.perceivedLuminance > 0.5)
    }

    @Test func midGray_luminanceInRange() {
        let luminance = Color(hex: "#808080").perceivedLuminance
        #expect(luminance > 0.3 && luminance < 0.7)
    }
}

@MainActor
@Suite(.serialized)
struct WindowControllerAppearanceTests {

    // MARK: - setTopCornerRadius clamping

    @Test func setTopCornerRadius_belowMin_clampedTo0() {
        let wc = WindowController()
        wc.setTopCornerRadius(-5)
        #expect(wc.topCornerRadius == 0)
    }

    @Test func setTopCornerRadius_aboveMax_clampedTo20() {
        let wc = WindowController()
        wc.setTopCornerRadius(100)
        #expect(wc.topCornerRadius == 20)
    }

    @Test func setTopCornerRadius_normalValue_setsExactly() {
        let wc = WindowController()
        wc.setTopCornerRadius(8)
        #expect(wc.topCornerRadius == 8)
    }

    // MARK: - setTabBarOpacity clamping

    @Test func setTabBarOpacity_belowMin_clampedTo0() {
        let wc = WindowController()
        wc.setTabBarOpacity(-0.5)
        #expect(wc.tabBarOpacity == 0)
    }

    @Test func setTabBarOpacity_aboveMax_clampedTo1() {
        let wc = WindowController()
        wc.setTabBarOpacity(2.0)
        #expect(wc.tabBarOpacity == 1)
    }

    @Test func setTabBarOpacity_normalValue_setsExactly() {
        let wc = WindowController()
        wc.setTabBarOpacity(0.5)
        #expect(wc.tabBarOpacity == 0.5)
    }

    // MARK: - setTabBarColor / resetTabBarColor

    @Test func setTabBarColor_storesHex() {
        let wc = WindowController()
        wc.setTabBarColor(.white)
        #expect(wc.tabBarColorHex == "#FFFFFF")
    }

    @Test func resetTabBarColor_restoresDefaults() {
        let wc = WindowController()
        wc.setTabBarColor(.white)
        wc.setTabBarOpacity(0.2)
        wc.resetTabBarColor()
        #expect(wc.tabBarColorHex == "#000000")
        #expect(wc.tabBarOpacity == 0.85)
    }
}

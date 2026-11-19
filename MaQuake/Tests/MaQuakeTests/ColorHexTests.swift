import Testing
import SwiftUI
@testable import Macuake

/// Tests for the Color hex/luminance helpers and the WindowController appearance
/// setters (corner radius, independent bar/tab colors, and bar opacity).
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
    private func preservingColorSettings(_ test: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = ["tabColorHex", "tabOpacity", "tabBarColorHex", "tabBarOpacity"].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        test()
    }

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

    // MARK: - Independent tab color

    @Test func tabColor_defaultsWithoutChangingExistingBarSettings() {
        preservingColorSettings {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "tabColorHex")
            defaults.removeObject(forKey: "tabOpacity")
            defaults.set("#237E71", forKey: "tabBarColorHex")
            defaults.set(0.4, forKey: "tabBarOpacity")
            let wc = WindowController()
            #expect(wc.tabColorHex == "#262626")
            #expect(wc.tabOpacity == 1)
            #expect(wc.tabBarColorHex == "#237E71")
            #expect(wc.tabBarOpacity == 0.4)
        }
    }

    @Test func setTabColor_persistsIndependentlyAcrossControllers() {
        preservingColorSettings {
            let wc = WindowController()
            wc.setTabBarColor(Color(hex: "#237E71"))
            wc.setTabBarOpacity(0.35)
            wc.setTabColor(Color(hex: "#AD3657"))
            wc.setTabOpacity(0.55)
            #expect(wc.tabColorHex == "#AD3657")
            #expect(UserDefaults.standard.string(forKey: "tabColorHex") == "#AD3657")
            let restored = WindowController()
            #expect(restored.tabColorHex == "#AD3657")
            #expect(restored.tabOpacity == 0.55)
            #expect(restored.tabBarColorHex == "#237E71")
            #expect(restored.tabBarOpacity == 0.35)
        }
    }

    @Test func resetTabColor_leavesBarAndOpacityUnchanged() {
        preservingColorSettings {
            let wc = WindowController()
            wc.setTabBarColor(Color(hex: "#237E71"))
            wc.setTabBarOpacity(0.35)
            wc.setTabColor(.white)
            wc.setTabOpacity(0.4)
            wc.resetTabColor()
            #expect(wc.tabColorHex == "#262626")
            #expect(UserDefaults.standard.string(forKey: "tabColorHex") == "#262626")
            #expect(wc.tabOpacity == 1)
            #expect(UserDefaults.standard.double(forKey: "tabOpacity") == 1)
            #expect(wc.tabBarColorHex == "#237E71")
            #expect(wc.tabBarOpacity == 0.35)
        }
    }

    @Test func resetBarColor_leavesSelectedTabColorUnchanged() {
        preservingColorSettings {
            let wc = WindowController()
            wc.setTabColor(Color(hex: "#AD3657"))
            wc.setTabOpacity(0.45)
            wc.setTabBarColor(.white)
            wc.setTabBarOpacity(0.2)
            wc.resetTabBarColor()
            #expect(wc.tabBarColorHex == "#000000")
            #expect(wc.tabBarOpacity == 0.85)
            #expect(wc.tabColorHex == "#AD3657")
            #expect(wc.tabOpacity == 0.45)
            #expect(UserDefaults.standard.string(forKey: "tabColorHex") == "#AD3657")
        }
    }

    @Test func tabOpacity_clampsAndPersists() {
        preservingColorSettings {
            let wc = WindowController()
            for (input, expected) in [(-0.5, 0.0), (0.35, 0.35), (1.5, 1.0)] {
                wc.setTabOpacity(input)
                #expect(wc.tabOpacity == expected)
                #expect(UserDefaults.standard.double(forKey: "tabOpacity") == expected)
            }
        }
    }

    @Test func opacityChangesPreserveRGBAndOtherOpacity() {
        preservingColorSettings {
            let wc = WindowController()
            wc.setTabBarColor(Color(hex: "#237E71"))
            wc.setTabColor(Color(hex: "#AD3657"))
            wc.setTabBarOpacity(0.7)
            wc.setTabOpacity(0.4)
            wc.setTabBarOpacity(0.2)
            #expect(wc.tabOpacity == 0.4)
            wc.setTabOpacity(0)
            #expect(wc.tabBarOpacity == 0.2)
            #expect(wc.tabBarColorHex == "#237E71")
            #expect(wc.tabColorHex == "#AD3657")
        }
    }

    @Test func RGBChangesPreserveBothOpacities() {
        preservingColorSettings {
            let wc = WindowController()
            wc.setTabBarOpacity(0.3)
            wc.setTabOpacity(0.45)
            wc.setTabBarColor(.white)
            wc.setTabColor(.black)
            #expect(wc.tabBarOpacity == 0.3)
            #expect(wc.tabOpacity == 0.45)
        }
    }
}

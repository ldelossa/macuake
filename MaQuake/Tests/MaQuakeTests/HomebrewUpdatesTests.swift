import Foundation
import Testing
@testable import Macuake

@Suite
struct HomebrewUpdatesTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func commandsTargetOnlyTheFork() {
        #expect(HomebrewUpdates.cask == "ldelossa/macuake/macuake")
        #expect(HomebrewUpdates.installCommand == "brew install --cask ldelossa/macuake/macuake")
        #expect(HomebrewUpdates.upgradeCommand == "brew upgrade --cask ldelossa/macuake/macuake")
    }

    @Test func bundleHasCompleteMetadataAndNoUpdaterFeed() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("MaQuake/Resources/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleExecutable"] as? String == "Macuake")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["CFBundleIdentifier"] as? String == "com.maquake.app")
        #expect(info["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(info["CFBundleShortVersionString"] as? String == info["CFBundleVersion"] as? String)
        #expect(info["SUFeedURL"] == nil)
        #expect(info["SUPublicEDKey"] == nil)
    }

    @Test func policyDoesNotChangeSavedUpdatePreferences() {
        let keys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUSendProfileInfo"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        _ = HomebrewUpdates.installCommand
        _ = HomebrewUpdates.upgradeCommand
        let after = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        #expect(before == after)
    }
}

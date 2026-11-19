import Testing
import AppKit
@testable import Macuake

@MainActor
@Suite(.serialized)
struct PickerAutoHideTests {
    private func visibleController() -> WindowController {
        let controller = WindowController()
        // Exercise the policy without asynchronous show animation or timing sleeps.
        controller.state = .visible
        return controller
    }

    @Test func unprotectedFocusLossStillHides() {
        let controller = visibleController()
        controller.panel.resignKey()
        controller.requestAutoHide(.focusLoss)
        #expect(controller.state == .hidden)
    }

    @Test func pickerFocusLossStaysVisibleWithoutPinning() {
        let controller = visibleController()
        controller.setTransientInteraction(UUID(), isPresented: true)
        controller.panel.resignKey()
        controller.requestAutoHide(.focusLoss)
        controller.requestAutoHide(.focusLoss)
        #expect(controller.state == .visible)
        #expect(controller.hasTransientInteraction)
        #expect(!controller.isPinned)
    }

    @Test func dismissalRestoresOrdinaryFocusLossBehavior() {
        let controller = visibleController()
        let picker = UUID()
        controller.setTransientInteraction(picker, isPresented: true)
        controller.setTransientInteraction(picker, isPresented: false)
        #expect(!controller.hasTransientInteraction)
        // A subsequent real focus loss, not the dismissal's restored parent focus.
        controller.panel.resignKey()
        controller.requestAutoHide(.focusLoss)
        #expect(controller.state == .hidden)
    }

    @Test func overlappingPickersReleaseIndependently() {
        let controller = visibleController()
        let barPicker = UUID()
        let tabPicker = UUID()
        controller.setTransientInteraction(barPicker, isPresented: true)
        controller.setTransientInteraction(tabPicker, isPresented: true)
        controller.setTransientInteraction(barPicker, isPresented: false)
        controller.requestAutoHide(.focusLoss)
        #expect(controller.hasTransientInteraction)
        #expect(controller.state == .visible)
        controller.setTransientInteraction(tabPicker, isPresented: false)
        #expect(!controller.hasTransientInteraction)
    }

    @Test func repeatedPresentationAndCleanupAreIdempotent() {
        let controller = visibleController()
        let picker = UUID()
        controller.setTransientInteraction(picker, isPresented: true)
        controller.setTransientInteraction(picker, isPresented: true)
        controller.setTransientInteraction(picker, isPresented: false)
        controller.setTransientInteraction(picker, isPresented: false)
        #expect(!controller.hasTransientInteraction)
        #expect(!controller.isPinned)
    }

    @Test func unknownDismissalDoesNotReleaseAnotherPicker() {
        let controller = visibleController()
        controller.setTransientInteraction(UUID(), isPresented: true)
        controller.setTransientInteraction(UUID(), isPresented: false)
        #expect(controller.hasTransientInteraction)
    }

    @Test(arguments: [WindowController.AutoHideReason.outsideClick, .applicationSwitch])
    func leavingTheAppStillHidesDuringColorSelection(reason: WindowController.AutoHideReason) {
        let controller = visibleController()
        controller.setTransientInteraction(UUID(), isPresented: true)
        controller.requestAutoHide(reason)
        #expect(controller.state == .hidden)
        #expect(!controller.hasTransientInteraction)
    }

    @Test func explicitHideClosesInteractionWithoutRevivingParent() {
        let controller = visibleController()
        let picker = UUID()
        controller.setTransientInteraction(picker, isPresented: true)
        controller.hide()
        controller.setTransientInteraction(picker, isPresented: false)
        #expect(controller.state == .hidden)
        #expect(!controller.hasTransientInteraction)
    }

    @Test func explicitToggleStillHidesWhilePickerIsOpen() {
        let controller = visibleController()
        controller.setTransientInteraction(UUID(), isPresented: true)
        controller.toggle()
        #expect(controller.state == .hidden)
        #expect(!controller.hasTransientInteraction)
    }

    @Test func pinBehaviorIsUnchanged() {
        let controller = visibleController()
        controller.isPinned = true
        let picker = UUID()
        controller.setTransientInteraction(picker, isPresented: true)
        controller.requestAutoHide(.focusLoss)
        controller.requestAutoHide(.outsideClick)
        controller.requestAutoHide(.applicationSwitch)
        controller.setTransientInteraction(picker, isPresented: false)
        #expect(controller.state == .visible)
        #expect(controller.isPinned)
        #expect(!controller.hasTransientInteraction)
        controller.hide()
        #expect(controller.state == .hidden)
    }

    @Test func hiddenParentDoesNotAcquireNewProtection() {
        let controller = WindowController()
        controller.setTransientInteraction(UUID(), isPresented: true)
        #expect(controller.state == .hidden)
        #expect(!controller.hasTransientInteraction)
    }

    @Test func regainedParentKeyFocusIgnoresStaleResignRequest() {
        let controller = visibleController()
        controller.panel.makeKey()
        #expect(controller.panel.isKeyWindow)
        controller.requestAutoHide(.focusLoss)
        #expect(controller.state == .visible)
    }

    @Test func cleanupDoesNotActivateOverAnotherApplication() {
        let controller = visibleController()
        let picker = UUID()
        controller.setTransientInteraction(picker, isPresented: true)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.setTransientInteraction(picker, isPresented: false)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID)
    }

    @Test func focusAndAppSwitchKeepExistingDebounceButOutsideClickDoesNot() {
        // An unshown controller has showTimestamp == .distantPast; inject time
        // relative to that baseline to test the grace period deterministically.
        for reason in [WindowController.AutoHideReason.focusLoss, .applicationSwitch] {
            let controller = visibleController()
            controller.panel.resignKey()
            controller.requestAutoHide(reason, at: Date.distantPast.addingTimeInterval(0.1))
            #expect(controller.state == .visible)
            controller.requestAutoHide(reason, at: Date.distantPast.addingTimeInterval(1))
            #expect(controller.state == .hidden)
        }
        let controller = visibleController()
        controller.requestAutoHide(.outsideClick, at: .distantPast)
        #expect(controller.state == .hidden)
    }
}

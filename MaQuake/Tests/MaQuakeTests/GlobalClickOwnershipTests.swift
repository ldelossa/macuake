import Testing
import AppKit
@testable import Macuake

@MainActor
@Suite(.serialized)
struct GlobalClickOwnershipTests {
    private func visibleController() -> WindowController {
        let controller = WindowController()
        controller.state = .visible
        return controller
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func terminalWindowClickIsNotOutside() {
        let controller = visibleController()
        #expect(controller.panel.windowNumber > 0)
        controller.handleGlobalMouseDown(windowNumber: controller.panel.windowNumber)
        #expect(controller.state == .visible)
        #expect(!controller.isPinned)
    }

    @Test func ownedPopoverClickWithActivePickerDoesNotHide() {
        let controller = visibleController()
        let popover = makeWindow()
        controller.panel.addChildWindow(popover, ordered: .above)
        defer {
            controller.panel.removeChildWindow(popover)
            popover.close()
        }
        controller.setTransientInteraction(UUID(), isPresented: true)
        #expect(popover.parent === controller.panel)
        #expect(NSApp.window(withWindowNumber: popover.windowNumber) === popover)

        // Replay the captured route: global monitor reports the child popup's ID.
        controller.handleGlobalMouseDown(windowNumber: popover.windowNumber)
        #expect(controller.state == .visible)
        #expect(controller.hasTransientInteraction)
        #expect(!controller.isPinned)
    }

    @Test func descendantWindowAncestryIsRecognized() {
        let controller = visibleController()
        let child = makeWindow()
        let grandchild = makeWindow()
        controller.panel.addChildWindow(child, ordered: .above)
        child.addChildWindow(grandchild, ordered: .above)
        defer {
            child.removeChildWindow(grandchild)
            controller.panel.removeChildWindow(child)
            grandchild.close()
            child.close()
        }
        controller.handleGlobalMouseDown(windowNumber: grandchild.windowNumber)
        #expect(controller.state == .visible)
    }

    @Test func ownedWindowDoesNotDependOnPickerTokenOrPrivateWindowClass() {
        let controller = visibleController()
        let child = makeWindow()
        controller.panel.addChildWindow(child, ordered: .above)
        defer {
            controller.panel.removeChildWindow(child)
            child.close()
        }
        #expect(!controller.hasTransientInteraction)
        controller.handleGlobalMouseDown(windowNumber: child.windowNumber)
        #expect(controller.state == .visible)
    }

    @Test func unrelatedApplicationWindowStillHidesWithPickerOpen() {
        let controller = visibleController()
        let unrelated = makeWindow()
        defer { unrelated.close() }
        unrelated.orderFront(nil)
        controller.setTransientInteraction(UUID(), isPresented: true)
        #expect(unrelated.parent == nil)
        #expect(NSApp.window(withWindowNumber: unrelated.windowNumber) === unrelated)
        controller.handleGlobalMouseDown(windowNumber: unrelated.windowNumber)
        #expect(controller.state == .hidden)
        #expect(!controller.hasTransientInteraction)
    }

    @Test(arguments: [0, -1, 2_000_000_000])
    func unknownOrExternalWindowStillHides(windowNumber: Int) {
        let controller = visibleController()
        controller.setTransientInteraction(UUID(), isPresented: true)
        controller.handleGlobalMouseDown(windowNumber: windowNumber)
        #expect(controller.state == .hidden)
        #expect(!controller.hasTransientInteraction)
    }

    @Test func detachedWindowIsNoLongerOwnedByTerminal() {
        let controller = visibleController()
        let child = makeWindow()
        defer { child.close() }
        controller.panel.addChildWindow(child, ordered: .above)
        controller.panel.removeChildWindow(child)
        controller.handleGlobalMouseDown(windowNumber: child.windowNumber)
        #expect(controller.state == .hidden)
    }

    @Test func ownedClickIsDecidedBeforePopupCloses() {
        let controller = visibleController()
        let child = makeWindow()
        controller.panel.addChildWindow(child, ordered: .above)
        controller.handleGlobalMouseDown(windowNumber: child.windowNumber)
        controller.panel.removeChildWindow(child)
        child.close()
        #expect(controller.state == .visible)
    }

    @Test func genuineExternalClickStillRespectsPinning() {
        let controller = visibleController()
        controller.isPinned = true
        controller.handleGlobalMouseDown(windowNumber: 0)
        #expect(controller.state == .visible)
        #expect(controller.isPinned)
    }
}

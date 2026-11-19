import AppKit
import SwiftUI
import Testing
@testable import Macuake

/// Exercise real AppKit responder assignment without activating the test process
/// or disturbing the user's running terminal. Only window eligibility is simulated.
@MainActor
@Suite(.serialized)
struct SplitFocusTests {
    final class FocusWindow: NSWindow {
        var reportsKey = true
        var reportsVisible = true
        override var isKeyWindow: Bool { reportsKey }
        override var isVisible: Bool { reportsVisible }

        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                       styleMask: [.titled], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
        }
    }

    private func hosted() throws -> (TabManager, PaneManager, FocusWindow) {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        let window = FocusWindow()
        window.contentView = NSHostingView(rootView: PaneSplitView(
            paneManager: panes, tabManager: manager, theme: manager.theme
        ))
        window.contentView?.layoutSubtreeIfNeeded()
        return (manager, panes, window)
    }

    private func dispose(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func waitForFocus(_ view: NSView, in window: NSWindow) async -> Bool {
        for _ in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            if window.firstResponder === view { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return window.firstResponder === view
    }

    @Test(arguments: [Axis.horizontal, .vertical])
    func newSplitReceivesKeyboardFocus(axis: Axis) async throws {
        let (manager, panes, window) = try hosted()
        defer { dispose(window) }
        let original = try #require(panes.focusedBackend?.focusableView)
        #expect(await waitForFocus(original, in: window))

        try #require(manager.splitActivePane(axis: axis))
        let newView = try #require(panes.focusedBackend?.focusableView)
        #expect(newView !== original)
        #expect(await waitForFocus(newView, in: window))
        // A later SwiftUI tree update must not undo the responder handoff.
        try await Task.sleep(for: .milliseconds(125))
        #expect(window.firstResponder === newView)
    }

    @Test func directAndNestedSplitsReceiveKeyboardFocus() async throws {
        let (_, panes, window) = try hosted()
        defer { dispose(window) }
        let originalID = panes.focusedPaneID
        let original = try #require(panes.focusedBackend?.focusableView)
        #expect(await waitForFocus(original, in: window))

        // Context menus call PaneManager directly, including a nonselected pane.
        try #require(panes.splitPane(id: originalID, axis: .horizontal))
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
        try #require(panes.splitPane(id: originalID, axis: .vertical))
        #expect(panes.rootPane.leafCount == 3)
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
    }

    @Test func navigationAndClosingRestoreKeyboardFocus() async throws {
        let (manager, panes, window) = try hosted()
        defer { dispose(window) }
        let original = try #require(panes.focusedBackend?.focusableView)
        #expect(await waitForFocus(original, in: window))
        try #require(manager.splitActivePane(axis: .horizontal))
        let second = try #require(panes.focusedBackend?.focusableView)
        #expect(await waitForFocus(second, in: window))

        manager.moveFocusInActiveTab(.previous)
        #expect(await waitForFocus(original, in: window))
        manager.moveFocusInActiveTab(.next)
        #expect(await waitForFocus(second, in: window))
        manager.closeActivePane()
        #expect(panes.rootPane.leafCount == 1)
        #expect(await waitForFocus(original, in: window))
    }

    @Test func closingUnfocusedPanePreservesResponderAfterTreeCollapse() async throws {
        let (manager, panes, window) = try hosted()
        defer { dispose(window) }
        let originalID = panes.focusedPaneID
        try #require(manager.splitActivePane(axis: .horizontal))
        let selected = try #require(panes.focusedBackend?.focusableView)
        #expect(await waitForFocus(selected, in: window))
        panes.closePane(id: originalID)
        #expect(await waitForFocus(selected, in: window))
    }

    @Test func pendingFocusWaitsForAttachment() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        try #require(manager.splitActivePane(axis: .vertical))
        let backend = try #require(panes.focusedBackend)
        try await Task.sleep(for: .milliseconds(100))
        let window = FocusWindow()
        defer { dispose(window) }
        window.contentView?.addSubview(backend.view)
        #expect(await waitForFocus(backend.focusableView, in: window))
    }

    @Test func oldPaneRequestCannotOverrideNewSelection() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        let originalID = panes.focusedPaneID
        let originalBackend = try #require(panes.focusedBackend)
        try #require(manager.splitActivePane(axis: .horizontal))
        let selectedBackend = try #require(panes.focusedBackend)
        let window = FocusWindow()
        defer { dispose(window) }
        window.contentView?.addSubview(selectedBackend.view)
        #expect(await waitForFocus(selectedBackend.focusableView, in: window))

        // An older detached pane becomes available after the selected one.
        window.contentView?.addSubview(originalBackend.view)
        try await Task.sleep(for: .milliseconds(150))
        #expect(panes.focusedPaneID != originalID)
        #expect(window.firstResponder === selectedBackend.focusableView)
    }

    @Test func oldTabRequestCannotOverrideNewTab() async throws {
        let manager = TabManager()
        let oldBackend = try #require(manager.activeTab?.paneManager?.focusedBackend)
        manager.addTab()
        let selectedBackend = try #require(manager.activeTab?.paneManager?.focusedBackend)
        let window = FocusWindow()
        defer { dispose(window) }
        window.contentView?.addSubview(selectedBackend.view)
        #expect(await waitForFocus(selectedBackend.focusableView, in: window))
        window.contentView?.addSubview(oldBackend.view)
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.firstResponder === selectedBackend.focusableView)
    }

    @Test func inactivePaneManagerCannotStealFocus() async throws {
        let manager = TabManager()
        let oldPanes = try #require(manager.activeTab?.paneManager)
        manager.addTab()
        let selectedBackend = try #require(manager.activeTab?.paneManager?.focusedBackend)
        let window = FocusWindow()
        defer { dispose(window) }
        window.contentView?.addSubview(selectedBackend.view)
        #expect(await waitForFocus(selectedBackend.focusableView, in: window))
        try #require(oldPanes.splitFocusedPane(axis: .horizontal))
        window.contentView?.addSubview(try #require(oldPanes.focusedBackend?.view))
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.firstResponder === selectedBackend.focusableView)
    }

    @Test func temporarySelectionDuringResizeDoesNotStealEditorFocus() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        let originalID = panes.focusedPaneID
        try #require(manager.splitActivePane(axis: .horizontal))
        let selectedID = panes.focusedPaneID
        let backend = try #require(panes.focusedBackend)
        let window = FocusWindow()
        defer { dispose(window) }
        window.contentView?.addSubview(backend.view)
        #expect(await waitForFocus(backend.focusableView, in: window))
        let editor = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        window.contentView?.addSubview(editor)
        try #require(window.makeFirstResponder(editor))
        let responder = try #require(window.firstResponder)

        // The API resize path temporarily changes selection for its calculation.
        // These bookkeeping assignments are not user requests for keyboard focus.
        panes.focusedPaneID = originalID
        panes.resizeFocusedSplit(delta: 0.05)
        panes.focusedPaneID = selectedID
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.firstResponder === responder)
    }

    @Test(arguments: ["nonkey", "hidden", "child", "ignoresMouse"])
    func ineligibleWindowDoesNotReceiveFocus(reason: String) async throws {
        let manager = TabManager()
        let backend = try #require(manager.activeTab?.paneManager?.focusedBackend)
        let window = FocusWindow()
        let child = FocusWindow()
        defer { dispose(child); dispose(window) }
        switch reason {
        case "nonkey": window.reportsKey = false
        case "hidden": window.reportsVisible = false
        case "ignoresMouse": window.ignoresMouseEvents = true
        default: window.addChildWindow(child, ordered: .above)
        }
        window.contentView?.addSubview(backend.view)
        manager.focusTerminalInActiveTab()
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.firstResponder !== backend.focusableView)
    }
}

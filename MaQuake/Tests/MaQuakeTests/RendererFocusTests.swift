import AppKit
import SwiftUI
import Testing
@testable import Macuake

/// Ghostty is disabled in unit tests, so assert the renderer focus commands and
/// real AppKit responder lifecycle. Actual cursor animation is a native check.
@MainActor
@Suite(.serialized)
struct RendererFocusTests {
    private func attach(_ backends: [GhosttyBackend]) -> SplitFocusTests.FocusWindow {
        let window = SplitFocusTests.FocusWindow()
        for backend in backends { window.contentView?.addSubview(backend.view) }
        return window
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

    private func expectOnlySelectedFocused(_ panes: PaneManager, in window: NSWindow) throws {
        let selected = try #require(panes.focusedBackend as? GhosttyBackend)
        if ProcessInfo.processInfo.environment["MACUAKE_TEST_GHOSTTY"] == "1" {
            for id in panes.rootPane.leafIDs {
                let backend = try #require(panes.rootPane.backend(for: id) as? GhosttyBackend)
                try #require(backend.surface != nil, "GPU opt-in must exercise actual Ghostty surfaces")
            }
        }
        #expect(window.firstResponder === selected.focusableView)
        let focusedIDs = panes.rootPane.leafIDs.filter {
            (panes.rootPane.backend(for: $0) as? GhosttyBackend)?.isSurfaceFocused == true
        }
        #expect(focusedIDs == [panes.focusedPaneID])
    }

    @Test func newAndUnselectedBackendsStartUnfocused() {
        let selected = GhosttyBackend()
        let inactive = GhosttyBackend()
        let window = attach([selected, inactive])
        defer { dispose(window) }
        #expect(!selected.isSurfaceFocused)
        #expect(!inactive.isSurfaceFocused)
        #expect(window.makeFirstResponder(selected.focusableView))
        #expect(selected.isSurfaceFocused)
        #expect(!inactive.isSurfaceFocused)
    }

    @Test func nativeTransferClearsEvenStaleSurfaceFocus() throws {
        let stale = GhosttyBackend()
        let selected = GhosttyBackend()
        let window = attach([stale, selected])
        defer { dispose(window) }
        // Reproduce an old surface that missed its native resignation callback.
        stale.setSurfaceFocus(true)
        try #require(window.makeFirstResponder(selected.focusableView))
        #expect(selected.isSurfaceFocused)
        #expect(!stale.isSurfaceFocused)
    }

    @Test func detachClearsFocusAndReattachmentReconcilesResponder() throws {
        let backend = GhosttyBackend()
        let window = attach([backend])
        defer { dispose(window) }
        try #require(window.makeFirstResponder(backend.focusableView))
        #expect(backend.isSurfaceFocused)
        backend.view.removeFromSuperview()
        #expect(!backend.isSurfaceFocused)
        window.contentView?.addSubview(backend.view)
        try #require(window.makeFirstResponder(backend.focusableView))
        #expect(backend.isSurfaceFocused)
    }

    @Test func textEditorReceivesFocusWithoutAnyBlinkingTerminal() throws {
        let backend = GhosttyBackend()
        let window = attach([backend])
        defer { dispose(window) }
        try #require(window.makeFirstResponder(backend.focusableView))
        let editor = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        window.contentView?.addSubview(editor)
        try #require(window.makeFirstResponder(editor))
        #expect(!backend.isSurfaceFocused)
    }

    @Test func keyWindowChangesStopAndResumeRendererFocus() throws {
        let backend = GhosttyBackend()
        let window = attach([backend])
        defer { dispose(window) }
        try #require(window.makeFirstResponder(backend.focusableView))
        #expect(backend.isSurfaceFocused)
        window.reportsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!backend.isSurfaceFocused)
        window.reportsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(backend.isSurfaceFocused)
    }

    @Test func keyChildWindowSuppressesParentCursor() throws {
        let backend = GhosttyBackend()
        let window = attach([backend])
        let child = SplitFocusTests.FocusWindow()
        defer { dispose(child); dispose(window) }
        try #require(window.makeFirstResponder(backend.focusableView))
        window.addChildWindow(child, ordered: .above)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: child)
        #expect(!backend.isSurfaceFocused)
        child.reportsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: child)
        #expect(backend.isSurfaceFocused)
    }

    @Test(arguments: [Axis.horizontal, .vertical])
    func hostedSplitsAndNavigationKeepExactlyOneSurfaceFocused(axis: Axis) async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        let window = SplitFocusTests.FocusWindow()
        window.contentView = NSHostingView(rootView: PaneSplitView(
            paneManager: panes, tabManager: manager, theme: manager.theme
        ))
        defer { dispose(window) }
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
        try expectOnlySelectedFocused(panes, in: window)
        try #require(manager.splitActivePane(axis: axis))
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
        try expectOnlySelectedFocused(panes, in: window)
        try #require(manager.splitActivePane(axis: axis == .horizontal ? .vertical : .horizontal))
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
        try expectOnlySelectedFocused(panes, in: window)
        manager.moveFocusInActiveTab(.previous)
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
        try expectOnlySelectedFocused(panes, in: window)
        manager.closeActivePane()
        #expect(await waitForFocus(try #require(panes.focusedBackend?.focusableView), in: window))
        try expectOnlySelectedFocused(panes, in: window)
    }

    @Test func terminatedSurfaceIsUnfocused() throws {
        let backend = GhosttyBackend()
        let window = attach([backend])
        defer { dispose(window) }
        try #require(window.makeFirstResponder(backend.focusableView))
        backend.terminate()
        #expect(!backend.isSurfaceFocused)
    }
}

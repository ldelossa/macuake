import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Macuake

@MainActor
@Suite(.serialized)
struct PaneZoomTests {
    private func dispose(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func wait(in window: NSWindow? = nil, until condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func signature(_ node: PaneNode) -> String {
        switch node {
        case .leaf(let id, let backend):
            return "leaf:\(id):\(ObjectIdentifier(backend))"
        case .split(let id, let axis, let first, let second, let ratio):
            return "split:\(id):\(axis):\(ratio)[\(signature(first))][\(signature(second))]"
        }
    }

    private func hosted(_ panes: PaneManager, manager: TabManager) -> SplitFocusTests.FocusWindow {
        let window = SplitFocusTests.FocusWindow()
        window.contentView = NSHostingView(rootView: PaneSplitView(
            paneManager: panes, tabManager: manager, theme: manager.theme
        ))
        return window
    }

    private func expectZoomedFocus(_ panes: PaneManager, in window: NSWindow) throws {
        #expect(panes.isZoomed)
        let selected = try #require(panes.focusedBackend as? GhosttyBackend)
        #expect(window.firstResponder === selected.focusableView)
        for id in panes.rootPane.leafIDs {
            let backend = try #require(panes.rootPane.backend(for: id) as? GhosttyBackend)
            #expect(backend.isSurfaceFocused == (id == panes.focusedPaneID))
            #expect((backend.view.window === window) == (id == panes.focusedPaneID))
            if ProcessInfo.processInfo.environment["MACUAKE_TEST_GHOSTTY"] == "1" {
                try #require(backend.surface != nil, "Hidden sessions must retain actual Ghostty surfaces")
            }
        }
    }

    @Test(arguments: [Axis.horizontal, .vertical])
    func nativeZoomActionFillsTabAndRestoresExactLayout(axis: Axis) async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        let originalID = panes.focusedPaneID
        try #require(panes.splitFocusedPane(axis: axis, ratio: 0.37))
        let selected = try #require(panes.focusedBackend as? GhosttyBackend)
        let other = try #require(panes.rootPane.backend(for: originalID))
        let treeID = panes.rootPane.id
        let leafIDs = panes.rootPane.leafIDs
        let instance = try #require(panes.focusedInstance)
        let window = SplitFocusTests.FocusWindow()
        window.contentView = NSHostingView(rootView: PaneSplitView(
            paneManager: panes, tabManager: manager, theme: manager.theme
        ))
        defer { dispose(window); panes.rootPane.terminateAll() }
        #expect(await wait(in: window) {
            window.firstResponder === selected.focusableView && other.view.window === window
        })
        let originalSize = selected.view.bounds.size

        // Ghostty forwards this action to TerminalInstance's delegate method.
        instance.terminalRequestedToggleSplitZoom()
        #expect(await wait(in: window) {
            guard let bounds = window.contentView?.bounds else { return false }
            return selected.view.window === window && other.view.window == nil
                && abs(selected.view.bounds.width - bounds.width) < 1
                && abs(selected.view.bounds.height - bounds.height) < 1
                && window.firstResponder === selected.focusableView
        })
        #expect(panes.rootPane.id == treeID)
        #expect(panes.rootPane.leafIDs == leafIDs)
        #expect(selected.isSurfaceFocused)

        instance.terminalRequestedToggleSplitZoom()
        #expect(await wait(in: window) {
            other.view.window === window && window.firstResponder === selected.focusableView
                && abs(selected.view.bounds.width - originalSize.width) < 1
                && abs(selected.view.bounds.height - originalSize.height) < 1
        })
        if case .split(_, _, _, _, let ratio) = panes.rootPane {
            #expect(ratio == 0.37)
        } else {
            Issue.record("Zoom must not replace the underlying split tree")
        }
    }

    @Test func singlePaneZoomIsNoOp() {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        let before = signature(panes.rootPane)
        var focusRequests = 0
        panes.onFocusChange = { focusRequests += 1 }
        panes.toggleZoom()
        #expect(!panes.isZoomed)
        #expect(signature(panes.rootPane) == before)
        #expect(focusRequests == 0)
    }

    @Test func repeatedZoomPreservesNestedTreeAndBackendIdentity() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        try #require(panes.splitFocusedPane(axis: .horizontal, ratio: 0.23))
        try #require(panes.splitFocusedPane(axis: .vertical, ratio: 0.68))
        let before = signature(panes.rootPane)
        let focusedID = panes.focusedPaneID
        for _ in 0..<8 {
            panes.toggleZoom()
            #expect(panes.isZoomed)
            #expect(signature(panes.rootPane) == before)
            panes.toggleZoom()
            #expect(!panes.isZoomed)
            #expect(signature(panes.rootPane) == before)
            #expect(panes.focusedPaneID == focusedID)
        }
    }

    @Test func zoomFollowsPaneNavigation() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        try #require(panes.splitFocusedPane(axis: .horizontal))
        let originalFocus = panes.focusedPaneID
        let before = signature(panes.rootPane)
        panes.toggleZoom()
        panes.moveFocus(.previous)
        #expect(panes.isZoomed)
        #expect(panes.focusedPaneID != originalFocus)
        panes.moveFocus(.next)
        #expect(panes.isZoomed)
        #expect(panes.focusedPaneID == originalFocus)
        #expect(signature(panes.rootPane) == before)
    }

    @Test func creatingSplitExitsZoomAndRetainsExistingSessions() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        try #require(panes.splitFocusedPane(axis: .horizontal))
        let oldIDs = panes.rootPane.leafIDs
        let oldBackends = oldIDs.compactMap { panes.rootPane.backend(for: $0) }
        panes.toggleZoom()
        try #require(panes.splitFocusedPane(axis: .vertical))
        #expect(!panes.isZoomed)
        #expect(panes.rootPane.leafCount == 3)
        for (id, backend) in zip(oldIDs, oldBackends) {
            #expect(panes.rootPane.backend(for: id) === backend)
        }
    }

    @Test func closingZoomedPaneRestoresSurvivingLayout() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        try #require(panes.splitFocusedPane(axis: .horizontal))
        try #require(panes.splitFocusedPane(axis: .vertical))
        panes.toggleZoom()
        let removedID = panes.focusedPaneID
        #expect(panes.closePane(id: removedID))
        #expect(!panes.isZoomed)
        #expect(panes.rootPane.leafCount == 2)
        #expect(panes.rootPane.backend(for: removedID) == nil)
        #expect(panes.focusedBackend != nil)
    }

    @Test func closingHiddenPaneKeepsZoomUntilOnlyOneRemains() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        try #require(panes.splitFocusedPane(axis: .horizontal))
        try #require(panes.splitFocusedPane(axis: .vertical))
        let focusedID = panes.focusedPaneID
        panes.toggleZoom()
        let hiddenIDs = panes.rootPane.leafIDs.filter { $0 != focusedID }
        panes.closePane(id: hiddenIDs[0])
        #expect(panes.isZoomed)
        panes.closePane(id: hiddenIDs[1])
        #expect(!panes.isZoomed)
        #expect(panes.focusedPaneID == focusedID)
        #expect(panes.rootPane.leafCount == 1)
    }

    @Test func staleSourceAndFailedSplitDoNotChangeZoom() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        let removedID = panes.focusedPaneID
        try #require(panes.splitFocusedPane(axis: .horizontal))
        try #require(panes.splitFocusedPane(axis: .vertical))
        panes.closePane(id: removedID)
        panes.toggleZoom()
        let before = signature(panes.rootPane)
        let focusedID = panes.focusedPaneID
        panes.toggleZoom(for: removedID)
        #expect(!panes.splitPane(id: removedID, axis: .horizontal))
        #expect(panes.isZoomed)
        #expect(panes.focusedPaneID == focusedID)
        #expect(signature(panes.rootPane) == before)
    }

    @Test func delegateTargetsItsOwnTabAndSourcePane() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        let panes = try #require(manager.activeTab?.paneManager)
        let sourceID = panes.focusedPaneID
        let source = try #require(panes.focusedInstance)
        try #require(panes.splitFocusedPane(axis: .horizontal))
        manager.addTab()
        let sourceTabIndex = try #require(manager.tabs.firstIndex { $0.paneManager === panes })
        let activeID = try #require(manager.activeTab?.id)
        let otherPanes = try #require(manager.activeTab?.paneManager)
        source.terminalRequestedToggleSplitZoom()
        #expect(await wait { panes.isZoomed })
        #expect(panes.focusedPaneID == sourceID)
        #expect(!otherPanes.isZoomed)
        #expect(manager.activeTab?.id == activeID)
        manager.selectTab(at: sourceTabIndex)
        #expect(manager.activeTab?.paneManager === panes)
        #expect(panes.isZoomed)
    }

    @Test func temporaryResizeSelectionDoesNotCancelZoomOrRequestFocus() throws {
        let panes = PaneManager()
        defer { panes.rootPane.terminateAll() }
        try #require(panes.splitFocusedPane(axis: .horizontal))
        panes.toggleZoom()
        let focusedID = panes.focusedPaneID
        var focusRequests = 0
        panes.onFocusChange = { focusRequests += 1 }
        panes.focusedPaneID = panes.rootPane.leafIDs.first!
        panes.resizeFocusedSplit(delta: 0.05)
        panes.focusedPaneID = focusedID
        #expect(panes.isZoomed)
        #expect(focusRequests == 0)
    }

    @Test func nativeNavigationAndDirectSelectionSwapZoomedView() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        try #require(panes.splitFocusedPane(axis: .horizontal))
        try #require(panes.splitFocusedPane(axis: .vertical))
        let window = hosted(panes, manager: manager)
        defer { dispose(window); panes.rootPane.terminateAll() }
        // A shortcut is delivered only after the native terminal is mounted.
        #expect(await wait(in: window) {
            window.firstResponder === panes.focusedBackend?.focusableView
                && panes.rootPane.leafIDs.allSatisfy { panes.rootPane.backend(for: $0)?.view.window === window }
        })
        panes.toggleZoom()
        for _ in 0..<3 {
            let selected = try #require(panes.focusedBackend)
            #expect(await wait(in: window) {
                window.firstResponder === selected.focusableView
                    && panes.rootPane.leafIDs.allSatisfy {
                        (panes.rootPane.backend(for: $0)?.view.window === window) == ($0 == panes.focusedPaneID)
                    }
            })
            try expectZoomedFocus(panes, in: window)
            manager.moveFocusInActiveTab(.previous)
        }
        // API focus uses a direct model assignment followed by native focus.
        panes.focusedPaneID = panes.rootPane.leafIDs.first!
        manager.focusTerminalInActiveTab()
        let selected = try #require(panes.focusedBackend)
        #expect(await wait(in: window) { window.firstResponder === selected.focusableView })
        try expectZoomedFocus(panes, in: window)
    }

    @Test func nativeStructuralEditsRestoreLayoutAndKeyboardFocus() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        try #require(panes.splitFocusedPane(axis: .horizontal))
        let window = hosted(panes, manager: manager)
        defer { dispose(window); panes.rootPane.terminateAll() }
        #expect(await wait(in: window) {
            window.firstResponder === panes.focusedBackend?.focusableView
                && panes.rootPane.leafIDs.allSatisfy { panes.rootPane.backend(for: $0)?.view.window === window }
        })
        panes.toggleZoom()
        #expect(await wait(in: window) {
            panes.rootPane.leafIDs.filter { panes.rootPane.backend(for: $0)?.view.window === window }.count == 1
        })
        try #require(manager.splitActivePane(axis: .vertical))
        #expect(await wait(in: window) {
            window.firstResponder === panes.focusedBackend?.focusableView
                && panes.rootPane.leafIDs.allSatisfy { panes.rootPane.backend(for: $0)?.view.window === window }
        })
        #expect(!panes.isZoomed)
        panes.toggleZoom()
        #expect(await wait(in: window) {
            panes.rootPane.leafIDs.filter { panes.rootPane.backend(for: $0)?.view.window === window }.count == 1
        })
        manager.closeActivePane()
        #expect(await wait(in: window) {
            window.firstResponder === panes.focusedBackend?.focusableView
                && panes.rootPane.leafIDs.allSatisfy { panes.rootPane.backend(for: $0)?.view.window === window }
        })
        #expect(!panes.isZoomed)
    }

    @Test func alreadyZoomedStateRendersOnInitialAttachment() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        try #require(panes.splitFocusedPane(axis: .horizontal))
        panes.toggleZoom()
        let window = hosted(panes, manager: manager)
        defer { dispose(window); panes.rootPane.terminateAll() }
        #expect(await wait(in: window) {
            window.firstResponder === panes.focusedBackend?.focusableView
                && panes.rootPane.leafIDs.filter {
                    panes.rootPane.backend(for: $0)?.view.window === window
                }.count == 1
        })
        try expectZoomedFocus(panes, in: window)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACUAKE_TEST_GHOSTTY"] == "1"))
    func actualGhosttyBindingActionRoutesToZoomAndBack() async throws {
        let manager = TabManager()
        let panes = try #require(manager.activeTab?.paneManager)
        try #require(panes.splitFocusedPane(axis: .horizontal, ratio: 0.41))
        let selected = try #require(panes.focusedBackend as? GhosttyBackend)
        let surface = try #require(selected.surface)
        let window = hosted(panes, manager: manager)
        defer { dispose(window); panes.rootPane.terminateAll() }
        let before = signature(panes.rootPane)
        #expect(await wait(in: window) { window.firstResponder === selected.focusableView })
        let action = "toggle_split_zoom"
        #expect(action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) })
        #expect(await wait(in: window) {
            panes.isZoomed && panes.rootPane.leafIDs.filter {
                panes.rootPane.backend(for: $0)?.view.window === window
            }.count == 1 && window.firstResponder === selected.focusableView
        })
        try expectZoomedFocus(panes, in: window)
        #expect(action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) })
        #expect(await wait(in: window) {
            !panes.isZoomed && panes.rootPane.leafIDs.allSatisfy {
                panes.rootPane.backend(for: $0)?.view.window === window
            } && window.firstResponder === selected.focusableView
        })
        #expect(signature(panes.rootPane) == before)
    }
}

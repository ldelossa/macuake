import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Macuake

@MainActor
@Suite(.serialized)
struct TabRenameShortcutTests {
    private func wait(in window: NSWindow? = nil, until condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func titlePrompt(_ kind: ghostty_action_prompt_title_e) -> ghostty_action_s {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_PROMPT_TITLE
        action.action.prompt_title = kind
        return action
    }

    final class RenameProbe {
        var saves: [String?] = []
    }

    private struct RenameHost: View {
        @ObservedObject var manager: TabManager
        let panes: PaneManager
        let tabID: String
        let probe: RenameProbe

        var body: some View {
            VStack(spacing: 0) {
                if let index = manager.tabs.firstIndex(where: { $0.id == tabID }) {
                    let tab = manager.tabs[index]
                    TabItemView(
                        tabID: tabID, index: index + 1, title: tabShortTitle(tab.displayTitle),
                        kind: tab.kind, isActive: true, customTitle: tab.customTitle,
                        isEditing: Binding(
                            get: { manager.editingTabID == tabID },
                            set: { editing in
                                if editing { manager.beginRenamingTab(id: tabID) }
                                else { manager.finishRenamingTab(id: tabID) }
                            }
                        ),
                        onSelect: { manager.selectTab(at: index) }, onClose: {},
                        onRename: { name in
                            probe.saves.append(name)
                            manager.renameTab(id: tabID, name: name)
                        }, onHover: { _ in }
                    )
                }
                PaneSplitView(paneManager: panes, tabManager: manager, theme: manager.theme)
            }
        }
    }

    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { editableField(in: $0) }.first
    }

    private func host(customTitle: String? = nil) async throws -> (TabManager, PaneManager, SplitFocusTests.FocusWindow, RenameProbe) {
        let manager = TabManager()
        let tab = try #require(manager.activeTab)
        let panes = try #require(tab.paneManager)
        manager.renameTab(id: tab.id, name: customTitle)
        let probe = RenameProbe()
        let window = SplitFocusTests.FocusWindow()
        window.contentView = NSHostingView(rootView: RenameHost(
            manager: manager, panes: panes, tabID: tab.id, probe: probe
        ))
        try #require(await wait(in: window) { window.firstResponder === panes.focusedBackend?.focusableView })
        return (manager, panes, window, probe)
    }

    private func dispose(_ window: NSWindow, manager: TabManager) {
        window.contentView = nil
        window.close()
        manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() }
    }

    private func startEditor(_ manager: TabManager, panes: PaneManager, in window: NSWindow) async throws -> NSTextField {
        let backend = try #require(panes.focusedBackend as? GhosttyBackend)
        try #require(backend.handleAction(titlePrompt(GHOSTTY_PROMPT_TITLE_TAB)))
        try #require(await wait(in: window) {
            guard let root = window.contentView, let field = editableField(in: root) else { return false }
            return manager.editingTabID == manager.activeTab?.id && field.currentEditor() != nil
        })
        let root = try #require(window.contentView)
        return try #require(editableField(in: root))
    }

    private func replaceDraft(_ text: String, in window: NSWindow) throws {
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func press(_ keyCode: UInt16, characters: String, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
        // Match AppKit's key-equivalent pass before ordinary responder delivery.
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    private func drainActions() async {
        for _ in 0..<3 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test func ghosttyTabTitlePromptStartsActiveTabEditing() async throws {
        let manager = TabManager()
        let tab = try #require(manager.activeTab)
        let backend = try #require(tab.paneManager?.focusedBackend as? GhosttyBackend)
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        #expect(backend.handleAction(titlePrompt(GHOSTTY_PROMPT_TITLE_TAB)))
        #expect(await wait { manager.editingTabID == tab.id })
        #expect(manager.activeTab?.id == tab.id)
    }

    @Test func surfaceTitlePromptRemainsUnsupported() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        let backend = try #require(manager.activeTab?.paneManager?.focusedBackend as? GhosttyBackend)
        #expect(!backend.handleAction(titlePrompt(GHOSTTY_PROMPT_TITLE_SURFACE)))
        await drainActions()
        #expect(manager.editingTabID == nil)
    }

    @Test func inactiveForeignAndClosedSourcesDoNotRenameActiveTab() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        let oldTab = try #require(manager.activeTab)
        let oldBackend = try #require(oldTab.paneManager?.focusedBackend as? GhosttyBackend)
        manager.addTab()
        let activeID = try #require(manager.activeTab?.id)
        #expect(oldBackend.handleAction(titlePrompt(GHOSTTY_PROMPT_TITLE_TAB)))
        await drainActions()
        #expect(manager.editingTabID == nil)
        let foreign = GhosttyBackend()
        #expect(foreign.handleAction(titlePrompt(GHOSTTY_PROMPT_TITLE_TAB)))
        await drainActions()
        #expect(manager.editingTabID == nil)
        manager.closeTab(id: oldTab.id)
        #expect(oldBackend.handleAction(titlePrompt(GHOSTTY_PROMPT_TITLE_TAB)))
        await drainActions()
        #expect(manager.editingTabID == nil)
        #expect(manager.activeTab?.id == activeID)
    }

    @Test func specialTabsAndMissingSourceCannotBeginRename() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        let backend = try #require(manager.activeTab?.paneManager?.focusedBackend)
        manager.openSettings()
        #expect(!manager.beginRenamingTab(id: try #require(manager.activeTab?.id)))
        #expect(!manager.beginRenamingActiveTab(from: backend))
        #expect(!manager.beginRenamingTab(id: "missing"))
        NotificationCenter.default.post(name: .macuakeGhosttyAction, object: nil,
                                        userInfo: ["action": "prompt_tab_title"])
        await drainActions()
        #expect(manager.editingTabID == nil)
    }

    @Test func staleFinishDoesNotCloseAnotherEditor() throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        let firstID = try #require(manager.activeTab?.id)
        manager.addTab()
        let secondID = try #require(manager.activeTab?.id)
        #expect(manager.beginRenamingTab(id: firstID))
        #expect(manager.beginRenamingTab(id: secondID))
        manager.finishRenamingTab(id: firstID)
        #expect(manager.editingTabID == secondID)
    }

    @Test func renameInvalidatesPendingTerminalFocus() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.paneManager?.rootPane.terminateAll() } }
        let tab = try #require(manager.activeTab)
        let backend = try #require(tab.paneManager?.focusedBackend)
        #expect(manager.beginRenamingTab(id: tab.id))
        let window = SplitFocusTests.FocusWindow()
        defer { window.contentView = nil; window.close() }
        window.contentView?.addSubview(backend.view)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        window.contentView?.addSubview(field)
        try #require(window.makeFirstResponder(field))
        let responder = try #require(window.firstResponder)
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.firstResponder === responder)
        #expect(manager.editingTabID == tab.id)
    }

    @Test func fullCustomTitleInitializesAndEnterSavesOnce() async throws {
        let original = "team/service / production full custom name"
        let (manager, panes, window, probe) = try await host(customTitle: original)
        defer { dispose(window, manager: manager) }
        let field = try await startEditor(manager, panes: panes, in: window)
        #expect(await wait(in: window) { field.stringValue == original })
        #expect((panes.focusedBackend as? GhosttyBackend)?.isSurfaceFocused == false)
        try replaceDraft("renamed/service", in: window)
        try press(36, characters: "\r", in: window)
        #expect(await wait(in: window) {
            manager.editingTabID == nil && window.firstResponder === panes.focusedBackend?.focusableView
        })
        #expect(manager.activeTab?.customTitle == "renamed/service")
        #expect(probe.saves == ["renamed/service"])
        #expect((panes.focusedBackend as? GhosttyBackend)?.isSurfaceFocused == true)
    }

    @Test func escapeDiscardsDraftAndReturnsTerminalFocus() async throws {
        let original = "unchanged/full title"
        let (manager, panes, window, probe) = try await host(customTitle: original)
        defer { dispose(window, manager: manager) }
        _ = try await startEditor(manager, panes: panes, in: window)
        try replaceDraft("discard this", in: window)
        try press(53, characters: "\u{1B}", in: window)
        #expect(await wait(in: window) {
            manager.editingTabID == nil && window.firstResponder === panes.focusedBackend?.focusableView
        })
        #expect(manager.activeTab?.customTitle == original)
        #expect(probe.saves.isEmpty)
    }

    @Test func focusLossCommitsOnceAndReopeningUsesCurrentName() async throws {
        let (manager, panes, window, probe) = try await host(customTitle: "before")
        defer { dispose(window, manager: manager) }
        _ = try await startEditor(manager, panes: panes, in: window)
        try replaceDraft("after/full name", in: window)
        #expect(window.makeFirstResponder(panes.focusedBackend?.focusableView))
        #expect(await wait(in: window) { manager.editingTabID == nil })
        #expect(manager.activeTab?.customTitle == "after/full name")
        #expect(probe.saves == ["after/full name"])
        let field = try await startEditor(manager, panes: panes, in: window)
        #expect(await wait(in: window) { field.stringValue == "after/full name" })
        try press(53, characters: "\u{1B}", in: window)
        #expect(await wait(in: window) { manager.editingTabID == nil })
        #expect(probe.saves == ["after/full name"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACUAKE_TEST_GHOSTTY"] == "1"))
    func actualGhosttyPromptActionUsesEditorWithoutChangingZoom() async throws {
        let (manager, panes, window, probe) = try await host(customTitle: "original")
        defer { dispose(window, manager: manager) }
        try #require(panes.splitFocusedPane(axis: .horizontal))
        #expect(await wait(in: window) { window.firstResponder === panes.focusedBackend?.focusableView })
        panes.toggleZoom()
        #expect(await wait(in: window) { window.firstResponder === panes.focusedBackend?.focusableView })
        let focusedID = panes.focusedPaneID
        let backend = try #require(panes.focusedBackend as? GhosttyBackend)
        let surface = try #require(backend.surface)
        let action = "prompt_tab_title"
        #expect(action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) })
        #expect(await wait(in: window) {
            guard let root = window.contentView, let field = editableField(in: root) else { return false }
            return manager.editingTabID == manager.activeTab?.id && field.currentEditor() != nil
        })
        #expect(panes.isZoomed)
        #expect(panes.focusedPaneID == focusedID)
        try replaceDraft("GPU rename", in: window)
        try press(36, characters: "\r", in: window)
        #expect(await wait(in: window) {
            manager.editingTabID == nil && window.firstResponder === backend.focusableView
        })
        #expect(manager.activeTab?.customTitle == "GPU rename")
        #expect(probe.saves == ["GPU rename"])
        #expect(panes.isZoomed)
        #expect(backend.isSurfaceFocused)
    }
}

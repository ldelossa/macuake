import Foundation
import SwiftUI

struct Tab: Identifiable {
    let id: String
    let kind: TabKind
    let paneManager: PaneManager?
    var title: String
    var customTitle: String?

    enum TabKind {
        case terminal
        case settings
        case help
    }

    var displayTitle: String {
        customTitle ?? title
    }

    /// Backward-compatible accessor: returns the focused pane's instance.
    var instance: TerminalInstance? {
        paneManager?.focusedInstance
    }

    /// Terminal tab
    init(directory: String? = nil) {
        self.id = generateShortID()
        self.kind = .terminal
        self.paneManager = PaneManager(directory: directory)
        self.title = "zsh"
    }

    /// Special tab (settings, help)
    init(kind: TabKind, title: String) {
        self.id = generateShortID()
        self.kind = kind
        self.paneManager = nil
        self.title = title
    }
}

@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var activeTabIndex: Int = 0
    @Published var hoveredTabIndex: Int? = nil
    @Published var editingTabID: String? = nil

    /// Stack of directories from recently closed tabs (for ⌘⇧T reopen)
    private var closedTabDirectories: [String] = []

    var activeTab: Tab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var theme: TerminalTheme = .default

    @AppStorage("terminalOpacity") private var savedOpacity: Double = 0.95

    private var splitObserver: Any?
    private var ghosttyActionObserver: Any?

    init() {
        theme.backgroundOpacity = savedOpacity
        restoreTabsOrDefault()
        // Listen for split requests from context menu (right-click in terminal)
        splitObserver = NotificationCenter.default.addObserver(
            forName: .macuakeSplitRequest, object: nil, queue: .main
        ) { [weak self] notif in
            guard let self, let axis = notif.userInfo?["axis"] as? String,
                  let pm = self.activeTab?.paneManager else { return }
            pm.splitFocusedPane(axis: axis == "horizontal" ? .horizontal : .vertical)
        }
        ghosttyActionObserver = NotificationCenter.default.addObserver(
            forName: .macuakeGhosttyAction, object: nil, queue: .main
        ) { [weak self] notif in
            guard let self, let info = notif.userInfo, let name = info["action"] as? String else { return }
            self.handleGhosttyAction(name, arg: info["arg"] as? String ?? "", value: info["value"] as? Int ?? 0)
        }
    }

    func setOpacity(_ value: Double) {
        let clamped = min(max(value, 0.3), 1.0)
        theme.backgroundOpacity = clamped
        savedOpacity = clamped
        objectWillChange.send()
    }

    func addTab(in directory: String? = nil) {
        let tab = Tab(directory: directory)
        let tabID = tab.id
        let index = tabs.count

        // Wire PaneManager callbacks
        tab.paneManager?.onFocusedTitleChange = { [weak self] title in
            guard let self, index < self.tabs.count, self.tabs[index].id == tabID else { return }
            self.tabs[index].title = title
        }

        tab.paneManager?.onLastPaneClosed = { [weak self] in
            guard let self else { return }
            self.closeTab(id: tabID)
        }

        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        focusTerminalInActiveTab()
    }

    /// Handle tab/split actions triggered by Ghostty keybindings.
    func handleGhosttyAction(_ name: String, arg: String, value: Int) {
        switch name {
        case "new_tab": addTab()
        case "close_tab": if let tab = activeTab { closeTab(id: tab.id) }
        case "goto_tab":
            switch arg {
            case "next": selectNextTab()
            case "previous": selectPreviousTab()
            case "last": selectTab(at: tabs.count - 1)
            default: selectTab(at: value)
            }
        case "move_tab":
            guard !tabs.isEmpty else { return }
            let dest = min(max(activeTabIndex + value, 0), tabs.count - 1)
            moveTab(from: activeTabIndex, to: dest)
        case "new_split": splitActivePane(axis: arg == "horizontal" ? .horizontal : .vertical)
        case "goto_split": moveFocusInActiveTab(arg == "next" ? .next : .previous)
        default: break
        }
    }

    func closeTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        // Save directory for ⌘⇧T reopen (terminal tabs only)
        if let pm = tabs[index].paneManager {
            let dir = pm.currentDirectory
            if !dir.isEmpty {
                closedTabDirectories.append(dir)
            }
            // Disconnect callbacks before terminating to prevent re-entrant closeTab
            pm.onLastPaneClosed = nil
            pm.rootPane.terminateAll()
        }

        tabs.remove(at: index)

        if tabs.isEmpty {
            addTab()
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    func reopenClosedTab() {
        guard let dir = closedTabDirectories.popLast() else { return }
        addTab(in: dir)
    }

    var canReopenClosedTab: Bool {
        !closedTabDirectories.isEmpty
    }

    func renameTab(id: String, name: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].customTitle = (name?.isEmpty ?? true) ? nil : name
    }

    // MARK: - Split Panes

    @discardableResult
    func splitActivePane(axis: Axis) -> Bool {
        guard let tab = activeTab, tab.kind == .terminal, let pm = tab.paneManager else { return false }
        return pm.splitFocusedPane(axis: axis)
    }

    func closeActivePane() {
        guard let tab = activeTab, tab.kind == .terminal, let pm = tab.paneManager else { return }
        pm.closePane(id: pm.focusedPaneID)
        // If last pane closed, onLastPaneClosed callback handles closeTab
    }

    func moveFocusInActiveTab(_ direction: PaneManager.NavigationDirection) {
        guard let tab = activeTab, let pm = tab.paneManager else { return }
        pm.moveFocus(direction)
    }

    // MARK: - Special Tabs

    func openSettings() {
        if let idx = tabs.firstIndex(where: { $0.kind == .settings }) {
            if activeTabIndex == idx {
                closeTab(id: tabs[idx].id)
            } else {
                selectTab(at: idx)
            }
            return
        }
        let tab = Tab(kind: .settings, title: "Settings")
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
    }

    func openHelp() {
        if let idx = tabs.firstIndex(where: { $0.kind == .help }) {
            if activeTabIndex == idx {
                closeTab(id: tabs[idx].id)
            } else {
                selectTab(at: idx)
            }
            return
        }
        let tab = Tab(kind: .help, title: "Help")
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
    }

    func closeSpecialTabs() {
        tabs.removeAll { $0.kind != .terminal }
        if tabs.isEmpty {
            addTab()
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    // MARK: - Tab Navigation

    func moveTab(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < tabs.count,
              destination >= 0, destination < tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        // Keep active tab index pointing to the same tab
        if activeTabIndex == source {
            activeTabIndex = destination
        } else if source < activeTabIndex && destination >= activeTabIndex {
            activeTabIndex -= 1
        } else if source > activeTabIndex && destination <= activeTabIndex {
            activeTabIndex += 1
        }
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
        focusTerminalInActiveTab()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        activeTabIndex = (activeTabIndex + 1) % tabs.count
        focusTerminalInActiveTab()
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        activeTabIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
        focusTerminalInActiveTab()
    }

    /// Make the focused pane's terminal view the first responder so it receives keyboard input.
    func focusTerminalInActiveTab() {
        guard let tab = activeTab, let pm = tab.paneManager,
              let backend = pm.focusedBackend else { return }
        let termView = backend.focusableView
        // The view of a freshly created tab may not be attached to the window yet
        // (SwiftUI inserts it lazily), so retry briefly until it is.
        func attempt(_ remaining: Int) {
            if let window = termView.window {
                window.makeFirstResponder(termView)
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt(remaining - 1) }
            }
        }
        DispatchQueue.main.async { attempt(20) }
    }

    // MARK: - Tab State Persistence

    private static let savedTabsKey = "savedTabDirectories"
    private static let savedActiveIndexKey = "savedActiveTabIndex"

    /// Save current tab working directories to UserDefaults.
    func saveTabState() {
        let dirs = tabs.compactMap { tab -> String? in
            guard tab.kind == .terminal else { return nil }
            let dir = tab.paneManager?.currentDirectory ?? ""
            return dir.isEmpty ? "~" : dir
        }
        UserDefaults.standard.set(dirs, forKey: Self.savedTabsKey)
        UserDefaults.standard.set(activeTabIndex, forKey: Self.savedActiveIndexKey)
    }

    /// Restore tabs from saved state or create a default tab.
    private func restoreTabsOrDefault() {
        guard UserDefaults.standard.bool(forKey: "restoreTabsOnLaunch"),
              let dirs = UserDefaults.standard.stringArray(forKey: Self.savedTabsKey),
              !dirs.isEmpty else {
            addTab()
            return
        }

        for dir in dirs {
            let resolved = dir == "~" ? nil : dir
            addTab(in: resolved)
        }

        let savedIndex = UserDefaults.standard.integer(forKey: Self.savedActiveIndexKey)
        if savedIndex >= 0 && savedIndex < tabs.count {
            activeTabIndex = savedIndex
        }
    }
}

import AppKit
import SwiftUI
import KeyboardShortcuts

enum PanelState: Equatable {
    case hidden
    case visible
}

@MainActor
final class WindowController: ObservableObject {
    enum AutoHideReason: Equatable {
        case focusLoss, outsideClick, applicationSwitch
    }

    let panel: TerminalPanel
    let tabManager: TabManager

    @Published var state: PanelState = .hidden
    @Published var isPinned: Bool = false
    @Published var displayID: Int = 0
    @Published var widthPercent: Int = 75
    @Published var heightPercent: Int = 50
    @Published var panelWidth: CGFloat = 0
    @Published var topCornerRadius: Double = 12
    @Published var tabBarColorHex: String = "#000000"
    @Published var tabBarOpacity: Double = 0.85
    @Published var tabColorHex: String = "#262626"
    @Published var tabOpacity: Double = 1.0

    private var previousApp: NSRunningApplication?
    private var resignObserver: Any?
    private var appSwitchObserver: Any?
    private var screenObserver: Any?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var middleClickMonitor: Any?
    private var scrollMonitor: Any?

    // Debounce: ignore resign/appSwitch hide triggers briefly after show()
    private var showTimestamp: Date = .distantPast
    private var transientInteractionIDs: Set<UUID> = []

    var hasTransientInteraction: Bool { !transientInteractionIDs.isEmpty }

    // Scroll wheel state for tab switching
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollTime: Date = .distantPast

    // Persisted
    @AppStorage("terminalWidthPercent") private var savedWidthPercent: Int = 75
    @AppStorage("terminalHeightPercent") private var savedHeightPercent: Int = 50
    @AppStorage("selectedDisplayID") private var savedDisplayID: Int = 0
    @AppStorage("topCornerRadius") private var savedTopCornerRadius: Double = 12
    @AppStorage("tabBarColorHex") private var savedTabBarColorHex: String = "#000000"
    @AppStorage("tabBarOpacity") private var savedTabBarOpacity: Double = 0.85
    @AppStorage("tabColorHex") private var savedTabColorHex: String = "#262626"
    @AppStorage("tabOpacity") private var savedTabOpacity: Double = 1.0

    // MARK: - Sizes

    /// Cached width — set before animation so only height animates (slide down).
    var cachedWidth: CGFloat = 0

    var terminalSize: CGSize {
        let screen = resolvedScreen.frame
        let width = screen.width * CGFloat(widthPercent) / 100.0
        let height = screen.height * CGFloat(heightPercent) / 100.0
        return CGSize(width: max(width, 300), height: max(height, 150))
    }

    // MARK: - Init

    init() {
        let panel = TerminalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        self.panel = panel
        self.tabManager = TabManager()

        self.displayID = savedDisplayID
        self.widthPercent = savedWidthPercent
        self.heightPercent = savedHeightPercent
        self.topCornerRadius = savedTopCornerRadius
        self.tabBarColorHex = savedTabBarColorHex
        self.tabBarOpacity = savedTabBarOpacity
        self.tabColorHex = savedTabColorHex
        self.tabOpacity = savedTabOpacity

        setupContentView()
        setupObservers()
        setupKeyMonitor()
        setupClickMonitor()
        setupMiddleClickMonitor()
        setupScrollMonitor()

        // Panel is always visible at top of screen — SwiftUI content animates inside
        repositionPanel()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        traceAutoHide("controller.ready", includeWindows: true)
    }

    deinit {
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = middleClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupContentView() {
        let rootView = PanelContentView(
            tabManager: tabManager,
            windowController: self
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    // MARK: - Panel positioning (fixed frame, no animation)

    func repositionPanel() {
        let screen = resolvedScreen.frame
        panel.setFrame(NSRect(
            x: screen.origin.x,
            y: screen.origin.y,
            width: screen.width,
            height: screen.height
        ), display: true)
        panelWidth = screen.width
    }

    // MARK: - Observers

    private func setupObservers() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: .panelDidResignKey,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.traceAutoHide("observer.panelDidResignKey", includeWindows: true)
                self.requestAutoHide(.focusLoss)
            }
        }

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self.traceAutoHide("observer.applicationActivated", details: "activatedPID=\(app.processIdentifier) activatedBundle=\(app.bundleIdentifier ?? "unknown")", includeWindows: true)
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.requestAutoHide(.applicationSwitch)
                }
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.repositionPanel()
            }
        }
    }

    // MARK: - Key Monitor (layout-independent, Chrome-style)

    private static let kVK_Tab: UInt16 = 48
    private static let kVK_T: UInt16 = 17
    private static let kVK_W: UInt16 = 13
    private static let kVK_Comma: UInt16 = 43
    private static let kVK_P: UInt16 = 35
    private static let kVK_LeftBracket: UInt16 = 33
    private static let kVK_RightBracket: UInt16 = 30
    private static let kVK_D: UInt16 = 2
    private static let kVK_F: UInt16 = 3
    private static let kVK_G: UInt16 = 5
    private static let kVK_1: UInt16 = 18
    private static let kVK_2: UInt16 = 19
    private static let kVK_3: UInt16 = 20
    private static let kVK_4: UInt16 = 21
    private static let kVK_5: UInt16 = 23
    private static let kVK_6: UInt16 = 22
    private static let kVK_7: UInt16 = 26
    private static let kVK_8: UInt16 = 28
    private static let kVK_9: UInt16 = 25

    private static let digitKeyCodes: [UInt16: Int] = [
        kVK_1: 1, kVK_2: 2, kVK_3: 3, kVK_4: 4, kVK_5: 5,
        kVK_6: 6, kVK_7: 7, kVK_8: 8, kVK_9: 9,
    ]

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let ctrl = event.modifierFlags.contains(.control)
            let key = event.keyCode

            // Ctrl+Tab / Ctrl+Shift+Tab → next/prev tab
            if ctrl && key == Self.kVK_Tab {
                if shift {
                    self.tabManager.selectPreviousTab()
                } else {
                    self.tabManager.selectNextTab()
                }
                return nil
            }

            guard cmd else { return event }

            // Configurable next/prev tab shortcuts (via KeyboardShortcuts recorder)
            if self.eventMatchesShortcut(event, for: .nextTab) {
                self.tabManager.selectNextTab()
                return nil
            }
            if self.eventMatchesShortcut(event, for: .previousTab) {
                self.tabManager.selectPreviousTab()
                return nil
            }

            // ⌘1-8 → select tab N, ⌘9 → last tab (Chrome behavior)
            if !shift, let digit = Self.digitKeyCodes[key] {
                if digit == 9 {
                    self.tabManager.selectTab(at: self.tabManager.tabs.count - 1)
                } else {
                    self.tabManager.selectTab(at: digit - 1)
                }
                return nil
            }

            switch key {
            case Self.kVK_T where shift:
                // ⌘⇧T → reopen last closed tab
                self.tabManager.reopenClosedTab()
                return nil
            case Self.kVK_T where !shift:
                self.tabManager.addTab()
                return nil
            case Self.kVK_W where !shift:
                // ⌘W → close focused pane (if split) or close tab
                if let tab = self.tabManager.activeTab, tab.kind == .terminal,
                   let pm = tab.paneManager, pm.rootPane.leafCount > 1 {
                    self.tabManager.closeActivePane()
                } else if let tab = self.tabManager.activeTab {
                    self.tabManager.closeTab(id: tab.id)
                }
                return nil
            case Self.kVK_D where !shift:
                // ⌘D → split horizontal (side by side)
                self.tabManager.splitActivePane(axis: .horizontal)
                return nil
            case Self.kVK_D where shift:
                // ⌘⇧D → split vertical (top/bottom)
                self.tabManager.splitActivePane(axis: .vertical)
                return nil
            case Self.kVK_P where shift:
                // ⌘⇧P → toggle pin
                self.isPinned.toggle()
                return nil
            case Self.kVK_Comma where !shift:
                self.openSettings()
                return nil
            case Self.kVK_LeftBracket where !shift:
                // ⌘[ → previous pane
                self.tabManager.moveFocusInActiveTab(.previous)
                return nil
            case Self.kVK_RightBracket where !shift:
                // ⌘] → next pane
                self.tabManager.moveFocusInActiveTab(.next)
                return nil
            case Self.kVK_F where !shift:
                // ⌘F → show find bar
                self.tabManager.activeTab?.instance?.backend.showFindBar()
                return nil
            case Self.kVK_G where !shift:
                // ⌘G → find next
                self.tabManager.activeTab?.instance?.backend.findNext()
                return nil
            case Self.kVK_G where shift:
                // ⌘⇧G → find previous
                self.tabManager.activeTab?.instance?.backend.findPrevious()
                return nil
            default:
                break
            }

            return event
        }
    }

    private func eventMatchesShortcut(_ event: NSEvent, for name: KeyboardShortcuts.Name) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        let keyMatch = event.keyCode == UInt16(shortcut.carbonKeyCode)
        let modMatch = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
            .subtracting(.function)
            == shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        return keyMatch && modMatch
    }

    // MARK: - Mouse Monitors

    private func setupClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // AppKit delivers event-monitor handlers on the main thread. Resolve
            // ownership now, before a deferred task could see a dismissed window.
            MainActor.assumeIsolated {
                guard let self else { return }
                let eventDetails = "type=\(event.type.rawValue) eventWindow=\(event.windowNumber) eventTime=\(event.timestamp) eventX=\(event.locationInWindow.x) eventY=\(event.locationInWindow.y)"
                self.traceAutoHide("observer.globalMouseDown", details: eventDetails, includeWindows: true)
                self.handleGlobalMouseDown(windowNumber: event.windowNumber)
            }
        }
    }

    /// A global monitor can also receive clicks delivered to an owned popover.
    /// Determine ownership by the window relationship, not by monitor category.
    func handleGlobalMouseDown(windowNumber: Int) {
        var window = windowNumber > 0 ? NSApp?.window(withWindowNumber: windowNumber) : nil
        while let candidate = window {
            if candidate === panel {
                traceAutoHide("globalClick.ignored", details: "reason=terminalOwnedWindow eventWindow=\(windowNumber)", includeWindows: true)
                return
            }
            window = candidate.parent
        }
        traceAutoHide("globalClick.outside", details: "eventWindow=\(windowNumber)")
        requestAutoHide(.outsideClick)
    }

    /// Middle click on tab → close that tab (Chrome behavior)
    private func setupMiddleClickMonitor() {
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, event.buttonNumber == 2 else { return event }

            if let hoveredIndex = self.tabManager.hoveredTabIndex,
               hoveredIndex < self.tabManager.tabs.count {
                let tab = self.tabManager.tabs[hoveredIndex]
                self.tabManager.closeTab(id: tab.id)
            }
            return nil
        }
    }

    /// Scroll wheel on tab bar area → switch tabs (Chrome behavior)
    private func setupScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.panel.isKeyWindow, self.state == .visible else { return event }

            // Only handle scroll when mouse is in the tab bar area (top ~36pt below menu bar)
            let mouse = NSEvent.mouseLocation
            let screen = self.resolvedScreen
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let termWidth = self.terminalSize.width
            let termX = screen.frame.midX - termWidth / 2
            let tabBarTop = screen.frame.maxY - menuBarHeight
            let tabBarBottom = tabBarTop - 36

            guard mouse.y >= tabBarBottom && mouse.y <= tabBarTop
                    && mouse.x >= termX && mouse.x <= termX + termWidth else {
                return event
            }

            // Debounce: reset accumulator after 500ms gap
            let now = Date()
            if now.timeIntervalSince(self.lastScrollTime) > 0.5 {
                self.scrollAccumulator = 0
            }
            self.lastScrollTime = now

            // Use deltaY (vertical scroll) for tab switching
            self.scrollAccumulator += event.scrollingDeltaY

            let threshold: CGFloat = 15
            if self.scrollAccumulator > threshold {
                self.tabManager.selectPreviousTab()
                self.scrollAccumulator = 0
            } else if self.scrollAccumulator < -threshold {
                self.tabManager.selectNextTab()
                self.scrollAccumulator = 0
            }

            return nil // consume scroll event in tab bar
        }
    }

    // MARK: - Owned transient UI and auto-hide

    private func traceAutoHide(_ event: String, details: String = "", includeWindows: Bool = false) {
        guard AutoHideTrace.isEnabled else { return }
        let ids = transientInteractionIDs.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ",")
        AutoHideTrace.record(event, panel: panel, details: "state=\(state) pinned=\(isPinned) interactions=[\(ids)] \(details)", includeWindows: includeWindows)
    }

    /// Called synchronously before a picker opens, and on every dismissal path.
    func setTransientInteraction(_ id: UUID, isPresented: Bool) {
        traceAutoHide("interaction.requested", details: "id=\(id.uuidString.prefix(8)) presented=\(isPresented)")
        if isPresented {
            guard state == .visible else {
                traceAutoHide("interaction.ignored", details: "reason=parentHidden")
                return
            }
            transientInteractionIDs.insert(id)
            traceAutoHide("interaction.acquired")
        } else {
            guard transientInteractionIDs.remove(id) != nil else {
                traceAutoHide("interaction.ignored", details: "reason=unknownID")
                return
            }
            traceAutoHide("interaction.released")
            // Do not activate Macuake over another app when a popover closes.
            if !hasTransientInteraction, state == .visible, NSApp?.isActive == true {
                traceAutoHide("interaction.restoreParentKey")
                panel.makeKey()
            }
        }
    }

    /// Focus may move into an owned popover without leaving the terminal UI.
    /// Real outside clicks, app switches, and explicit hide are not suppressed.
    func requestAutoHide(_ reason: AutoHideReason, at timestamp: Date = Date()) {
        traceAutoHide("autoHide.requested", details: "reason=\(reason) sinceShow=\(timestamp.timeIntervalSince(showTimestamp))", includeWindows: true)
        guard state == .visible else {
            traceAutoHide("autoHide.ignored", details: "reason=hidden")
            return
        }
        if reason != .outsideClick, timestamp.timeIntervalSince(showTimestamp) <= 0.3 {
            traceAutoHide("autoHide.ignored", details: "reason=showDebounce")
            return
        }
        if isPinned {
            traceAutoHide("autoHide.ignored", details: "reason=pinned")
            if reason == .applicationSwitch { panel.resignKey() }
            return
        }
        if reason == .focusLoss {
            guard !hasTransientInteraction else {
                traceAutoHide("autoHide.ignored", details: "reason=ownedInteraction")
                return
            }
            guard !panel.isKeyWindow else {
                traceAutoHide("autoHide.ignored", details: "reason=parentStillKey")
                return
            }
        }
        hide(source: "auto.\(reason)")
    }

    // MARK: - Toggle (SwiftUI animation driven by state change)

    func toggle() {
        if state == .hidden { show() }
        else if state == .visible { hide() }
    }

    func show() {
        traceAutoHide("show.requested", includeWindows: true)
        guard state == .hidden else { return }
        showTimestamp = Date()
        previousApp = NSWorkspace.shared.frontmostApplication

        repositionPanel()

        // Fix width before animation so only height slides
        cachedWidth = terminalSize.width

        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Defer animation by one run loop tick so the SwiftUI hosting view
        // picks up the new panel frame. Without this, switching monitors
        // shows content sized/centered for the previous screen.
        DispatchQueue.main.async { [self] in
            if UserDefaults.standard.bool(forKey: "disableAnimation") {
                state = .visible
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)) {
                    state = .visible
                }
            }

            traceAutoHide("show.committed", includeWindows: true)
            tabManager.focusTerminalInActiveTab()
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func hide(source: String = "explicit") {
        traceAutoHide("hide.requested", details: "source=\(source)", includeWindows: true)
        guard state == .visible else { return }
        transientInteractionIDs.removeAll()

        if UserDefaults.standard.bool(forKey: "disableAnimation") {
            state = .hidden
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)) {
                state = .hidden
            }
        }
        panel.ignoresMouseEvents = true
        traceAutoHide("hide.committed", details: "source=\(source)", includeWindows: true)

        // After animation settles (or immediately) — activate previous app
        let delay = UserDefaults.standard.bool(forKey: "disableAnimation") ? 0.05 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .hidden else { return }
            if let prev = self.previousApp, !prev.isTerminated {
                self.traceAutoHide("hide.restorePreviousApp", details: "targetPID=\(prev.processIdentifier) targetBundle=\(prev.bundleIdentifier ?? "unknown")")
                prev.activate()
            }
        }
    }

    // MARK: - Resize (percent-based, no animation to avoid jitter)

    func updateHeightByDelta(_ pixelHeight: CGFloat) {
        let screen = resolvedScreen.frame
        let pct = Int((pixelHeight / screen.height) * 100)
        let clamped = min(max(pct, 20), 100)
        heightPercent = clamped
        savedHeightPercent = clamped
    }

    func updateWidthByDelta(_ pixelWidth: CGFloat) {
        let screen = resolvedScreen.frame
        let pct = Int((pixelWidth / screen.width) * 100)
        let clamped = min(max(pct, 30), 100)
        widthPercent = clamped
        savedWidthPercent = clamped
        cachedWidth = terminalSize.width
    }

    func setWidthPercent(_ percent: Int) {
        widthPercent = min(max(percent, 30), 100)
        savedWidthPercent = widthPercent
        cachedWidth = terminalSize.width
    }

    func setHeightPercent(_ percent: Int) {
        heightPercent = min(max(percent, 20), 100)
        savedHeightPercent = heightPercent
    }

    // MARK: - Appearance

    func setTopCornerRadius(_ radius: Double) {
        topCornerRadius = min(max(radius, 0), 20)
        savedTopCornerRadius = topCornerRadius
    }

    func setTabBarColor(_ color: Color) {
        traceAutoHide("appearance.barRGBChanged")
        tabBarColorHex = color.toHex()
        savedTabBarColorHex = tabBarColorHex
    }

    func setTabBarOpacity(_ opacity: Double) {
        traceAutoHide("appearance.barOpacityChanged")
        tabBarOpacity = min(max(opacity, 0), 1)
        savedTabBarOpacity = tabBarOpacity
    }

    func resetTabBarColor() {
        setTabBarColor(.black)
        setTabBarOpacity(0.85)
    }

    func setTabColor(_ color: Color) {
        traceAutoHide("appearance.tabRGBChanged")
        tabColorHex = color.toHex()
        savedTabColorHex = tabColorHex
    }

    func setTabOpacity(_ opacity: Double) {
        traceAutoHide("appearance.tabOpacityChanged")
        tabOpacity = min(max(opacity, 0), 1)
        savedTabOpacity = tabOpacity
    }

    func resetTabColor() {
        setTabColor(Color(hex: "#262626"))
        setTabOpacity(1.0)
    }

    func setDisplayID(_ id: Int) {
        displayID = id
        savedDisplayID = id
    }

    var resolvedScreen: NSScreen {
        if displayID == 0 {
            let mouse = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                if screen.frame.contains(mouse) {
                    return screen
                }
            }
            return NSScreen.main ?? NSScreen.screens[0]
        }
        let targetID = CGDirectDisplayID(displayID)
        for screen in NSScreen.screens {
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenID == targetID {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Settings / Help (as tabs)

    func openSettings() {
        tabManager.openSettings()
        if state == .hidden { show() }
    }

    func openHelp() {
        tabManager.openHelp()
        if state == .hidden { show() }
    }
}

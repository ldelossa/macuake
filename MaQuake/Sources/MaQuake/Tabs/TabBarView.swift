import SwiftUI
import AppKit

struct TabBarView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var windowController: WindowController
    @State private var showTabList = false
    @State private var tabsOverflow = false
    @State private var draggedTabID: String?

    private var palette: TabBarPalette {
        TabBarPalette(
            barColor: Color(hex: windowController.tabBarColorHex),
            tabColor: Color(hex: windowController.tabColorHex),
            opacity: windowController.tabBarOpacity,
            tabOpacity: windowController.tabOpacity
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { outerGeo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        HStack(spacing: 1) {
                            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                                TabItemView(
                                    tabID: tab.id,
                                    index: index + 1,
                                    title: shortTitle(tab.displayTitle),
                                    kind: tab.kind,
                                    isActive: index == tabManager.activeTabIndex,
                                    customTitle: tab.customTitle,
                                    isEditing: Binding(
                                        get: { tabManager.editingTabID == tab.id },
                                        set: { editing in
                                            if editing {
                                                tabManager.beginRenamingTab(id: tab.id)
                                            } else {
                                                tabManager.finishRenamingTab(id: tab.id)
                                            }
                                        }
                                    ),
                                    onSelect: {
                                        tabManager.selectTab(at: index)
                                    },
                                    onClose: { tabManager.closeTab(id: tab.id) },
                                    onRename: { name in
                                        tabManager.renameTab(id: tab.id, name: name)
                                    },
                                    onHover: { hovered in
                                        tabManager.hoveredTabIndex = hovered ? index : nil
                                    }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(palette.foreground, style: StrokeStyle(lineWidth: draggedTabID == tab.id ? 1 : 0, dash: [3, 2]))
                                        .allowsHitTesting(false)
                                )
                                .onDrag {
                                    draggedTabID = tab.id
                                    return NSItemProvider(object: tab.id as NSString)
                                }
                                .onDrop(of: [.text], delegate: TabDropDelegate(
                                    tabManager: tabManager,
                                    targetTabID: tab.id,
                                    draggedTabID: $draggedTabID
                                ))
                            }
                        }
                        .padding(.leading, 4)
                        .background(GeometryReader { innerGeo in
                            Color.clear.onChange(of: tabManager.tabs.count) {
                                tabsOverflow = innerGeo.size.width > outerGeo.size.width
                            }
                            .onAppear {
                                tabsOverflow = innerGeo.size.width > outerGeo.size.width
                            }
                        })

                        // Spacer to fill remaining width
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                    .frame(minWidth: outerGeo.size.width, alignment: .leading)
                }
            }
            .overlay(DoubleClickCatcher { [weak tabManager] in
                guard let tabManager, tabManager.hoveredTabIndex == nil else { return }
                tabManager.addTab()
            })

            // Tab list button — visible when tabs overflow
            if tabsOverflow {
                Button(action: { showTabList.toggle() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(palette.toolbarForeground)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTabList, arrowEdge: .bottom) {
                    TabListPopover(tabManager: tabManager, onDismiss: { showTabList = false })
                        .environment(\.tabBarPalette, palette)
                }
            }

            Spacer()

            // Pin button
            Button(action: { windowController.isPinned.toggle() }) {
                Image(systemName: windowController.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(palette.toolbarForeground)
                    .rotationEffect(.degrees(windowController.isPinned ? 0 : 45))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(windowController.isPinned ? "Unpin (auto-hide on focus loss)" : "Pin (stay visible)")
            .animation(.easeInOut(duration: 0.15), value: windowController.isPinned)
            
            // Settings button
            Button(action: { windowController.openSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.toolbarForeground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            
            Button(action: { tabManager.addTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(palette.toolbarForeground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .padding(.top, 4)
        .frame(height: 36)
        .background(Color(hex: windowController.tabBarColorHex).opacity(windowController.tabBarOpacity))
        .environment(\.tabBarPalette, palette)
        .environment(\.colorScheme, palette.foreground.relativeLuminance > 0.5 ? .dark : .light)
        .contentShape(Rectangle())
    }

    private func shortTitle(_ title: String) -> String {
        tabShortTitle(title)
    }
}

/// Extract last path component for tab display. Testable free function.
func tabShortTitle(_ title: String) -> String {
    let components = title.split(separator: "/")
    return components.last.map(String.init) ?? title
}

private struct TabCloseButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct TabItemView: View {
    @Environment(\.tabBarPalette) private var palette
    let tabID: String
    let index: Int
    let title: String
    let kind: Tab.TabKind
    let isActive: Bool
    let customTitle: String?
    @Binding var isEditing: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String?) -> Void
    let onHover: (Bool) -> Void

    @State private var isHovered = false
    @State private var editText = ""
    @State private var renameFinished = false
    @FocusState private var fieldFocused: Bool

    private var appearance: TabBarPalette.Appearance {
        palette.appearance(isActive: isActive, isHovered: isHovered, isEditing: isEditing)
    }

    private var icon: String? {
        switch kind {
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        case .terminal: return nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // The full padded tab handles clicks, not just this label group.
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundColor(appearance.foreground)
                }

                if isEditing {
                    TextField("Tab name", text: $editText, onCommit: {
                        finishEditing(commit: true)
                    })
                    .textFieldStyle(.plain)
                    .foregroundColor(appearance.foreground)
                    .tint(appearance.foreground)
                    .font(.system(size: 11))
                    .frame(maxWidth: 120)
                    .focused($fieldFocused)
                    .onExitCommand {
                        finishEditing(commit: false)
                    }
                    .onChange(of: fieldFocused) {
                        if !fieldFocused { finishEditing(commit: true) }
                    }
                    .onAppear {
                        editText = customTitle ?? ""
                        renameFinished = false
                        fieldFocused = true
                    }
                } else {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundColor(appearance.foreground)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                }

                if kind == .terminal && index <= 9 {
                    Text("⌘\(index)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(appearance.foreground)
                }
            }

            // Keep the close control independent of selection and rename.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(appearance.foreground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
            .help("Close tab")
            .anchorPreference(key: TabCloseButtonBoundsKey.self, value: .bounds) { $0 }
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .frame(height: 32)
        .contentShape(Rectangle())
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                .fill(appearance.surface)
        )
        .overlayPreferenceValue(TabCloseButtonBoundsKey.self) { closeBounds in
            if !isEditing {
                GeometryReader { geometry in
                    MouseDownOverlay(
                        action: { onSelect() },
                        doubleAction: kind == .terminal ? { isEditing = true } : nil,
                        excludedRect: closeBounds.map { geometry[$0] }
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            if appearance.showsSelectionIndicator {
                Rectangle()
                    .fill(appearance.foreground)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
    }

    private func finishEditing(commit: Bool) {
        guard !renameFinished else { return }
        renameFinished = true
        if commit { onRename(editText.isEmpty ? nil : editText) }
        isEditing = false
    }
}

// MARK: - MouseDown handler for instant tab clicks

/// Transparent NSView overlay that fires actions on mouseDown.
/// Single click calls `action`, double click calls `doubleAction`.
struct MouseDownOverlay: NSViewRepresentable {
    let action: () -> Void
    let doubleAction: (() -> Void)?
    var excludedRect: CGRect? = nil

    func makeNSView(context: Context) -> MouseDownNSView {
        let v = MouseDownNSView()
        v.action = action
        v.doubleAction = doubleAction
        v.excludedRect = excludedRect
        return v
    }

    func updateNSView(_ v: MouseDownNSView, context: Context) {
        v.action = action
        v.doubleAction = doubleAction
        v.excludedRect = excludedRect
    }
}

final class MouseDownNSView: NSView {
    var action: (() -> Void)?
    var doubleAction: (() -> Void)?
    var excludedRect: CGRect?

    // Match SwiftUI's top-left geometry for the close-button exclusion.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if excludedRect?.contains(localPoint) == true { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, let doubleAction {
            doubleAction()
        } else {
            action?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - Double-click catcher (pass-through overlay using event monitor)

/// Detects double-clicks anywhere in its bounds without blocking other events.
/// Uses a local event monitor so buttons and tabs underneath still work.
struct DoubleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> DoubleClickNSView {
        let v = DoubleClickNSView()
        v.onDoubleClick = action
        return v
    }

    func updateNSView(_ v: DoubleClickNSView, context: Context) {
        v.onDoubleClick = action
    }
}

final class DoubleClickNSView: NSView {
    var onDoubleClick: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.clickCount >= 2 else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(loc) else { return event }
                // Only fire on empty space — skip if another interactive view handles this click.
                // Walk up the hit view hierarchy checking for known interactive types
                // or SwiftUI gesture recognizers (installed by .onTapGesture on tab items).
                let winLoc = event.locationInWindow
                if let hitView = self.window?.contentView?.hitTest(winLoc) {
                    var current: NSView? = hitView
                    var depth = 0
                    // Walk up ~20 levels — enough to find SwiftUI gesture recognizers
                    // on tab items without reaching high-level views (e.g. dismiss gesture)
                    while let v = current, depth < 20 {
                        if v is MouseDownNSView || v is NSButton || v is NSTextField {
                            return event
                        }
                        if v.gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer }) {
                            return event
                        }
                        current = v.superview
                        depth += 1
                    }
                }
                self.onDoubleClick?()
                return event
            }
        } else if window == nil, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - Tab list popover

struct TabListPopover: View {
    @Environment(\.tabBarPalette) private var palette
    @ObservedObject var tabManager: TabManager
    let onDismiss: () -> Void
    @State private var hoveredTabID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                let appearance = palette.appearance(
                    isActive: index == tabManager.activeTabIndex,
                    isHovered: hoveredTabID == tab.id
                )
                HStack(spacing: 8) {
                    if tab.kind != .terminal {
                        Image(systemName: tab.kind == .settings ? "gearshape" : "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundColor(appearance.foreground)
                    }

                    Text(tab.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(appearance.foreground)
                        .fontWeight(index == tabManager.activeTabIndex ? .semibold : .regular)

                    Spacer()

                    Button(action: {
                        tabManager.closeTab(id: tab.id)
                        if tabManager.tabs.count <= 1 { onDismiss() }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(appearance.foreground)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(appearance.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(appearance.foreground, lineWidth: appearance.showsSelectionIndicator ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .onHover { hoveredTabID = $0 ? tab.id : nil }
                .onTapGesture {
                    tabManager.selectTab(at: index)
                    onDismiss()
                }
            }
        }
        .padding(6)
        .frame(minWidth: 180)
        // Each translucent row is composited once over the bar reference.
        .background(palette.barReference)
    }
}

// MARK: - Tab drag & drop

struct TabDropDelegate: DropDelegate {
    let tabManager: TabManager
    let targetTabID: String
    @Binding var draggedTabID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedTabID, draggedID != targetTabID else { return }
        guard let from = tabManager.tabs.firstIndex(where: { $0.id == draggedID }),
              let to = tabManager.tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabManager.moveTab(from: from, to: to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
    }
}

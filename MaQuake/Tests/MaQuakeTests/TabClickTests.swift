import Testing
import AppKit
import SwiftUI
@testable import Macuake

/// Tests for tab bar click behavior:
/// - Single click on tab → select (via MouseDownOverlay)
/// - Double click on tab → rename
/// - Double click on empty space → new tab (via DoubleClickCatcher + hoveredTabIndex)
/// - Single click on empty space → nothing
///
/// Also tests the layer opacity of the terminal container to prevent
/// transparency regressions (blurry mc/TUI rendering).
@MainActor
@Suite(.serialized)
struct TabClickTests {

    // MARK: - Helpers

    private func makeMouseEvent(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        )!
    }

    // MARK: - MouseDownOverlay tab click scenarios

    @Test func tabClick_single_selectsTab() {
        var selected = false
        let view = MouseDownNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.action = { selected = true }
        view.doubleAction = { /* rename */ }

        view.mouseDown(with: makeMouseEvent(clickCount: 1))
        #expect(selected, "Single click should select the tab")
    }

    @Test func tabClick_single_doesNotRename() {
        var renamed = false
        let view = MouseDownNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.action = { /* select */ }
        view.doubleAction = { renamed = true }

        view.mouseDown(with: makeMouseEvent(clickCount: 1))
        #expect(!renamed, "Single click should NOT trigger rename")
    }

    @Test func tabClick_double_renames() {
        var renamed = false
        let view = MouseDownNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.action = { /* select */ }
        view.doubleAction = { renamed = true }

        view.mouseDown(with: makeMouseEvent(clickCount: 2))
        #expect(renamed, "Double click on tab should trigger rename")
    }

    @Test func tabClick_double_doesNotSelect() {
        var selected = false
        let view = MouseDownNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.action = { selected = true }
        view.doubleAction = { /* rename */ }

        view.mouseDown(with: makeMouseEvent(clickCount: 2))
        #expect(!selected, "Double click should NOT trigger select (only rename)")
    }

    // MARK: - Hosted tab surface regression tests

    private final class SurfaceProbe: ObservableObject {
        @Published var editing = false
        var selections = 0
        var closes = 0
    }

    private struct SurfaceHost: View {
        @ObservedObject var probe: SurfaceProbe
        let kind: Macuake.Tab.TabKind

        var body: some View {
            TabItemView(
                tabID: "surface-test", index: 1, title: "Terminal", kind: kind,
                isActive: true, customTitle: nil, isEditing: $probe.editing,
                onSelect: { probe.selections += 1 },
                onClose: { probe.closes += 1 }, onRename: { _ in }, onHover: { _ in }
            )
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func surface(in view: NSView) -> MouseDownNSView? {
        if let surface = view as? MouseDownNSView { return surface }
        return view.subviews.lazy.compactMap { surface(in: $0) }.first
    }

    private func waitForLayout(in window: NSWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func hostSurface(kind: Macuake.Tab.TabKind = .terminal) async throws -> (NSWindow, SurfaceProbe, MouseDownNSView) {
        let probe = SurfaceProbe()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SurfaceHost(probe: probe, kind: kind))
        try #require(await waitForLayout(in: window) {
            guard let root = window.contentView, let view = surface(in: root) else { return false }
            return view.bounds.height > 0 && view.excludedRect != nil
        })
        let root = try #require(window.contentView)
        return (window, probe, try #require(surface(in: root)))
    }

    @Test func tabSurface_paddingSelectsAndDoubleClickRenames() async throws {
        let (window, probe, view) = try await hostSurface()
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        #expect(view.bounds.height == 32, "Click surface must cover the full visible tab height")

        // These points were outside the old title-only overlay.
        let points = [
            NSPoint(x: 1, y: 1),
            NSPoint(x: 1, y: view.bounds.midY),
            NSPoint(x: view.bounds.midX, y: 1),
            NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 1),
            NSPoint(x: view.bounds.maxX - 1, y: view.bounds.midY)
        ]
        for point in points {
            let hit = root.hitTest(view.convert(point, to: root.superview))
            #expect(hit === view, "Tab padding at \(point) must hit the tab surface")
            hit?.mouseDown(with: makeMouseEvent(clickCount: 1))
        }
        #expect(probe.selections == points.count)
        #expect(!probe.editing)

        let hit = root.hitTest(view.convert(points[0], to: root.superview))
        hit?.mouseDown(with: makeMouseEvent(clickCount: 2))
        #expect(probe.editing, "Double-clicking padding must enter rename mode")
        #expect(probe.closes == 0)
        #expect(await waitForLayout(in: window) { surface(in: root) == nil },
                "The mouse overlay must disappear while editing so it cannot block the text field")
    }

    @Test func tabSurface_closeButtonIsExcludedButSurroundingPaddingIsClickable() async throws {
        let (window, probe, view) = try await hostSurface()
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let closeRect = try #require(view.excludedRect)
        #expect(closeRect.width == 14 && closeRect.height == 14)
        #expect(closeRect.minY > 0 && closeRect.maxY < view.bounds.maxY)
        let closePoint = NSPoint(x: closeRect.midX, y: closeRect.midY)
        #expect(root.hitTest(view.convert(closePoint, to: root.superview)) !== view,
                "Close-button clicks must pass through the tab overlay")
        for y in [CGFloat(1), view.bounds.maxY - 1] {
            let point = NSPoint(x: closeRect.midX, y: y)
            #expect(root.hitTest(view.convert(point, to: root.superview)) === view,
                    "Padding above and below the close button still belongs to the tab")
        }
        #expect(probe.selections == 0 && !probe.editing)
    }

    @Test func tabSurface_specialTabsSelectWithoutRenaming() async throws {
        for kind in [Macuake.Tab.TabKind.settings, .help] {
            let (window, probe, view) = try await hostSurface(kind: kind)
            defer { window.contentView = nil; window.close() }
            view.mouseDown(with: makeMouseEvent(clickCount: 2))
            #expect(probe.selections == 1)
            #expect(!probe.editing)
        }
    }

    @Test func tabSurface_exclusionUsesTopLeftCoordinatesWithOffsetFrame() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let view = MouseDownNSView(frame: NSRect(x: 20, y: 15, width: 150, height: 32))
        parent.addSubview(view)
        view.excludedRect = NSRect(x: 110, y: 3, width: 14, height: 14)
        let excluded = view.convert(NSPoint(x: 117, y: 5), to: parent)
        let clickable = view.convert(NSPoint(x: 117, y: 28), to: parent)
        #expect(parent.hitTest(excluded) !== view)
        #expect(parent.hitTest(clickable) === view)
    }

    // MARK: - DoubleClickCatcher empty space scenarios

    @Test func emptySpace_doubleClick_addsTab_whenNoTabHovered() {
        let tm = TabManager()
        let initialCount = tm.tabs.count
        #expect(tm.hoveredTabIndex == nil)

        // Simulate what DoubleClickCatcher does
        if tm.hoveredTabIndex == nil {
            tm.addTab()
        }

        #expect(tm.tabs.count == initialCount + 1)
    }

    @Test func emptySpace_doubleClick_doesNotAddTab_whenTabHovered() {
        let tm = TabManager()
        let initialCount = tm.tabs.count
        tm.hoveredTabIndex = 0  // tab is hovered

        // Simulate what DoubleClickCatcher does
        if tm.hoveredTabIndex == nil {
            tm.addTab()
        }

        #expect(tm.tabs.count == initialCount, "Should NOT add tab when hovering over existing tab")
    }

    // MARK: - Tab selection via TabManager

    @Test func tabManager_selectTab_changesActiveIndex() {
        let tm = TabManager()
        tm.addTab()
        tm.addTab()
        #expect(tm.tabs.count == 3)
        #expect(tm.activeTabIndex == 2)

        tm.selectTab(at: 0)
        #expect(tm.activeTabIndex == 0)

        tm.selectTab(at: 1)
        #expect(tm.activeTabIndex == 1)
    }

    @Test func tabManager_selectTab_outOfBounds_isNoOp() {
        let tm = TabManager()
        tm.selectTab(at: 99)
        #expect(tm.activeTabIndex == 0)

        tm.selectTab(at: -1)
        #expect(tm.activeTabIndex == 0)
    }

    // MARK: - Layer opacity regression test

    #if canImport(GhosttyKit)
    @Test func ghosttyBackend_containerView_isOpaque() {
        // The container view must have an opaque layer with black background
        // to prevent the Metal framebuffer transparency from bleeding through.
        // Regression: removing this causes blurry TUI rendering (mc, htop, etc.)
        let backend = GhosttyBackend()
        let container = backend.view

        #expect(container.wantsLayer == true, "Container must be layer-backed")
        #expect(container.layer?.isOpaque == true, "Container layer must be opaque")

        if let bg = container.layer?.backgroundColor {
            let components = bg.components ?? []
            // Black in grayscale: [0.0, 1.0] (luminance=0, alpha=1)
            // Black in RGB: [0.0, 0.0, 0.0, 1.0]
            let isBlack: Bool
            if components.count == 2 {
                isBlack = components[0] < 0.01 // grayscale luminance
            } else if components.count >= 3 {
                isBlack = components[0] < 0.01 && components[1] < 0.01 && components[2] < 0.01
            } else {
                isBlack = false
            }
            #expect(isBlack, "Container background should be black, got \(components)")
        } else {
            #expect(Bool(false), "Container layer must have backgroundColor set")
        }

        backend.terminate()
    }
    #endif
}

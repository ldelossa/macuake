import SwiftUI

/// The root SwiftUI view hosted inside TerminalPanel.
/// Animation is driven explicitly by withAnimation in show()/hide().
struct PanelContentView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var windowController: WindowController

    // Resize preview: shows outline during drag, applies on release
    @State private var dragStartSize: CGSize = .zero
    @State private var resizePreview: CGSize? = nil

    private var isVisible: Bool {
        windowController.state == .visible
    }

    private var currentWidth: CGFloat {
        windowController.cachedWidth > 0
            ? windowController.cachedWidth
            : windowController.terminalSize.width
    }

    private var currentSize: CGSize {
        CGSize(
            width: currentWidth,
            height: isVisible ? windowController.terminalSize.height : 0
        )
    }

    private var menuBarHeight: CGFloat {
        let screen = windowController.resolvedScreen
        let fromFrame = screen.frame.maxY - screen.visibleFrame.maxY
        // safeAreaInsets.top gives the menu bar / safe area height
        let safeTop = screen.safeAreaInsets.top
        return max(fromFrame, safeTop)
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: windowController.topCornerRadius,
            bottomLeadingRadius: 12,
            bottomTrailingRadius: 12,
            topTrailingRadius: windowController.topCornerRadius
        )
    }

    // MARK: - Terminal content (always full size — animation only clips)

    private var terminalContent: some View {
        VStack(spacing: 0) {
            TabBarView(tabManager: tabManager, windowController: windowController)

            ZStack {
                ForEach(tabManager.tabs) { tab in
                    Group {
                        switch tab.kind {
                        case .terminal:
                            if let pm = tab.paneManager {
                                PaneSplitView(
                                    paneManager: pm,
                                    tabManager: tabManager,
                                    theme: tabManager.theme
                                )
                            }
                        case .settings:
                            SettingsView(windowController: windowController)
                        case .help:
                            HelpView()
                        }
                    }
                    .zIndex(tab.id == tabManager.activeTab?.id ? 1 : 0)
                    .offset(x: tab.id == tabManager.activeTab?.id ? 0 : 99999)
                    .allowsHitTesting(tab.id == tabManager.activeTab?.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .frame(width: currentWidth, height: windowController.terminalSize.height)
    }

    // MARK: - Edge drag resize (preview border, apply on release)

    private func edgeDragGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartSize == .zero {
                    dragStartSize = windowController.terminalSize
                }
                resizePreview = ResizePreview.size(
                    start: dragStartSize,
                    edge: edge,
                    translation: value.translation,
                    screen: windowController.resolvedScreen.frame
                )
            }
            .onEnded { _ in
                if let preview = resizePreview {
                    switch edge {
                    case .left, .right:
                        windowController.updateWidthByDelta(preview.width)
                    case .bottom:
                        windowController.updateHeightByDelta(preview.height)
                    }
                }
                resizePreview = nil
                dragStartSize = .zero
            }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dismiss layer
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    AutoHideTrace.record("panel.dismissLayer.click", panel: windowController.panel, includeWindows: true)
                    windowController.hide(source: "dismissLayer")
                }
                .allowsHitTesting(isVisible && !windowController.isPinned)

            VStack(spacing: 0) {
                Color.clear.frame(height: menuBarHeight)

                ZStack(alignment: .top) {
                    // Terminal always at full size, clipped by animated container.
                    // This prevents SIGWINCH on every animation frame.
                    terminalContent
                        .frame(height: currentSize.height, alignment: .top)
                        .clipped()
                        .clipShape(panelShape)
                        .overlay(
                            panelShape
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .opacity(isVisible ? 1 : 0)

                    // Resize preview border (shown during drag)
                    if let preview = resizePreview, isVisible {
                        panelShape
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                            .frame(width: preview.width, height: preview.height)
                    }

                    // Edge resize handles (left/right width, bottom height)
                    if isVisible {
                        ZStack(alignment: .topLeading) {
                            EdgeResizeHandle(edge: .left)
                                .frame(width: 8, height: currentSize.height)
                                .gesture(edgeDragGesture(edge: .left))

                            EdgeResizeHandle(edge: .right)
                                .frame(width: 8, height: currentSize.height)
                                .offset(x: currentSize.width - 8)
                                .gesture(edgeDragGesture(edge: .right))

                            EdgeResizeHandle(edge: .bottom)
                                .frame(width: currentSize.width, height: 8)
                                .offset(y: currentSize.height - 8)
                                .gesture(edgeDragGesture(edge: .bottom))
                        }
                        .frame(width: currentSize.width, height: currentSize.height)
                    }
                }

                Spacer()
            }
            .frame(width: windowController.panelWidth > 0 ? windowController.panelWidth : nil)
        }
    }
}

enum ResizeEdge {
    case left, right, bottom
}

/// Pure size math for edge drag resize, extracted for unit testing.
enum ResizePreview {
    static func size(start: CGSize, edge: ResizeEdge, translation: CGSize, screen: CGRect) -> CGSize {
        var size = start
        switch edge {
        case .left:
            size.width = start.width - translation.width * 2
        case .right:
            size.width = start.width + translation.width * 2
        case .bottom:
            size.height = start.height + translation.height
        }
        return CGSize(
            width: min(max(size.width, 300), screen.width),
            height: min(max(size.height, 150), screen.height * 0.9)
        )
    }
}

struct EdgeResizeHandle: View {
    let edge: ResizeEdge

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    switch edge {
                    case .left, .right:
                        NSCursor.resizeLeftRight.push()
                    case .bottom:
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}

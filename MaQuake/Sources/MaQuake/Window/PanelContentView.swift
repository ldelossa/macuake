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
                    case .bottomLeft, .bottomRight:
                        windowController.updateWidthByDelta(preview.width)
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

                            EdgeResizeHandle(edge: .bottomLeft)
                                .frame(width: 16, height: 16)
                                .offset(y: currentSize.height - 16)
                                .gesture(edgeDragGesture(edge: .bottomLeft))

                            EdgeResizeHandle(edge: .bottomRight)
                                .frame(width: 16, height: 16)
                                .offset(x: currentSize.width - 16, y: currentSize.height - 16)
                                .gesture(edgeDragGesture(edge: .bottomRight))
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

enum ResizeEdge: Equatable {
    case left, right, bottom, bottomLeft, bottomRight
}

/// Pure size math for edge drag resize, extracted for unit testing.
enum ResizePreview {
    static func size(start: CGSize, edge: ResizeEdge, translation: CGSize, screen: CGRect) -> CGSize {
        let minWidth: CGFloat = 300
        let minHeight: CGFloat = 150
        let maxWidth = screen.width
        let maxHeight = screen.height * 0.9

        switch edge {
        case .left:
            return CGSize(
                width: min(max(start.width - translation.width * 2, minWidth), maxWidth),
                height: start.height
            )
        case .right:
            return CGSize(
                width: min(max(start.width + translation.width * 2, minWidth), maxWidth),
                height: start.height
            )
        case .bottom:
            return CGSize(
                width: start.width,
                height: min(max(start.height + translation.height, minHeight), maxHeight)
            )
        case .bottomLeft, .bottomRight:
            // Scale proportionally from the top-center anchor so the top edge
            // stays put, the panel stays centered, and the aspect ratio holds.
            let halfWidth = start.width / 2
            let horizontal: CGFloat = (edge == .bottomRight)
                ? halfWidth + translation.width
                : halfWidth - translation.width
            let vertical = start.height + translation.height
            let d0 = sqrt(halfWidth * halfWidth + start.height * start.height)
            let d1 = sqrt(horizontal * horizontal + vertical * vertical)
            var scale = d0 > 0 ? d1 / d0 : 1
            let scaleMin = max(minWidth / start.width, minHeight / start.height)
            let scaleMax = min(maxWidth / start.width, maxHeight / start.height)
            scale = min(max(scale, scaleMin), scaleMax)
            return CGSize(
                width: start.width * scale,
                height: start.height * scale
            )
        }
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
                    case .bottomLeft, .bottomRight:
                        NSCursor.crosshair.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}

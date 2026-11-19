import AppKit
import Foundation

/// Temporary, opt-in diagnostics for native picker/event routing.
/// Does not record terminal contents, keystrokes, window titles, or color values.
@MainActor
enum AutoHideTrace {
    static let isEnabled = CommandLine.arguments.contains("--trace-auto-hide")

    static func record(
        _ event: String,
        panel: NSWindow? = nil,
        details: String = "",
        includeWindows: Bool = false
    ) {
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        var entry: [String: Any] = [
            "uptime": ProcessInfo.processInfo.systemUptime,
            "event": event,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "appActive": NSApp?.isActive ?? false,
            "mouseX": Double(mouse.x),
            "mouseY": Double(mouse.y),
            "details": details,
        ]
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            entry["frontmostPID"] = Int(frontmost.processIdentifier)
            entry["frontmostBundle"] = frontmost.bundleIdentifier ?? "unknown"
        }
        if let keyWindow = NSApp?.keyWindow { entry["keyWindow"] = windowFields(keyWindow) }
        if let panel { entry["panel"] = windowFields(panel) }
        if includeWindows {
            entry["windows"] = (NSApp?.windows ?? [])
                .filter { $0.isVisible || $0.isKeyWindow }
                .prefix(12)
                .map(windowFields)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        var line = Data("[auto-hide] ".utf8)
        line.append(data)
        line.append(0x0A)
        FileHandle.standardError.write(line)
    }

    private static func windowFields(_ window: NSWindow) -> [String: Any] {
        let frame = window.frame
        return [
            "id": window.windowNumber,
            "class": String(describing: type(of: window)),
            "level": window.level.rawValue,
            "visible": window.isVisible,
            "key": window.isKeyWindow,
            "parent": window.parent?.windowNumber ?? -1,
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.width),
            "height": Double(frame.height),
        ]
    }
}

// Read-only macOS 27 menu bar diagnostics. Run with `swift tools/menu-bar-snapshot.swift`.
// Never traverses app windows, menus, or document content.
// Raw observations only: insideBar is rectangle containment, not proof of visibility.
// MenuBarAgent may report duplicate windows and overlapping overflow placeholders.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.2)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute as String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}
func rect(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute as String),
          let size = attribute(element, kAXSizeAttribute as String),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}
func coordinates(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(1)
}

guard AXIsProcessTrusted() else { fail("Accessibility permission is required for the invoking tool.") }
guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
    fail("MenuBarAgent is not running.")
}
func identifier(_ element: AXUIElement, depth: Int = 0) -> String {
    if let value = attribute(element, kAXIdentifierAttribute as String) as? String, !value.isEmpty { return value }
    var pid: pid_t = 0
    // Only system-owned wrapper views: do not follow AXApplication proxies.
    guard depth < 5, AXUIElementGetPid(element, &pid) == .success,
          pid == agent.processIdentifier else { return "" }
    return children(element).lazy.map { identifier($0, depth: depth + 1) }.first { !$0.isEmpty } ?? ""
}
let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
    ($0.processIdentifier, $0.bundleIdentifier ?? "")
})
var bars: [[String: Any]] = []
for window in children(AXUIElementCreateApplication(agent.processIdentifier), kAXWindowsAttribute as String) {
    guard let barFrame = rect(window) else { continue }
    var items: [[String: Any]] = []
    for group in children(window) {
        guard let frame = rect(group) else { continue }
        for hosted in children(group) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(hosted, &pid) == .success else { continue }
            items.append([
                "pid": pid, "bundle": running[pid] ?? "", "frame": coordinates(frame),
                "identifier": identifier(hosted),
                "insideBar": barFrame.contains(frame)
            ])
        }
    }
    bars.append(["frame": coordinates(barFrame), "items": items.sorted {
        ($0["frame"] as! [CGFloat])[0] < ($1["frame"] as! [CGFloat])[0]
    }])
}
let output: [String: Any] = [
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
    "bars": bars
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))

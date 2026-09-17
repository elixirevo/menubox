import AppKit
import CoreGraphics

/// Identifies the actual app-owned popup, so it can remain interactive at Box.
struct StatusItemMenuPresentation {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect // Quartz coordinates

    static func visibleWindows() -> [StatusItemEventRouter.Window]? {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])?
            .filter { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 }
            .compactMap(StatusItemEventRouter.Window.init(info:))
    }

    /// A custom status popup must have appeared in response to this request.
    /// Existing app windows, the status icon itself and other apps cannot count.
    static func customPopupCandidates(ownerPID: pid_t, visibleBeforeRequest: Set<CGWindowID>,
                                      windows: [StatusItemEventRouter.Window]) -> [StatusItemEventRouter.Window] {
        windows.filter {
            $0.ownerPID == ownerPID && !visibleBeforeRequest.contains($0.id) &&
                $0.layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) - 10 &&
                $0.frame.width >= 60 && $0.frame.width <= 1200 &&
                $0.frame.height > 40 && $0.frame.height <= 1600
        }
    }

    static func matchingCustomPopup(windows: [StatusItemEventRouter.Window],
                                    dialogFrames: [CGRect]) -> StatusItemMenuPresentation? {
        let matches = windows.filter { window in
            dialogFrames.contains { frame in
                abs(frame.minX - window.frame.minX) <= 8 &&
                    abs(frame.minY - window.frame.minY) <= 8 &&
                    abs(frame.width - window.frame.width) <= 16 &&
                    abs(frame.height - window.frame.height) <= 16
            }
        }
        guard matches.count == 1, let window = matches.first else { return nil }
        return .init(windowID: window.id, ownerPID: window.ownerPID, frame: window.frame)
    }

    var isVisible: Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
        }
    }

    static func isBesideBox(menu: CGRect, box: CGRect, anchor: CGPoint) -> Bool {
        // All three arguments use Quartz coordinates. The popup must start in
        // the Box area; the pointer may move within Box while the app responds.
        // A menu hanging from the menu bar is not adopted.
        box.insetBy(dx: -4, dy: -4).contains(anchor) &&
            menu.minY >= box.minY - 4 && menu.minY <= box.maxY + 8 &&
            menu.intersects(box.insetBy(dx: -24, dy: -24))
    }
}

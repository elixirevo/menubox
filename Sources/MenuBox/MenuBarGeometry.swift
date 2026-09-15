import AppKit
import CoreGraphics
import Foundation

enum MenuBarGeometry {
    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let visibleTopGap = screen.frame.maxY - screen.visibleFrame.maxY
        if visibleTopGap >= 18 {
            return visibleTopGap
        }
        return max(22, NSStatusBar.system.thickness)
    }

    static func menuBarRect(for screen: NSScreen) -> NSRect {
        let height = menuBarHeight(for: screen)
        return NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )
    }

    static func rect(for range: HiddenRange, on screen: NSScreen) -> NSRect {
        let menu = menuBarRect(for: screen)
        let left = max(menu.minX, min(range.leftX, range.rightX))
        let right = min(menu.maxX, max(range.leftX, range.rightX))
        let width = max(1, right - left)
        return NSRect(x: left, y: menu.minY, width: width, height: menu.height)
    }

    static func defaultRange(for screen: NSScreen) -> HiddenRange {
        let menu = menuBarRect(for: screen)
        let right = menu.maxX - 86
        let left = max(menu.minX + 40, right - 280)
        return HiddenRange(
            displayId: screen.menuBoxDisplayId,
            leftX: left,
            rightX: right,
            updatedAt: Date()
        )
    }

    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    static func screen(displayId: String) -> NSScreen? {
        NSScreen.screens.first { $0.menuBoxDisplayId == displayId }
    }

    static func clamp(_ rect: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = rect
        if result.maxX > visibleFrame.maxX {
            result.origin.x = visibleFrame.maxX - result.width
        }
        if result.minX < visibleFrame.minX {
            result.origin.x = visibleFrame.minX
        }
        if result.maxY > visibleFrame.maxY {
            result.origin.y = visibleFrame.maxY - result.height
        }
        if result.minY < visibleFrame.minY {
            result.origin.y = visibleFrame.minY
        }
        return result
    }

    static var desktopTop: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
    }

    static func quartzPoint(fromAppKitPoint point: NSPoint) -> CGPoint {
        if let screen = screen(containing: point),
           let displayBounds = cgDisplayBounds(for: screen) {
            return CGPoint(
                x: displayBounds.minX + (point.x - screen.frame.minX),
                y: displayBounds.minY + (screen.frame.maxY - point.y)
            )
        }

        let top = desktopTop == 0 ? point.y : desktopTop
        return CGPoint(x: point.x, y: top - point.y)
    }

    static func appKitPoint(fromQuartzPoint point: CGPoint) -> NSPoint {
        if let screen = screen(containingQuartzPoint: point),
           let displayBounds = cgDisplayBounds(for: screen) {
            return NSPoint(
                x: screen.frame.minX + (point.x - displayBounds.minX),
                y: screen.frame.maxY - (point.y - displayBounds.minY)
            )
        }

        let top = desktopTop == 0 ? point.y : desktopTop
        return NSPoint(x: point.x, y: top - point.y)
    }

    private static func screen(containingQuartzPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let bounds = cgDisplayBounds(for: screen) else { return false }
            return bounds.contains(point)
        } ?? NSScreen.main
    }

    private static func cgDisplayBounds(for screen: NSScreen) -> CGRect? {
        guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
    }
}

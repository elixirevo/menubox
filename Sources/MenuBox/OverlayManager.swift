import AppKit
import CoreGraphics

final class OverlayManager {
    private let store: SettingsStore
    private var windows: [String: NSPanel] = [:]
    private(set) var isHidden = false

    init(store: SettingsStore) {
        self.store = store
    }

    func hideConfiguredRanges() {
        store.refreshDisplays()
        var didHideAnyRange = false

        for screen in NSScreen.screens {
            let policy = store.policy(for: screen)
            guard policy.mode != .disabled else {
                windows[screen.menuBoxDisplayId]?.orderOut(nil)
                continue
            }

            guard let range = store.range(for: screen) else {
                windows[screen.menuBoxDisplayId]?.orderOut(nil)
                continue
            }

            let rect = MenuBarGeometry.rect(for: range, on: screen)
            guard rect.width > 4 else { continue }

            let panel = windows[screen.menuBoxDisplayId] ?? makePanel()
            windows[screen.menuBoxDisplayId] = panel
            panel.setFrame(rect, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: rect.size)
            panel.orderFrontRegardless()
            didHideAnyRange = true
        }

        isHidden = didHideAnyRange
        if !didHideAnyRange {
            orderOutAll()
        }
    }

    func revealConfiguredRanges() {
        isHidden = false
        orderOutAll()
    }

    func orderOutAll() {
        for window in windows.values {
            window.orderOut(nil)
        }
    }

    func refreshIfHidden() {
        if isHidden {
            hideConfiguredRanges()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let cover = MenuBarCoverView(frame: .zero)
        cover.autoresizingMask = [.width, .height]
        panel.contentView = cover
        return panel
    }
}

final class MenuBarCoverView: NSVisualEffectView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 0
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fallback = isDark
            ? NSColor(calibratedWhite: 0.16, alpha: 0.92)
            : NSColor(calibratedWhite: 0.94, alpha: 0.92)
        fallback.setFill()
        bounds.fill()
    }
}

import AppKit
import CoreGraphics

private enum BoxInteractionTiming {
    static let forwardedClickPassthroughDuration: TimeInterval = 8
    static let dismissSuppressionDuration: TimeInterval = 1.4
}

private enum BoxLayout {
    static let gridPadding: CGFloat = 10
    static let gridGap: CGFloat = 8
    static let iconRowExtraHeight: CGFloat = 6
    static let statusReserveHeight: CGFloat = 24
    static let defaultMaxGridColumns = 10
}

private enum GlassBoxStyle {
    static let cornerRadius: CGFloat = 8
    static let material: NSVisualEffectView.Material = .popover
}

final class BoxWindowController {
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var suppressDismissUntil: Date?
    private var forwardedClickRestoreWorkItem: DispatchWorkItem?
    private var proxyMenuHandler: ProxyMenuHandler?
    private var activeProxyMenu: NSMenu?
    private let settingsStore: SettingsStore
    var onForwardedClick: ((MenuBarProxyClick, CGMouseButton) -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    var isShowing: Bool {
        panel?.isVisible == true
    }

    func show(
        anchorFrame: NSRect,
        rangeRect: NSRect,
        screen: NSScreen,
        captureResult: ScreenCapture.CaptureResult,
        proxyTargets: [MenuBarProxyTarget]
    ) {
        close()

        let image = captureResult.image
        let scale = screen.backingScaleFactor
        let imagePointSize = image.map {
            NSSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale)
        } ?? NSSize(width: max(160, rangeRect.width), height: max(24, rangeRect.height))

        let padding: CGFloat = 10
        let maxWidth = min(screen.visibleFrame.width - 24, max(180, rangeRect.width + padding * 2))
        let width = min(maxWidth, max(180, imagePointSize.width + padding * 2))
        let rowHeight: CGFloat = max(28, CGFloat(settingsStore.settings.boxIconSize) + 10)
        let rows = CGFloat(max(1, settingsStore.settings.boxMaxRows))
        let height: CGFloat = min(rowHeight * rows + padding * 2, max(54, imagePointSize.height + padding * 2))

        let proposed = NSRect(
            x: anchorFrame.midX - width / 2,
            y: MenuBarGeometry.menuBarRect(for: screen).minY - height - 6,
            width: width,
            height: height
        )
        let frame = MenuBarGeometry.clamp(proposed, to: screen.visibleFrame.insetBy(dx: 8, dy: 8))

        let panel = FloatingPanel(contentRect: frame)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        panel.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        let content = IconStripView(frame: NSRect(origin: .zero, size: frame.size))
        content.image = image
        content.usesTargetGrid = false
        content.sourcePointSize = rangeRect.size
        content.placeholderText = captureResult.placeholderText
        content.rangeRect = rangeRect
        content.proxyTargets = proxyTargets
        content.iconSize = CGFloat(settingsStore.settings.boxIconSize)
        content.showsStatusText = settingsStore.settings.boxStatusMessagesEnabled
        content.statusText = settingsStore.settings.boxStatusMessagesEnabled
            ? initialStatusText(proxyTargets: proxyTargets)
            : nil
        content.onClick = { [weak self] (click: MenuBarProxyClick, button: CGMouseButton) in
            if button != .left {
                self?.prepareForForwardedClick(click)
            }
            self?.onForwardedClick?(click, button)
        }
        panel.contentView = GlassBoxContentView(frame: NSRect(origin: .zero, size: frame.size), iconStripView: content)
        panel.orderFrontRegardless()
        self.panel = panel

        installDismissMonitors(panel: panel)
    }

    func showProxyTargets(
        anchorFrame: NSRect,
        screen: NSScreen,
        proxyTargets: [MenuBarProxyTarget],
        statusText: String? = nil
    ) {
        close()

        let padding = BoxLayout.gridPadding
        let iconSize = CGFloat(settingsStore.settings.boxIconSize)
        let gap = BoxLayout.gridGap
        let maxWidth = screen.visibleFrame.width - 24
        let maxColumns = max(1, Int((maxWidth - padding * 2 + gap) / (iconSize + gap)))
        let maxGridColumns = max(1, settingsStore.settings.boxMaxColumns)
        let columns = max(1, min(maxColumns, maxGridColumns, max(1, proxyTargets.count)))
        let rows = max(1, Int(ceil(Double(max(1, proxyTargets.count)) / Double(columns))))
        let rowHeight = iconSize + BoxLayout.iconRowExtraHeight
        let statusReserveHeight = settingsStore.settings.boxStatusMessagesEnabled ? BoxLayout.statusReserveHeight : 0
        let minimumGridWidth = padding * 2 + iconSize
        let fittedGridWidth = padding * 2 + CGFloat(columns) * iconSize + CGFloat(max(0, columns - 1)) * gap
        let width = min(maxWidth, max(minimumGridWidth, fittedGridWidth))
        let fittedGridHeight = padding * 2 + CGFloat(rows) * rowHeight + statusReserveHeight
        let minimumHeight = settingsStore.settings.boxStatusMessagesEnabled ? max(54, fittedGridHeight) : fittedGridHeight
        let height = min(
            screen.visibleFrame.height - 24,
            minimumHeight
        )

        let proposed = NSRect(
            x: anchorFrame.midX - width / 2,
            y: MenuBarGeometry.menuBarRect(for: screen).minY - height - 6,
            width: width,
            height: height
        )
        let frame = MenuBarGeometry.clamp(proposed, to: screen.visibleFrame.insetBy(dx: 8, dy: 8))

        let panel = FloatingPanel(contentRect: frame)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        panel.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        let content = IconStripView(frame: NSRect(origin: .zero, size: frame.size))
        content.usesTargetGrid = true
        content.iconSize = iconSize
        content.maxGridColumns = maxGridColumns
        content.rangeRect = .zero
        content.proxyTargets = proxyTargets
        content.showsStatusText = settingsStore.settings.boxStatusMessagesEnabled
        content.statusText = settingsStore.settings.boxStatusMessagesEnabled
            ? statusText ?? initialStatusText(proxyTargets: proxyTargets)
            : nil
        content.onClick = { [weak self] (click: MenuBarProxyClick, button: CGMouseButton) in
            if button != .left {
                self?.prepareForForwardedClick(click)
            }
            self?.onForwardedClick?(click, button)
        }

        panel.contentView = GlassBoxContentView(frame: NSRect(origin: .zero, size: frame.size), iconStripView: content)
        panel.orderFrontRegardless()
        self.panel = panel

        installDismissMonitors(panel: panel)
    }

    func showStatus(_ text: String, duration: TimeInterval = 2.8) {
        guard settingsStore.settings.boxStatusMessagesEnabled else { return }
        guard let content = iconStripView else { return }
        content.statusText = text
        content.needsDisplay = true

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak content] in
            guard let self, let content, self.iconStripView === content else { return }
            content.statusText = self.initialStatusText(proxyTargets: content.proxyTargets)
            content.needsDisplay = true
        }
    }

    func showProxyMenu(
        for target: MenuBarProxyTarget,
        items: [MenuBarProxyMenuItem],
        anchorPoint: NSPoint?,
        selection: @escaping (MenuBarProxyMenuSelection) -> Void
    ) {
        guard let panel, let contentView = panel.contentView else { return }
        let visibleItems = trimmedMenuItems(items)
        guard visibleItems.contains(where: { !$0.isSeparator }) else { return }

        forwardedClickRestoreWorkItem?.cancel()
        forwardedClickRestoreWorkItem = nil
        suppressDismissUntil = .distantFuture
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)

        activeProxyMenu?.cancelTrackingWithoutAnimation()
        activeProxyMenu = nil

        let menu = NSMenu(title: target.displayName)
        let handler = ProxyMenuHandler { [weak self] item in
            self?.suppressDismissUntil = Date().addingTimeInterval(BoxInteractionTiming.dismissSuppressionDuration)
            selection(item)
        } onClose: { [weak self, weak menu] closedMenu in
            guard let self else { return }
            if let menu, closedMenu === menu {
                self.activeProxyMenu = nil
            }
            self.suppressDismissUntil = nil
            self.proxyMenuHandler = nil
        }
        proxyMenuHandler = handler

        menu.autoenablesItems = false
        menu.delegate = handler
        appendMenuItems(visibleItems, to: menu, target: handler)

        let localPoint = proxyMenuPoint(anchorPoint: anchorPoint, in: contentView, panel: panel)
        activeProxyMenu = menu
        menu.popUp(positioning: nil, at: localPoint, in: contentView)
    }

    func close() {
        forwardedClickRestoreWorkItem?.cancel()
        forwardedClickRestoreWorkItem = nil
        activeProxyMenu?.cancelTrackingWithoutAnimation()
        activeProxyMenu = nil
        proxyMenuHandler = nil
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func installDismissMonitors(panel: NSPanel) {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let panel else { return event }
            if self?.shouldSuppressDismiss == true {
                return event
            }
            if event.window !== panel {
                self?.close()
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            if self.shouldSuppressDismiss {
                return
            }
            self.close()
        }
    }

    private func prepareForForwardedClick(_ click: MenuBarProxyClick) {
        if click.revealBeforeForwarding {
            yieldToForwardedClick()
            return
        }

        forwardedClickRestoreWorkItem?.cancel()
        forwardedClickRestoreWorkItem = nil
        suppressDismissUntil = Date().addingTimeInterval(BoxInteractionTiming.dismissSuppressionDuration)
        panel?.ignoresMouseEvents = false
        panel?.alphaValue = 1
        panel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
    }

    private func yieldToForwardedClick() {
        guard let panel else { return }
        forwardedClickRestoreWorkItem?.cancel()
        suppressDismissUntil = Date().addingTimeInterval(BoxInteractionTiming.dismissSuppressionDuration)
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.18
        panel.level = .normal

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.suppressDismissUntil = nil
            self.forwardedClickRestoreWorkItem = nil
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        }
        forwardedClickRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BoxInteractionTiming.forwardedClickPassthroughDuration,
            execute: workItem
        )
    }

    private var shouldSuppressDismiss: Bool {
        guard let suppressDismissUntil else { return false }
        return Date() < suppressDismissUntil
    }

    private var iconStripView: IconStripView? {
        if let content = panel?.contentView as? IconStripView {
            return content
        }
        return (panel?.contentView as? GlassBoxContentView)?.iconStripView
    }

    private func initialStatusText(proxyTargets: [MenuBarProxyTarget]) -> String? {
        if !ClickForwarder.accessibilityTrusted {
            return "Accessibility access required"
        }
        if proxyTargets.isEmpty {
            return "No targets"
        }
        return nil
    }

    private func proxyMenuPoint(anchorPoint: NSPoint?, in view: NSView, panel: NSPanel) -> NSPoint {
        guard let anchorPoint else {
            return NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 4)
        }

        let windowPoint = panel.convertPoint(fromScreen: anchorPoint)
        let viewPoint = view.convert(windowPoint, from: nil)
        return NSPoint(
            x: max(view.bounds.minX + 8, min(view.bounds.maxX - 8, viewPoint.x)),
            y: max(view.bounds.minY + 8, min(view.bounds.maxY - 4, viewPoint.y))
        )
    }

    private func appendMenuItems(
        _ items: [MenuBarProxyMenuItem],
        to menu: NSMenu,
        target: ProxyMenuHandler,
        parentPath: [String] = [],
        parentIdentityPath: [String] = []
    ) {
        for item in trimmedMenuItems(items) {
            if item.isSeparator {
                if menu.items.last?.isSeparatorItem != true {
                    menu.addItem(.separator())
                }
                continue
            }

            let itemPath = parentPath + [item.title]
            let itemIdentityPath = parentIdentityPath + [item.identity]
            let menuItem = NSMenuItem(title: item.title, action: #selector(ProxyMenuHandler.select(_:)), keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = MenuBarProxyMenuSelection(
                item: item,
                path: itemPath,
                identityPath: itemIdentityPath
            )
            menuItem.isEnabled = item.isEnabled && (item.accessibilityElement != nil || item.appKitFrame != nil)
            menuItem.state = item.isChecked ? .on : .off

            let childItems = trimmedMenuItems(item.children)
            if childItems.contains(where: { !$0.isSeparator }) {
                let submenu = NSMenu(title: item.title)
                submenu.autoenablesItems = false
                appendMenuItems(
                    childItems,
                    to: submenu,
                    target: target,
                    parentPath: itemPath,
                    parentIdentityPath: itemIdentityPath
                )
                menuItem.submenu = submenu
                menuItem.isEnabled = true
            }

            menu.addItem(menuItem)
        }
    }

    private func trimmedMenuItems(_ items: [MenuBarProxyMenuItem]) -> [MenuBarProxyMenuItem] {
        var result = items
        while result.first?.isSeparator == true {
            result.removeFirst()
        }
        while result.last?.isSeparator == true {
            result.removeLast()
        }
        return result
    }
}

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class GlassBoxContentView: NSVisualEffectView {
    let iconStripView: IconStripView

    init(frame frameRect: NSRect, iconStripView: IconStripView) {
        self.iconStripView = iconStripView
        super.init(frame: frameRect)

        material = GlassBoxStyle.material
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
        wantsLayer = true
        updateChrome()

        iconStripView.frame = bounds
        iconStripView.autoresizingMask = [.width, .height]
        addSubview(iconStripView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    private func updateChrome() {
        wantsLayer = true
        layer?.cornerRadius = GlassBoxStyle.cornerRadius
        if #available(macOS 10.15, *) {
            layer?.cornerCurve = .continuous
        }
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }
}

final class ProxyMenuHandler: NSObject, NSMenuDelegate {
    private let selection: (MenuBarProxyMenuSelection) -> Void
    private let onClose: (NSMenu) -> Void

    init(selection: @escaping (MenuBarProxyMenuSelection) -> Void, onClose: @escaping (NSMenu) -> Void) {
        self.selection = selection
        self.onClose = onClose
    }

    @objc func select(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MenuBarProxyMenuSelection else { return }
        self.selection(selection)
    }

    func menuDidClose(_ menu: NSMenu) {
        onClose(menu)
    }
}

final class IconStripView: NSView {
    var image: CGImage?
    var usesTargetGrid = false
    var iconSize: CGFloat = 22
    var maxGridColumns: Int = BoxLayout.defaultMaxGridColumns
    var sourcePointSize: NSSize = .zero
    var placeholderText = "Unable to capture the menu bar image."
    var rangeRect: NSRect = .zero
    var proxyTargets: [MenuBarProxyTarget] = []
    var onClick: ((MenuBarProxyClick, CGMouseButton) -> Void)?
    var showsStatusText = true
    var statusText: String?
    private var hoveredTarget: MenuBarProxyTarget?
    private var trackingArea: NSTrackingArea?
    private var armedClick: (point: NSPoint, button: CGMouseButton)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        if usesTargetGrid {
            drawTargetGrid()
            drawStatusText()
            return
        }

        guard let image else {
            drawPlaceholder()
            return
        }

        let drawRect = currentImageDrawRect()

        NSImage(cgImage: image, size: drawRect.size).draw(in: drawRect)
        drawHoverHighlight()
        drawStatusText()
    }

    override func mouseDown(with event: NSEvent) {
        armForward(event: event, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        forwardIfArmed(event: event, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        armForward(event: event, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardIfArmed(event: event, button: .right)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTarget != nil {
            hoveredTarget = nil
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(usesTargetGrid ? bounds : currentImageDrawRect(), cursor: .pointingHand)
    }

    private func armForward(event: NSEvent, button: CGMouseButton) {
        if usesTargetGrid {
            let point = convert(event.locationInWindow, from: nil)
            armedClick = target(at: point) == nil ? nil : (point, button)
            return
        }

        guard image != nil, rangeRect.width > 0, rangeRect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = currentImageDrawRect()
        if imageRect.contains(point) {
            armedClick = (point, button)
        } else {
            armedClick = nil
        }
    }

    private func forwardIfArmed(event: NSEvent, button: CGMouseButton) {
        guard let armedClick, armedClick.button == button else { return }
        self.armedClick = nil

        if usesTargetGrid {
            let point = convert(event.locationInWindow, from: nil)
            guard let click = proxyClick(at: point),
                  let selectedTarget = target(at: point),
                  let armedTarget = target(at: armedClick.point),
                  selectedTarget === armedTarget else {
                return
            }
            onClick?(click, button)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let click = proxyClick(at: point),
              currentImageDrawRect().contains(armedClick.point) else {
            return
        }
        onClick?(click, button)
    }

    private func updateHover(with event: NSEvent) {
        if usesTargetGrid {
            let point = convert(event.locationInWindow, from: nil)
            let target = target(at: point)
            if target !== hoveredTarget {
                hoveredTarget = target
                needsDisplay = true
            }
            return
        }

        guard image != nil, rangeRect.width > 0, rangeRect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = currentImageDrawRect()
        guard imageRect.contains(point) else {
            if hoveredTarget != nil {
                hoveredTarget = nil
                needsDisplay = true
            }
            return
        }

        let xRatio = max(0, min(1, (point.x - imageRect.minX) / max(1, imageRect.width)))
        let screenPoint = NSPoint(
            x: rangeRect.minX + xRatio * rangeRect.width,
            y: rangeRect.midY
        )
        let target = proxyTarget(near: screenPoint)
        if target !== hoveredTarget {
            hoveredTarget = target
            needsDisplay = true
        }
    }

    private func proxyTarget(near point: NSPoint) -> MenuBarProxyTarget? {
        guard !proxyTargets.isEmpty else { return nil }

        let expandedHits = proxyTargets.filter { $0.appKitFrame.insetBy(dx: -4, dy: -8).contains(point) }
        if let hit = expandedHits.min(by: { distance($0.appKitClickPoint, point) < distance($1.appKitClickPoint, point) }) {
            return hit
        }

        let tolerance = max(12, rangeRect.height * 0.75)
        return proxyTargets
            .filter { abs($0.appKitClickPoint.x - point.x) <= tolerance }
            .min { distance($0.appKitClickPoint, point) < distance($1.appKitClickPoint, point) }
    }

    private func distance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func currentImageDrawRect() -> NSRect {
        guard let image else {
            return .zero
        }

        let sourceSize = sourcePointSize.width > 0 && sourcePointSize.height > 0
            ? sourcePointSize
            : NSSize(width: image.width, height: image.height)
        let scale = min((bounds.width - 20) / max(1, sourceSize.width), (bounds.height - 20) / max(1, sourceSize.height))
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private func drawHoverHighlight() {
        guard let hoveredTarget else { return }
        if usesTargetGrid {
            guard let rect = cellRect(for: hoveredTarget) else { return }
            drawHighlight(in: iconRect(in: rect).insetBy(dx: -3, dy: -3))
            return
        }

        let rect = viewRect(for: hoveredTarget.appKitFrame).insetBy(dx: -2, dy: -3)
        guard !rect.isEmpty else { return }

        drawHighlight(in: rect)
    }

    private func drawHighlight(in rect: NSRect) {
        guard !rect.isEmpty else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor.selectedContentBackgroundColor.withAlphaComponent(isDark ? 0.26 : 0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        NSColor.separatorColor.withAlphaComponent(isDark ? 0.24 : 0.18).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawTargetGrid() {
        for (target, rect) in targetCells() {
            let iconRect = iconRect(in: rect)

            if let icon = target.icon {
                icon.draw(in: iconRect)
            } else {
                drawFallbackIcon(for: target, in: iconRect)
            }
        }

        drawHoverHighlight()
    }

    private func drawFallbackIcon(for target: MenuBarProxyTarget, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()

        let name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = name.isEmpty ? "?" : String(name.prefix(1)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.controlAccentColor,
            .font: NSFont.systemFont(ofSize: max(11, iconSize * 0.42), weight: .semibold)
        ]
        let size = initial.size(withAttributes: attrs)
        initial.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private func target(at point: NSPoint) -> MenuBarProxyTarget? {
        targetCells().first { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }?.target
    }

    func proxyClick(at point: NSPoint) -> MenuBarProxyClick? {
        if usesTargetGrid {
            guard let selectedTarget = target(at: point) else {
                return nil
            }
            return MenuBarProxyClick(
                appKitPoint: selectedTarget.appKitClickPoint,
                searchRect: selectedTarget.appKitFrame.insetBy(dx: -80, dy: -12),
                target: selectedTarget,
                revealBeforeForwarding: false,
                menuAnchorPoint: menuAnchorPoint(for: selectedTarget, fallbackPoint: point)
            )
        }

        guard image != nil, rangeRect.width > 0, rangeRect.height > 0 else {
            return nil
        }
        let imageRect = currentImageDrawRect()
        guard imageRect.contains(point) else {
            return nil
        }

        let xRatio = max(0, min(1, (point.x - imageRect.minX) / max(1, imageRect.width)))
        let screenPoint = NSPoint(
            x: rangeRect.minX + xRatio * rangeRect.width,
            y: rangeRect.midY
        )
        let target = proxyTarget(near: screenPoint)
        return MenuBarProxyClick(
            appKitPoint: target?.appKitClickPoint ?? screenPoint,
            searchRect: rangeRect,
            target: target
        )
    }

    private func menuAnchorPoint(for target: MenuBarProxyTarget, fallbackPoint: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        let rect = cellRect(for: target) ?? NSRect(x: fallbackPoint.x, y: fallbackPoint.y, width: 1, height: 1)
        let localPoint = NSPoint(x: rect.midX, y: rect.maxY + 2)
        let windowPoint = convert(localPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func cellRect(for target: MenuBarProxyTarget) -> NSRect? {
        targetCells().first { $0.target === target }?.rect
    }

    private func targetCells() -> [(target: MenuBarProxyTarget, rect: NSRect)] {
        guard !proxyTargets.isEmpty else { return [] }

        let padding = BoxLayout.gridPadding
        let gap = BoxLayout.gridGap
        let rowHeight = iconSize + BoxLayout.iconRowExtraHeight
        let availableColumns = max(1, Int((bounds.width - padding * 2 + gap) / (iconSize + gap)))
        let columns = min(availableColumns, max(1, maxGridColumns))

        return proxyTargets.enumerated().map { index, target in
            let row = index / columns
            let column = index % columns
            let x = padding + CGFloat(column) * (iconSize + gap)
            let y = padding + CGFloat(row) * rowHeight
            return (
                target,
                NSRect(x: x, y: y, width: iconSize, height: rowHeight)
            )
        }
    }

    private func iconRect(in cellRect: NSRect) -> NSRect {
        NSRect(
            x: cellRect.midX - iconSize / 2,
            y: cellRect.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
    }

    private func viewRect(for appKitFrame: NSRect) -> NSRect {
        let imageRect = currentImageDrawRect()
        guard rangeRect.width > 0, imageRect.width > 0 else { return .zero }

        let minRatio = max(0, min(1, (appKitFrame.minX - rangeRect.minX) / rangeRect.width))
        let maxRatio = max(0, min(1, (appKitFrame.maxX - rangeRect.minX) / rangeRect.width))
        let x = imageRect.minX + minRatio * imageRect.width
        let width = max(6, (maxRatio - minRatio) * imageRect.width)
        return NSRect(x: x, y: imageRect.minY, width: width, height: imageRect.height)
    }

    private func drawStatusText() {
        guard showsStatusText else { return }
        guard let statusText, !statusText.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        let size = statusText.size(withAttributes: attrs)
        let rect = NSRect(
            x: bounds.maxX - size.width - 18,
            y: bounds.maxY - size.height - 12,
            width: size.width + 10,
            height: size.height + 6
        )

        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.36).setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 1
        path.stroke()

        statusText.draw(
            at: NSPoint(x: rect.minX + 5, y: rect.minY + 3),
            withAttributes: attrs
        )
    }

    private func drawPlaceholder() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .paragraphStyle: paragraph
        ]
        placeholderText.draw(in: bounds.insetBy(dx: 12, dy: bounds.height / 2 - 8), withAttributes: attrs)
    }

}

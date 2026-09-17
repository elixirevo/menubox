import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics

private enum StatusItemLength {
    static let shown = NSStatusItem.squareLength
    static let hidden: CGFloat = 10_000
}

private enum HiddenBoxLayout {
    static let maxCaptureWidth: CGFloat = 520
    static let captureDelayNanoseconds: UInt64 = 120_000_000
    static let clickForwardInitialDelayNanoseconds: UInt64 = 280_000_000
    static let clickForwardRetryDelayNanoseconds: UInt64 = 100_000_000
    static let clickForwardMaxAttempts = 12
}

private enum ProxyTargetCacheTiming {
    static let launchWarmupDelays: [TimeInterval] = [0.35, 1, 2, 4, 8, 15]
    static let appChangeRefreshDelays: [TimeInterval] = [0.75, 2, 5, 10, 20]
    static let environmentRefreshDelays: [TimeInterval] = [1, 3]
    static let periodicRefreshInterval: TimeInterval = 5
}

private enum ApplicationActivationTiming {
    static let windowCheckDelays: [TimeInterval] = [0.08, 0.22, 0.4]
}

private enum MenuBoxHotKey {
    static let signature: OSType = 0x4D4E4258 // MNBX
    static let menuBarIconID: UInt32 = 1
    static let boxUIID: UInt32 = 2
}

private struct ApplicationWindowActivationResult {
    let hasWindows: Bool
    let didRaiseWindow: Bool
}

private func menuBoxHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let eventRef, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == MenuBoxHotKey.signature else {
        return status
    }

    let controller = Unmanaged<MenuBoxController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.handleKeyboardShortcut(id: hotKeyID.id)
    }
    return noErr
}

final class MenuBoxController: NSObject {
    private let checkForUpdates: (() -> Void)?
    private let store = SettingsStore()
    private let permissions = PermissionStore()
    private var hideWhenPermissionsReady = false
    private lazy var overlayManager = OverlayManager(store: store)

    private lazy var boxWindowController = BoxWindowController(settingsStore: store)
    private var settingsWindowController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private var tapeItem: NSStatusItem?
    private var savedMarkerFrame: NSRect?
    private var markerFrame: NSRect? {
        tapeItem?.isVisible == true ? tapeItem?.button?.window?.frame : savedMarkerFrame
    }
    private var autoHideTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var hiddenMenuTask: Task<Void, Never>?
    private var isHidden = false
    private var usesNativeHiding: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
    }
    private lazy var nativeHiding: NativeMenuBarHiding = {
        let hiding = NativeMenuBarHiding()
        hiding.setMarkerHidden = { [weak self] hidden in
            guard let self else { return }
            guard self.tapeItem?.isVisible != !hidden else { return }
            if hidden { self.savedMarkerFrame = self.tapeItem?.button?.window?.frame }
            self.tapeItem?.isVisible = !hidden
        }
        hiding.onChange = { [weak self] hidden, error in
            guard let self else { return }
            self.isHidden = hidden
            self.statusItem?.button?.toolTip = error ?? "MenuBox"
            if let error { self.showHidingError(error) }
            if error == nil {
                self.renderCachedProxyTargetsIfBoxVisible()
                // The verified plan may now include an app whose icon appeared
                // after launch. Its AX inventory can be read while still hidden.
                self.refreshProxyTargetCache(updateVisibleBox: self.boxWindowController.isShowing)
            }
        }
        return hiding
    }()
    private var settingsCancellable: AnyCancellable?
    private var hotKeyEventHandler: EventHandlerRef?
    private var menuBarIconHotKey: EventHotKeyRef?
    private var boxUIHotKey: EventHotKeyRef?
    private var isRecordingShortcut = false
    private var proxyTargetScanTask: Task<Void, Never>?
    private var proxyTargetWarmupWorkItem: DispatchWorkItem?
    private var proxyTargetRefreshWorkItems: [DispatchWorkItem] = []
    private var proxyTargetPeriodicRefreshTimer: Timer?
    private var proxyTargetWarmupAttempt = 0
    private var targetInventory = MenuBarTargetInventory()
    private var cachedProxyTargets: [MenuBarProxyTarget] { targetInventory.targets }
    private var cachedProxyTargetsLoadedAt: Date?
    private var isStopping = false

    init(checkForUpdates: (() -> Void)? = nil) {
        self.checkForUpdates = checkForUpdates
        super.init()
    }

    deinit {
        hiddenMenuTask?.cancel()
        proxyTargetScanTask?.cancel()
        proxyTargetWarmupWorkItem?.cancel()
        proxyTargetRefreshWorkItems.forEach { $0.cancel() }
        proxyTargetPeriodicRefreshTimer?.invalidate()
        uninstallKeyboardShortcuts()
    }

    func start() {
        NSLog("[MenuBox] Accessibility trusted=%d", ClickForwarder.accessibilityTrusted)
        boxWindowController.onForwardedClick = { [weak self] click, button in
            self?.handleBoxIconClick(click: click, button: button)
        }
        boxWindowController.onClose = { [weak self] in
            self?.hiddenMenuTask?.cancel()
        }
        boxWindowController.onMenuInteractionEnded = { [weak self] in
            DispatchQueue.main.async { self?.renderCachedProxyTargetsIfBoxVisible() }
        }

        configureMainStatusItem()
        configureTapeStatusItem()
        installKeyboardShortcuts()

        settingsCancellable = store.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshKeyboardShortcuts()
            }

        if MenuBarHidingCompatibility.supportsSpacer {
            DispatchQueue.main.async { [weak self] in self?.hideHiddenIcons() }
        } else if usesNativeHiding {
            hideWhenPermissionsReady = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.hideWhenPermissionsReady else { return }
                self.permissions.refresh()
                if self.permissions.snapshot.isReady { self.hideHiddenIcons() }
            }
        }

        startProxyTargetCacheWarmup()
        startProxyTargetPeriodicRefresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(runningApplicationsChanged),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(runningApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceWillSleep(_:)),
                                                              name: notification, object: nil)
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                             NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidWake(_:)),
                                                              name: notification, object: nil)
        }
        permissions.onNeedsSetup = { [weak self] in
            guard let self else { return }
            if !self.permissions.snapshot.isReady, self.usesNativeHiding, self.nativeHiding.wantsHidden {
                self.hideWhenPermissionsReady = true
            }
            self.hiddenMenuTask?.cancel()
            self.autoHideTimer?.invalidate()
            self.autoHideTimer = nil
            self.boxWindowController.close()
            self.openSettings(tab: .permissions)
        }
        permissions.onAccessRestored = { [weak self] in
            guard let self else { return }
            self.startProxyTargetCacheWarmup()
            if self.hideWhenPermissionsReady { self.hideHiddenIcons() }
        }
        permissions.start()
    }

    private func configureMainStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: StatusItemLength.shown)
        item.autosaveName = "com.elixirevo.MenuBox.main"
        item.isVisible = true
        item.length = StatusItemLength.shown
        if let button = item.button {
            button.setAccessibilityIdentifier("MenuBox.main")
            button.image = StatusIconFactory.boxIcon()
            button.title = ""
            button.toolTip = "MenuBox"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func configureTapeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: StatusItemLength.shown)
        item.autosaveName = "com.elixirevo.MenuBox.tape"
        item.isVisible = true
        item.length = StatusItemLength.shown
        if let button = item.button {
            button.setAccessibilityIdentifier("MenuBox.marker")
            button.image = StatusIconFactory.tapeIcon()
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "MenuBox marker: Command-drag to move, right-click to open menu"
            button.target = self
            button.action = #selector(tapeItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        tapeItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            performBoxIconAction(store.settings.boxIconLeftClickAction)
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            performBoxIconAction(store.settings.boxIconRightClickAction)
        } else if event.modifierFlags.contains(.option) {
            performBoxIconAction(.showBoxUI)
        } else {
            performBoxIconAction(store.settings.boxIconLeftClickAction)
        }
    }

    @objc private func tapeItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(from: sender)
        }
    }

    private func toggleHiddenIcons() {
        if isHidden || (usesNativeHiding && nativeHiding.wantsHidden) {
            showHiddenIcons()
        } else {
            hideHiddenIcons()
        }
    }

    private func performBoxIconAction(_ action: BoxIconAction) {
        switch action {
        case .toggleHiddenIcons:
            toggleHiddenIcons()
        case .showBoxUI:
            showHiddenIconsBox()
        case .showHiddenIcons:
            showHiddenIcons()
        case .hideHiddenIcons:
            hideHiddenIcons()
        case .openSettings:
            openSettings()
        case .none:
            break
        }
    }

    fileprivate func handleKeyboardShortcut(id: UInt32) {
        guard store.settings.shortcutsEnabled else { return }

        switch id {
        case MenuBoxHotKey.menuBarIconID:
            toggleHiddenIcons()
        case MenuBoxHotKey.boxUIID:
            toggleHiddenIconsBox()
        default:
            break
        }
    }

    private func toggleHiddenIconsBox() {
        if boxWindowController.isShowing {
            boxWindowController.close()
        } else {
            showHiddenIconsBox()
        }
    }

    private func showHiddenIcons() {
        revealHiddenIcons()
        scheduleAutoHideIfNeeded()
    }

    private func revealHiddenIcons() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()
        captureTask = nil
        boxWindowController.close()

        revealMenuBarIcons()
    }

    private func revealMenuBarIcons() {
        hideWhenPermissionsReady = false
        if usesNativeHiding, !nativeHiding.show() { return }
        tapeItem?.length = StatusItemLength.shown
        isHidden = false
    }

    private func hideHiddenIcons() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()
        captureTask = nil
        boxWindowController.close()

        if usesNativeHiding {
            permissions.refresh()
            guard permissions.snapshot.isReady else {
                hideWhenPermissionsReady = true
                openSettings(tab: .permissions)
                return
            }
            hideWhenPermissionsReady = false
            nativeHiding.hide()
            return
        }
        guard MenuBarHidingCompatibility.supportsSpacer else {
            revealMenuBarIcons()
            statusItem?.button?.toolTip = MenuBarHidingCompatibility.unavailableMessage
            if let frame = statusItem?.button?.window?.frame,
               let screen = MenuBarGeometry.screen(containing: NSPoint(x: frame.midX, y: frame.midY)) {
                boxWindowController.showProxyTargets(
                    anchorFrame: frame, screen: screen, proxyTargets: [],
                    statusText: MenuBarHidingCompatibility.unavailableMessage
                )
            }
            return
        }
        tapeItem?.length = StatusItemLength.hidden
        isHidden = true
    }

    func stop() {
        isStopping = true
        proxyTargetScanTask?.cancel()
        proxyTargetPeriodicRefreshTimer?.invalidate()
        proxyTargetWarmupWorkItem?.cancel()
        proxyTargetRefreshWorkItems.forEach { $0.cancel() }
        permissions.stop()
        if usesNativeHiding { nativeHiding.stop() }
        autoHideTimer?.invalidate()
        tapeItem?.length = StatusItemLength.shown
    }

    private func scheduleAutoHideIfNeeded(minimumDelay: TimeInterval = 0) {
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        guard (MenuBarHidingCompatibility.supportsSpacer || usesNativeHiding), store.settings.autoHideEnabled else { return }

        let delay = max(store.settings.autoHideDelaySeconds, minimumDelay)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.hideHiddenIcons()
        }
        autoHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installKeyboardShortcuts() {
        guard hotKeyEventHandler == nil else {
            refreshKeyboardShortcuts()
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            menuBoxHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyEventHandler
        )
        if status != noErr {
            NSLog("[MenuBox] Failed to install hotkey handler: %d", status)
        }
        refreshKeyboardShortcuts()
    }

    private func refreshKeyboardShortcuts() {
        unregisterKeyboardShortcuts()
        guard hotKeyEventHandler != nil,
              !isRecordingShortcut,
              store.settings.shortcutsEnabled else {
            return
        }

        let menuBarShortcut = store.settings.menuBarIconShortcut
        let boxUIShortcut = store.settings.boxUIShortcut

        menuBarIconHotKey = registerKeyboardShortcut(
            menuBarShortcut,
            id: MenuBoxHotKey.menuBarIconID
        )

        if boxUIShortcut == menuBarShortcut {
            NSLog("[MenuBox] Box UI shortcut matches menu bar shortcut; skipping duplicate registration")
        } else {
            boxUIHotKey = registerKeyboardShortcut(
                boxUIShortcut,
                id: MenuBoxHotKey.boxUIID
            )
        }
    }

    private func setShortcutRecordingActive(_ active: Bool) {
        isRecordingShortcut = active
        if active {
            unregisterKeyboardShortcuts()
        } else {
            refreshKeyboardShortcuts()
        }
    }

    private func registerKeyboardShortcut(
        _ shortcut: KeyboardShortcutSetting,
        id: UInt32
    ) -> EventHotKeyRef? {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: MenuBoxHotKey.signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifierFlags(for: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("[MenuBox] Failed to register shortcut %@: %d", shortcut.displayTitle, status)
            return nil
        }
        return hotKeyRef
    }

    private func unregisterKeyboardShortcuts() {
        if let hotKey = menuBarIconHotKey {
            UnregisterEventHotKey(hotKey)
            menuBarIconHotKey = nil
        }
        if let hotKey = boxUIHotKey {
            UnregisterEventHotKey(hotKey)
            boxUIHotKey = nil
        }
    }

    private func uninstallKeyboardShortcuts() {
        unregisterKeyboardShortcuts()
        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    private func carbonModifierFlags(for modifiers: ShortcutModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettingsMenuAction), keyEquivalent: ","))
        if checkForUpdates != nil {
            menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesMenuAction), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MenuBox", action: #selector(quitMenuAction), keyEquivalent: "q"))

        for item in menu.items where item.target == nil {
            item.target = self
        }

        menu.popUp(positioning: nil, at: contextMenuAnchorPoint(for: button), in: button)
    }

    private func contextMenuAnchorPoint(for button: NSStatusBarButton) -> NSPoint {
        guard let window = button.window else {
            return NSPoint(x: button.bounds.midX, y: button.bounds.minY - 4)
        }

        let windowFrame = window.frame
        let windowCenter = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screen = MenuBarGeometry.screen(containing: windowCenter)
        let menuBarBottom = screen.map { MenuBarGeometry.menuBarRect(for: $0).minY } ?? windowFrame.minY
        let screenPoint = NSPoint(x: windowFrame.midX, y: menuBarBottom - 3)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let buttonPoint = button.convert(windowPoint, from: nil)

        return NSPoint(
            x: max(button.bounds.minX, min(button.bounds.maxX, buttonPoint.x)),
            y: buttonPoint.y
        )
    }

    @objc private func showHiddenIconsMenuAction() {
        showHiddenIcons()
    }

    @objc private func hideHiddenIconsMenuAction() {
        hideHiddenIcons()
    }

    @objc private func showHiddenIconsBoxMenuAction() {
        showHiddenIconsBox()
    }

    @objc private func refreshRangeMenuAction() {
        hideHiddenIcons()
    }

    @objc private func openSettingsMenuAction() {
        openSettings()
    }

    @objc private func checkForUpdatesMenuAction() {
        checkForUpdates?()
    }

    @objc private func quitMenuAction() {
        NSApplication.shared.terminate(nil)
    }

    private func openSettings(tab: SettingsTab? = nil) {
        if settingsWindowController == nil {
            let actions = SettingsActions(
                refreshHiddenRange: { [weak self] in
                    self?.hideHiddenIcons()
                },
                showHiddenIcons: { [weak self] in self?.showHiddenIcons() },
                hideHiddenIcons: { [weak self] in self?.hideHiddenIcons() },
                requestAccessibility: {
                    ClickForwarder.requestAccessibilityAccess()
                    ClickForwarder.openAccessibilitySettings()
                },
                requestFullDiskAccess: { ClickForwarder.openFullDiskAccessSettings() },
                setShortcutRecordingActive: { [weak self] active in
                    self?.setShortcutRecordingActive(active)
                },
                setLaunchAtLogin: { enabled in LaunchAtLoginManager.setEnabled(enabled) }
            )
            settingsWindowController = SettingsWindowController(store: store, permissions: permissions, actions: actions)
        }
        settingsWindowController?.show(tab: tab)
    }

    private func showHiddenIconsBox() {
        guard store.settings.boxUIEnabled else {
            return
        }

        guard ClickForwarder.accessibilityTrusted else {
            permissions.refresh()
            openSettings(tab: .permissions)
            return
        }

        guard let anchorFrame = statusItem?.button?.window?.frame,
              let tapeFrame = markerFrame,
              let screen = MenuBarGeometry.screen(containing: NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)) else {
            return
        }

        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()

        let cachedTargets = cachedProxyTargets(before: tapeFrame)
        let hasLoadedCache = cachedProxyTargetsLoadedAt != nil
        boxWindowController.showProxyTargets(
            anchorFrame: anchorFrame,
            screen: screen,
            proxyTargets: cachedTargets,
            statusText: hasLoadedCache ? nil : "Loading"
        )
        scheduleAutoHideIfNeeded()
        refreshProxyTargetCache(
            updateVisibleBox: true,
            retryWarmupIfEmpty: true
        )
        if usesNativeHiding { nativeHiding.environmentChanged(reason: "Box opened") }
    }

    private func startProxyTargetCacheWarmup() {
        proxyTargetWarmupWorkItem?.cancel()
        proxyTargetWarmupAttempt = 0
        scheduleProxyTargetCacheWarmupAttempt()
    }

    private func startProxyTargetPeriodicRefresh() {
        proxyTargetPeriodicRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: ProxyTargetCacheTiming.periodicRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.usesNativeHiding { self.nativeHiding.environmentChanged(reason: "status item inventory") }
            self.refreshProxyTargetCache(
                updateVisibleBox: self.boxWindowController.isShowing,
                retryWarmupIfEmpty: true
            )
        }
        timer.tolerance = 1
        proxyTargetPeriodicRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleProxyTargetCacheWarmupAttempt() {
        proxyTargetWarmupWorkItem?.cancel()
        guard proxyTargetCacheNeedsWarmup,
              proxyTargetWarmupAttempt < ProxyTargetCacheTiming.launchWarmupDelays.count else {
            return
        }

        let delay = ProxyTargetCacheTiming.launchWarmupDelays[proxyTargetWarmupAttempt]
        proxyTargetWarmupAttempt += 1

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.proxyTargetCacheNeedsWarmup else { return }
            self.refreshProxyTargetCache(
                updateVisibleBox: false,
                retryWarmupIfEmpty: true
            )
        }
        proxyTargetWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleProxyTargetCacheRefreshes(delays: [TimeInterval]) {
        proxyTargetRefreshWorkItems.forEach { $0.cancel() }
        proxyTargetRefreshWorkItems = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.usesNativeHiding { self.nativeHiding.environmentChanged(reason: "delayed item registration") }
                self.refreshProxyTargetCache(
                    updateVisibleBox: self.boxWindowController.isShowing,
                    retryWarmupIfEmpty: true
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func refreshProxyTargetCache(
        updateVisibleBox: Bool,
        retryWarmupIfEmpty: Bool = false
    ) {
        guard !isStopping, proxyTargetScanTask == nil, ClickForwarder.accessibilityTrusted else {
            return
        }
        let excludedPID = ProcessInfo.processInfo.processIdentifier
        let runningApplications = MenuBarProxyScanner.runningApplicationInfo(
            excludingProcessIdentifier: excludedPID
        )
        let startedAt = Date()

        proxyTargetScanTask = Task { [weak self] in
            let worker = Task.detached(priority: updateVisibleBox ? .userInitiated : .utility) {
                MenuBarProxyScanner.scanStatusItems(
                    runningApplications: runningApplications
                )
            }
            let scan = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, !self.isStopping else { return }
                self.proxyTargetScanTask = nil
                let owners = Dictionary(uniqueKeysWithValues:
                    MenuBarProxyScanner.runningApplicationInfo(excludingProcessIdentifier: excludedPID)
                        .map { ($0.processIdentifier, $0.bundleIdentifier) })
                self.targetInventory.merge(scan.targets, runningOwners: owners, completeOwners: scan.completeOwners,
                    preservingApplications: self.usesNativeHiding ? self.nativeHiding.hiddenApplications : [])
                self.cachedProxyTargetsLoadedAt = Date()
                NSLog(
                    "[MenuBox] Proxy inventory scanned %ld targets; retained %ld in %.1fms",
                    scan.targets.count, self.cachedProxyTargets.count,
                    Date().timeIntervalSince(startedAt) * 1000
                )

                if retryWarmupIfEmpty {
                    if self.proxyTargetCacheNeedsWarmup {
                        self.scheduleProxyTargetCacheWarmupAttempt()
                    } else {
                        self.proxyTargetWarmupWorkItem?.cancel()
                    }
                }

                // Resolve membership and the anchor now, not from coordinates
                // captured before this asynchronous scan or a display change.
                self.renderCachedProxyTargetsIfBoxVisible()
            }
        }
    }

    private func cachedProxyTargets(before tapeFrame: NSRect) -> [MenuBarProxyTarget] {
        if usesNativeHiding {
            if nativeHiding.isHidden {
                return targetInventory.selected(applications: nativeHiding.hiddenApplications)
            }
            // Share the same hosted section and multi-display validation as the
            // hiding backend. Overflow AX coordinates cannot classify membership.
            guard !nativeHiding.isTransitioning,
                  let snapshot = try? NativeMenuBarSnapshot.capture(),
                  let plan = try? snapshot.plan() else { return [] }
            return targetInventory.selected(applications: plan.applicationKeys)
        }
        return cachedProxyTargets
            .filter { $0.appKitFrame.maxX <= tapeFrame.minX + 1 }
            .sorted { $0.appKitFrame.minX < $1.appKitFrame.minX }
    }

    private func removeProxyTargets(processIdentifier: pid_t) {
        guard processIdentifier > 0 else { return }
        let oldCount = cachedProxyTargets.count
        targetInventory.remove(processIdentifier: processIdentifier)
        guard cachedProxyTargets.count != oldCount else { return }

        cachedProxyTargetsLoadedAt = Date()
        renderCachedProxyTargetsIfBoxVisible()
    }

    private func renderCachedProxyTargetsIfBoxVisible() {
        guard !isStopping, boxWindowController.isShowing,
              !boxWindowController.isMenuInteractionActive,
              let anchorFrame = statusItem?.button?.window?.frame,
              let tapeFrame = markerFrame,
              let screen = MenuBarGeometry.screen(containing: NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)) else {
            return
        }

        boxWindowController.refreshProxyTargets(
            anchorFrame: anchorFrame,
            screen: screen,
            proxyTargets: cachedProxyTargets(before: tapeFrame)
        )
    }

    private var proxyTargetCacheNeedsWarmup: Bool {
        if cachedProxyTargets.isEmpty { return true }
        guard usesNativeHiding, nativeHiding.isHidden else { return false }
        return !nativeHiding.hiddenApplications.isSubset(of: Set(cachedProxyTargets.map(\.bundleIdentifier)))
    }

    private func isQuitMenuSelection(_ selection: MenuBarProxyMenuSelection) -> Bool {
        let titles = (selection.path + [selection.item.title])
            .map { normalizedMenuCommandTitle($0) }
            .filter { !$0.isEmpty }

        return titles.contains { title in
            let localizedQuit = "\u{C885}\u{B8CC}"
            let localizedClose = "\u{B05D}\u{B0B4}\u{AE30}"
            return title == "quit" ||
                title.hasPrefix("quit ") ||
                title == "exit" ||
                title.hasPrefix("exit ") ||
                title == localizedQuit ||
                title.hasSuffix(" \(localizedQuit)") ||
                title == localizedClose ||
                title.hasSuffix(" \(localizedClose)")
        }
    }

    private func normalizedMenuCommandTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{2026}", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func hiddenIconsCaptureRect(tapeFrame: NSRect, screen: NSScreen) -> NSRect {
        let menu = MenuBarGeometry.menuBarRect(for: screen)
        let right = max(menu.minX, min(menu.maxX, tapeFrame.minX - 2))
        let left = max(menu.minX, right - HiddenBoxLayout.maxCaptureWidth)
        return NSRect(x: left, y: menu.minY, width: max(1, right - left), height: menu.height)
    }

    private func handleBoxIconClick(click: MenuBarProxyClick, button: CGMouseButton) {
        switch button {
        case .left:
            guard let target = click.target else {
                boxWindowController.showStatus("Failed: No target")
                scheduleAutoHideIfNeeded(minimumDelay: 15)
                return
            }
            activateTargetApplication(target)
        case .right:
            forwardClickToMenuBar(click: click, button: button)
        default:
            forwardClickToMenuBar(click: click, button: button)
        }
    }

    private func forwardClickToMenuBar(click: MenuBarProxyClick, button: CGMouseButton) {
        guard ClickForwarder.accessibilityTrusted else {
            permissions.refresh()
            openSettings(tab: .permissions)
            return
        }

        autoHideTimer?.invalidate()
        autoHideTimer = nil

        if usesNativeHiding || !click.revealBeforeForwarding {
            guard let target = click.target else {
                boxWindowController.showStatus("Failed: No target")
                return
            }

            openHiddenStatusItemMenu(for: target, anchorPoint: click.menuAnchorPoint)
            return
        }

        revealMenuBarIcons()

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            var target: MenuBarProxyTarget?

            for attempt in 0..<HiddenBoxLayout.clickForwardMaxAttempts {
                let delay = attempt == 0
                    ? HiddenBoxLayout.clickForwardInitialDelayNanoseconds
                    : HiddenBoxLayout.clickForwardRetryDelayNanoseconds
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                target = await MainActor.run {
                    self.liveTarget(for: click)
                }

                if target != nil {
                    break
                }
            }

            let resolvedTarget = target
            let forwardResult = await MainActor.run {
                let targetForClick = resolvedTarget ?? self.visibleFallbackTarget(for: click)
                let point = targetForClick?.appKitClickPoint ?? click.appKitPoint
                guard self.isVisibleMenuBarPoint(point) else {
                    NSLog("[MenuBox] Proxy click target is not visible after reveal point=%@", NSStringFromPoint(point))
                    self.boxWindowController.showStatus("Failed: Target not found")
                    return ClickForwarder.ForwardResult.failed
                }

                if let targetForClick {
                    NSLog("[MenuBox] Forwarding native proxy click to target role=%@ title=%@ description=%@ point=%@", targetForClick.role, targetForClick.title, targetForClick.description, NSStringFromPoint(point))
                } else {
                    NSLog("[MenuBox] Forwarding native proxy click without AX target point=%@", NSStringFromPoint(point))
                }

                let result = ClickForwarder.postClick(at: point, button: button, target: targetForClick)
                let targetName = targetForClick?.displayName ?? "Point"
                self.boxWindowController.showStatus("\(result.title): \(targetName)")
                return result
            }

            await MainActor.run {
                if forwardResult.didForward {
                    self.scheduleAutoHideIfNeeded(minimumDelay: 10)
                } else {
                    self.scheduleAutoHideIfNeeded(minimumDelay: 30)
                }
            }
        }
    }

    private func openHiddenStatusItemMenu(for target: MenuBarProxyTarget, anchorPoint: NSPoint?) {
        let previous = hiddenMenuTask
        previous?.cancel()
        boxWindowController.beginMenuInteraction()
        boxWindowController.showStatus("Opening menu: \(target.displayName)")
        hiddenMenuTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.boxWindowController.beginMenuInteraction()
            guard let liveTarget = MenuBarProxyScanner.refreshedStatusItemTarget(from: target) else {
                self.boxWindowController.showUnavailableMenu(for: target, anchorPoint: anchorPoint)
                self.boxWindowController.endMenuInteraction()
                return
            }
            if let opened = await self.requestHiddenStatusItemMenu(for: liveTarget) {
                if self.usesNativeHiding, let presentation = opened.presentation,
                   self.boxWindowController.canUseNativeMenu(presentation, anchorPoint: anchorPoint) {
                    self.nativeHiding.recordMenuInteraction("native presentation: \(liveTarget.bundleIdentifier), window=\(presentation.windowID)")
                    await NativeStatusItemMenu.keepVisibleUntilClosed(opened, isVisible: { presentation.isVisible })
                    self.nativeHiding.recordMenuInteraction("native presentation ended: \(liveTarget.bundleIdentifier)")
                    if !Task.isCancelled {
                        self.boxWindowController.endMenuInteraction()
                        self.scheduleAutoHideIfNeeded(minimumDelay: 15)
                    }
                    return
                }
                if self.usesNativeHiding {
                    self.nativeHiding.recordMenuInteraction("proxy presentation: \(liveTarget.bundleIdentifier), nativeFrame=\(opened.presentation.map { NSStringFromRect($0.frame) } ?? "unavailable")")
                }
                // The native popup is anchored to an offscreen icon. Display its
                // live contents in Box UI, then reacquire the native item at selection.
                opened.cancel()
                guard !Task.isCancelled, self.boxWindowController.isShowing else { return }
                self.boxWindowController.showProxyMenu(
                    for: liveTarget, items: opened.items, anchorPoint: anchorPoint
                ) { [weak self] selection in
                    self?.selectHiddenStatusItemMenu(selection, target: liveTarget)
                }
            } else if !Task.isCancelled, self.boxWindowController.isShowing {
                let items = MenuBarProxyScanner.immediateProxyMenuItems(for: liveTarget)
                if !self.showProxyMenuIfAvailable(for: liveTarget, items: items, anchorPoint: anchorPoint) {
                    self.boxWindowController.showUnavailableMenu(for: liveTarget, anchorPoint: anchorPoint)
                }
            }
            if !Task.isCancelled {
                self.boxWindowController.endMenuInteraction()
                self.scheduleAutoHideIfNeeded(minimumDelay: 15)
            }
        }
    }

    @MainActor
    private func requestHiddenStatusItemMenu(for target: MenuBarProxyTarget) async -> OpenedStatusItemMenu? {
        let menu = await NativeStatusItemMenu.read(for: target) { reason in
            if self.usesNativeHiding {
                self.nativeHiding.recordMenuInteraction("request: \(target.bundleIdentifier), \(reason)")
            }
        }
        if usesNativeHiding {
            nativeHiding.recordMenuInteraction("read: \(target.bundleIdentifier), items=\(menu?.items.count ?? 0)")
        }
        if let menu { return menu }
        guard !Task.isCancelled, usesNativeHiding, nativeHiding.isHidden,
              nativeHiding.hiddenApplications.contains(target.bundleIdentifier) else { return nil }
        return await requestTemporarilyVisibleMenu(for: target)
    }

    @MainActor
    private func requestTemporarilyVisibleMenu(for target: MenuBarProxyTarget) async -> OpenedStatusItemMenu? {
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let lease = try nativeHiding.beginTemporaryReveal(target.bundleIdentifier)
            var menuOwnsLease = false
            defer { if !menuOwnsLease { nativeHiding.endTemporaryReveal(lease) } }
            boxWindowController.showStatus("Opening menu: temporarily showing \(target.displayName)")
            // Wait for the host to publish the selected app at its real position.
            // A hidden AX frame can remain readable but points at the overflow
            // placeholder, so it must not be used as an event destination.
            while ProcessInfo.processInfo.systemUptime - started < 3 {
                try Task.checkCancellation()
                if (try? nativeHiding.temporaryRevealIsReady(lease)) == true,
                   let live = MenuBarProxyScanner.refreshedStatusItemTarget(from: target),
                   let destination = StatusItemEventRouter.visibleHostDestination(for: live) {
                    let opened = await NativeStatusItemMenu.read(for: live, destination: destination) { reason in
                        self.nativeHiding.recordMenuInteraction("temporary request: \(target.bundleIdentifier), \(reason)")
                    }
                    guard !Task.isCancelled, let opened else {
                        opened?.cancel()
                        return nil
                    }
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    nativeHiding.recordMenuInteraction("temporary read: \(target.bundleIdentifier), items=\(opened.items.count), elapsed=\(milliseconds)ms")
                    // The caller dismisses immediately for Box presentation,
                    // but keeps the live menu through command execution on
                    // selection. Rehiding earlier can invalidate dynamic items.
                    menuOwnsLease = true
                    return .init(items: opened.items, roots: opened.roots, presentation: opened.presentation) { [weak self] in
                        self?.nativeHiding.endTemporaryReveal(lease)
                    }
                }
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            nativeHiding.recordMenuInteraction("temporary route unavailable: " + target.bundleIdentifier)
        } catch is CancellationError {
            return nil
        } catch {
            nativeHiding.recordMenuInteraction("temporary reveal refused: " + error.localizedDescription)
        }
        return nil
    }

    private func selectHiddenStatusItemMenu(_ selection: MenuBarProxyMenuSelection, target: MenuBarProxyTarget) {
        let previous = hiddenMenuTask
        previous?.cancel()
        boxWindowController.beginMenuInteraction()
        hiddenMenuTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.boxWindowController.beginMenuInteraction()
            defer { self.boxWindowController.endMenuInteraction() }
            guard let currentTarget = MenuBarProxyScanner.refreshedStatusItemTarget(from: target),
                  let opened = await self.requestHiddenStatusItemMenu(for: currentTarget) else {
                self.boxWindowController.showStatus("Menu unavailable: \(target.displayName)")
                self.scheduleAutoHideIfNeeded(minimumDelay: 15)
                return
            }
            defer { opened.cancel() }
            guard !Task.isCancelled else { return }
            guard let item = MenuBarProxyScanner.currentMenuItem(matching: selection, in: opened.items) else {
                self.boxWindowController.showStatus("Menu changed: Open it again")
                self.scheduleAutoHideIfNeeded(minimumDelay: 15)
                return
            }
            let result = ClickForwarder.performProxyMenuItem(item)
            if self.usesNativeHiding {
                self.nativeHiding.recordMenuInteraction("selection: \(target.bundleIdentifier), forwarded=\(result.didForward)")
            }
            self.boxWindowController.showStatus("\(result.title): \(item.title)")
            if result.didForward, self.isQuitMenuSelection(selection) {
                self.removeProxyTargets(processIdentifier: target.processIdentifier)
            }
            self.scheduleAutoHideIfNeeded(minimumDelay: 15)
        }
    }

    private func activateTargetApplication(_ target: MenuBarProxyTarget) {
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        guard let app = runningApplication(for: target) else {
            boxWindowController.showStatus("Unsupported app: \(target.displayName)")
            scheduleAutoHideIfNeeded(minimumDelay: 15)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.performTargetApplicationActivation(app, target: target)
        }
    }

    private func performTargetApplicationActivation(_ app: NSRunningApplication, target: MenuBarProxyTarget) {
        if app.isHidden {
            app.unhide()
        }

        _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        let windowActivation = raiseApplicationWindows(processIdentifier: app.processIdentifier)
        if windowActivation.didRaiseWindow {
            boxWindowController.close()
            scheduleAutoHideIfNeeded(minimumDelay: 10)
            return
        }

        if windowActivation.hasWindows {
            boxWindowController.close()
            scheduleAutoHideIfNeeded(minimumDelay: 10)
            return
        }

        reopenApplicationBundle(app, target: target)
    }

    private func runningApplication(for target: MenuBarProxyTarget) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: target.processIdentifier) {
            return app
        }

        if !target.bundleIdentifier.isEmpty,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == target.bundleIdentifier }) {
            return app
        }

        guard !target.appName.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == target.appName }
    }

    private func raiseApplicationWindows(processIdentifier pid: pid_t) -> ApplicationWindowActivationResult {
        guard ClickForwarder.accessibilityTrusted else {
            return ApplicationWindowActivationResult(hasWindows: false, didRaiseWindow: false)
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            return ApplicationWindowActivationResult(hasWindows: false, didRaiseWindow: false)
        }

        var didRaiseWindow = false
        for window in windows {
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               (minimizedValue as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }

            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
                didRaiseWindow = true
            }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        return ApplicationWindowActivationResult(hasWindows: true, didRaiseWindow: didRaiseWindow)
    }

    private func reopenApplicationBundle(_ app: NSRunningApplication, target: MenuBarProxyTarget) {
        guard let bundleURL = app.bundleURL else {
            NSLog("[MenuBox] Failed to activate app without bundle URL: %@", target.displayName)
            markTargetApplicationUnsupported(target)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] reopenedApp, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    NSLog("[MenuBox] Failed to reopen %@: %@", target.displayName, error.localizedDescription)
                    self.markTargetApplicationUnsupported(target)
                    return
                }

                let appToRaise = reopenedApp ?? app
                _ = appToRaise.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                self.verifyTargetApplicationWindow(
                    app: appToRaise,
                    target: target,
                    delays: ApplicationActivationTiming.windowCheckDelays
                )
            }
        }
    }

    private func verifyTargetApplicationWindow(
        app: NSRunningApplication,
        target: MenuBarProxyTarget,
        delays: [TimeInterval]
    ) {
        guard let delay = delays.first else {
            markTargetApplicationUnsupported(target)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            let windowActivation = self.raiseApplicationWindows(processIdentifier: app.processIdentifier)
            if windowActivation.hasWindows || windowActivation.didRaiseWindow {
                self.boxWindowController.close()
                self.scheduleAutoHideIfNeeded(minimumDelay: 10)
                return
            }

            self.verifyTargetApplicationWindow(
                app: app,
                target: target,
                delays: Array(delays.dropFirst())
            )
        }
    }

    private func markTargetApplicationUnsupported(_ target: MenuBarProxyTarget) {
        boxWindowController.showStatus("Unsupported app: \(target.displayName)")
        scheduleAutoHideIfNeeded(minimumDelay: 30)
    }

    private func showProxyMenuIfAvailable(
        for target: MenuBarProxyTarget,
        items: [MenuBarProxyMenuItem],
        anchorPoint: NSPoint?
    ) -> Bool {
        guard items.contains(where: { !$0.isSeparator }) else {
            return false
        }

        boxWindowController.showProxyMenu(
            for: target,
            items: items,
            anchorPoint: anchorPoint
        ) { [weak self] selection in
            guard let self else { return }
            let result = ClickForwarder.performProxyMenuSelection(selection, target: target)
            self.boxWindowController.showStatus("\(result.title): \(selection.item.title)")
            if result.didForward, self.isQuitMenuSelection(selection) {
                self.removeProxyTargets(processIdentifier: target.processIdentifier)
            }
            if result.didForward {
                self.scheduleAutoHideIfNeeded(minimumDelay: 10)
            } else {
                self.scheduleAutoHideIfNeeded(minimumDelay: 30)
            }
        }
        scheduleAutoHideIfNeeded(minimumDelay: 10)
        return true
    }

    private func liveTarget(for click: MenuBarProxyClick) -> MenuBarProxyTarget? {
        if let original = click.target,
           let refreshed = MenuBarProxyScanner.refreshedTarget(from: original),
           isVisibleMenuBarPoint(refreshed.appKitClickPoint) {
            return refreshed
        }

        if let original = click.target,
           let searchRect = currentVisibleHiddenIconsSearchRect(),
           let matched = MenuBarProxyScanner.matchingTarget(for: original, in: searchRect),
           isVisibleMenuBarPoint(matched.appKitClickPoint) {
            return matched
        }

        if click.searchRect.width > 0,
           click.searchRect.height > 0,
           let nearby = MenuBarProxyScanner.bestTarget(near: click.appKitPoint, in: click.searchRect),
           isVisibleMenuBarPoint(nearby.appKitClickPoint) {
            return nearby
        }

        return nil
    }

    private func visibleFallbackTarget(for click: MenuBarProxyClick) -> MenuBarProxyTarget? {
        guard let target = click.target,
              isVisibleMenuBarPoint(target.appKitClickPoint) else {
            return nil
        }
        return target
    }

    private func currentVisibleHiddenIconsSearchRect() -> NSRect? {
        guard let tapeFrame = markerFrame,
              let screen = MenuBarGeometry.screen(containing: NSPoint(x: tapeFrame.midX, y: tapeFrame.midY)) else {
            return nil
        }

        return hiddenIconsCaptureRect(tapeFrame: tapeFrame, screen: screen).insetBy(dx: -12, dy: -6)
    }

    private func isVisibleMenuBarPoint(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            MenuBarGeometry.menuBarRect(for: screen)
                .insetBy(dx: -2, dy: -8)
                .contains(point)
        }
    }

    @objc private func screenParametersChanged() {
        store.refreshDisplays()
        if usesNativeHiding { nativeHiding.environmentChanged(reason: "display parameters") }
        if isHidden {
            hideHiddenIcons()
        }
        scheduleProxyTargetCacheRefreshes(delays: ProxyTargetCacheTiming.environmentRefreshDelays)
    }

    @objc private func activeSpaceChanged() {
        if usesNativeHiding { nativeHiding.environmentChanged(reason: "active Space") }
        if isHidden {
            hideHiddenIcons()
        }
        scheduleProxyTargetCacheRefreshes(delays: ProxyTargetCacheTiming.environmentRefreshDelays)
    }

    @objc private func runningApplicationsChanged() {
        if usesNativeHiding { nativeHiding.environmentChanged(reason: "application launched") }
        scheduleProxyTargetCacheRefreshes(delays: ProxyTargetCacheTiming.appChangeRefreshDelays)
    }

    @objc private func runningApplicationTerminated(_ notification: Notification) {
        if usesNativeHiding { nativeHiding.environmentChanged(reason: "application terminated") }
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            removeProxyTargets(processIdentifier: app.processIdentifier)
        } else if let app = notification.object as? NSRunningApplication {
            removeProxyTargets(processIdentifier: app.processIdentifier)
        }
        scheduleProxyTargetCacheRefreshes(delays: ProxyTargetCacheTiming.appChangeRefreshDelays)
    }

    @objc private func applicationActivated() {
        guard usesNativeHiding else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.nativeHiding.verifyAfterFocusChange()
        }
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        guard usesNativeHiding else { return }
        hiddenMenuTask?.cancel()
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        nativeHiding.suspend()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        if usesNativeHiding { nativeHiding.resume(reason: notification.name.rawValue) }
        else if isHidden { hideHiddenIcons() }
        scheduleProxyTargetCacheRefreshes(delays: ProxyTargetCacheTiming.environmentRefreshDelays)
    }

    private func showHidingError(_ message: String) {
        permissions.refresh()
        // Missing access has its own actionable settings page, not a transient
        // Box error. PermissionStore presents it once per loss of access.
        guard permissions.snapshot.isReady else { return }
        guard let frame = statusItem?.button?.window?.frame,
              let screen = MenuBarGeometry.screen(containing: NSPoint(x: frame.midX, y: frame.midY)) else { return }
        boxWindowController.showProxyTargets(anchorFrame: frame, screen: screen, proxyTargets: [], statusText: message)
    }
}

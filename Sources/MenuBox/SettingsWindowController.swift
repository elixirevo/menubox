import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let store: SettingsStore
    private let navigation = SettingsNavigation()

    init(store: SettingsStore, permissions: PermissionStore, actions: SettingsActions) {
        self.store = store

        let view = SettingsView(store: store, permissions: permissions, navigation: navigation, actions: actions)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MenuBox Settings"
        window.setContentSize(NSSize(width: 660, height: 600))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.selectedTab = tab }
        store.refreshDisplays()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct SettingsActions {
    var refreshHiddenRange: () -> Void
    var showHiddenIcons: () -> Void
    var hideHiddenIcons: () -> Void
    var requestAccessibility: () -> Void
    var requestFullDiskAccess: () -> Void
    var setShortcutRecordingActive: (Bool) -> Void
    var setLaunchAtLogin: (Bool) -> Void
}

enum SettingsTab: Hashable { case general, display, permissions }

final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
}

private enum ShortcutRecordingTarget {
    case menuBarIcon
    case boxUI
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionStore
    @ObservedObject var navigation: SettingsNavigation
    let actions: SettingsActions
    @State private var shortcutRecordingTarget: ShortcutRecordingTarget?
    @State private var shortcutMonitor: Any?
    @State private var isShowingResetConfirmation = false
    private let autoHideDelayOptions: [Double] = [5, 10, 15, 20, 30, 60]

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            displayTab
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.display)
            permissionTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .padding(SettingsLayout.windowPadding)
        .frame(minWidth: 560, minHeight: 460)
        .onDisappear {
            stopShortcutCapture()
        }
    }

    private var generalTab: some View {
        SettingsForm {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { enabled in
                        store.update { $0.launchAtLogin = enabled }
                        actions.setLaunchAtLogin(enabled)
                    }
                ))

                Toggle("Auto-hide again", isOn: Binding(
                    get: { store.settings.autoHideEnabled },
                    set: { enabled in store.update { $0.autoHideEnabled = enabled } }
                ))

                Picker("Auto-hide delay", selection: Binding(
                    get: { normalizedAutoHideDelay },
                    set: { value in store.update { $0.autoHideDelaySeconds = value } }
                )) {
                    ForEach(autoHideDelayOptions, id: \.self) { seconds in
                        Text("\(Int(seconds))s").tag(seconds)
                    }
                }
            }

            Section("Box Icon") {
                Toggle("Show Box UI", isOn: Binding(
                    get: { store.settings.boxUIEnabled },
                    set: { enabled in store.update { $0.boxUIEnabled = enabled } }
                ))

                Picker("Left click", selection: boxIconActionBinding(
                    \.boxIconLeftClickAction,
                    fallback: .toggleHiddenIcons
                )) {
                    ForEach(BoxIconAction.clickActionCases) { action in
                        Text(action.title).tag(action)
                    }
                }

                Picker("Right click", selection: boxIconActionBinding(
                    \.boxIconRightClickAction,
                    fallback: .showBoxUI
                )) {
                    ForEach(BoxIconAction.clickActionCases) { action in
                        Text(action.title).tag(action)
                    }
                }
            }

            Section("Shortcuts") {
                Toggle("Enable shortcuts", isOn: Binding(
                    get: { store.settings.shortcutsEnabled },
                    set: { enabled in store.update { $0.shortcutsEnabled = enabled } }
                ))

                shortcutRow(
                    "Menu bar icon",
                    target: .menuBarIcon,
                    shortcut: store.settings.menuBarIconShortcut
                )
                shortcutRow(
                    "Box UI",
                    target: .boxUI,
                    shortcut: store.settings.boxUIShortcut
                )
            }

            Section("Reset") {
                Button("Reset to Defaults", role: .destructive) {
                    isShowingResetConfirmation = true
                }
            }
        }
        .alert("Reset Settings?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetSettingsToDefaults()
            }
        } message: {
            Text("This will restore all settings to their default values.")
        }
    }

    private var normalizedAutoHideDelay: Double {
        autoHideDelayOptions.min {
            abs($0 - store.settings.autoHideDelaySeconds) < abs($1 - store.settings.autoHideDelaySeconds)
        } ?? 5
    }

    private func boxIconActionBinding(
        _ keyPath: WritableKeyPath<AppSettings, BoxIconAction>,
        fallback: BoxIconAction
    ) -> Binding<BoxIconAction> {
        Binding(
            get: {
                let action = store.settings[keyPath: keyPath]
                return BoxIconAction.clickActionCases.contains(action) ? action : fallback
            },
            set: { action in
                store.update { $0[keyPath: keyPath] = action }
            }
        )
    }

    private func shortcutRow(
        _ title: String,
        target: ShortcutRecordingTarget,
        shortcut: KeyboardShortcutSetting
    ) -> some View {
        let isRecording = shortcutRecordingTarget == target

        return SettingsRow(title) {
            Text(isRecording ? "Press shortcut" : shortcut.displayTitle)
                .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                .monospaced()
                .fixedSize()
                .frame(minWidth: 96, alignment: .trailing)
            Button {
                if isRecording {
                    stopShortcutCapture()
                } else {
                    startShortcutCapture(target)
                }
            } label: {
                Text(isRecording ? "Cancel" : "Change")
                    .frame(minWidth: 52)
            }
        }
    }

    private func startShortcutCapture(_ target: ShortcutRecordingTarget) {
        stopShortcutCapture()
        shortcutRecordingTarget = target
        actions.setShortcutRecordingActive(true)

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopShortcutCapture()
                return nil
            }

            guard let shortcut = KeyboardShortcutSetting.from(event: event) else {
                NSSound.beep()
                return nil
            }

            store.update { settings in
                switch target {
                case .menuBarIcon:
                    settings.menuBarIconShortcut = shortcut
                case .boxUI:
                    settings.boxUIShortcut = shortcut
                }
            }
            stopShortcutCapture()
            return nil
        }
    }

    private func stopShortcutCapture() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        if shortcutRecordingTarget != nil {
            shortcutRecordingTarget = nil
            actions.setShortcutRecordingActive(false)
        }
    }

    private func resetSettingsToDefaults() {
        stopShortcutCapture()
        store.resetToDefaults()
        actions.setLaunchAtLogin(AppSettings.defaults.launchAtLogin)
    }

    private var displayTab: some View {
        SettingsForm {
            Section("Box Icons") {
                Toggle("Show Box UI alerts", isOn: Binding(
                    get: { store.settings.boxStatusMessagesEnabled },
                    set: { enabled in store.update { $0.boxStatusMessagesEnabled = enabled } }
                ))

                SettingsRow("Icons per row") {
                    Text("\(store.settings.boxMaxColumns)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    Stepper("Icons per row", value: Binding(
                        get: { store.settings.boxMaxColumns },
                        set: { value in
                            store.update { $0.boxMaxColumns = max(1, min(20, value)) }
                        }
                    ), in: 1...20)
                    .labelsHidden()
                }
            }

            Section("Menu Bar Icons") {
                SettingsRow("Hidden icons") {
                    Button("Show hidden icons") {
                        actions.showHiddenIcons()
                    }
                    Button("Hide again") {
                        actions.hideHiddenIcons()
                    }
                }
            }
        }
    }

    private var permissionTab: some View {
        SettingsForm {
            Section {
                PermissionRow(
                    title: permissions.snapshot.fullDiskAccess == nil
                        ? "Accessibility" : "Device Control and Data Access (Accessibility)",
                    description: "Required to find menu bar icons and open their menus from Box UI.",
                    access: permissions.snapshot.accessibility ? .available : .denied,
                    action: actions.requestAccessibility
                )

                if let diskAccess = permissions.snapshot.fullDiskAccess {
                    PermissionRow(
                        title: "Full Disk Access",
                        description: "Required to hide icons on macOS 27. MenuBox uses this to access menu bar settings. This macOS permission also allows access to other apps’ data.",
                        access: diskAccess,
                        action: actions.requestFullDiskAccess
                    )
                }
            } header: {
                Text("Required Permissions")
            } footer: {
                Text("Enable MenuBox in System Settings → Privacy & Security.")
            }

            Section {
                SettingsRow("MenuBox application") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Open System Settings, then turn on MenuBox in each list. If it is missing, use the + button to add this app. If macOS asks, quit and reopen MenuBox after changing access.")
            }

            Section {
                HStack(spacing: SettingsLayout.rowSpacing) {
                    Label(permissions.snapshot.isReady ? "All required permissions are ready." : "Waiting for access…",
                          systemImage: permissions.snapshot.isReady ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(permissions.snapshot.isReady ? Color.green : Color.secondary)
                    Spacer()
                    Button("Check Again") { permissions.refresh() }
                }
                .frame(minHeight: SettingsLayout.rowHeight)
                if permissions.snapshot.fullDiskAccess == .unavailable {
                    SettingsDescription("Menu bar settings could not be checked. This does not necessarily mean access was denied. Try checking again.")
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Permission status updates automatically when you return here.")
            }
        }
    }
}

private enum SettingsLayout {
    static let windowPadding: CGFloat = 20
    static let rowSpacing: CGFloat = 12
    static let textSpacing: CGFloat = 4
    static let rowHeight: CGFloat = 24
}

/// Keep every tab on the same native spacing, section, and control styles.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .controlSize(.regular)
            .buttonStyle(.bordered)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let content: Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        HStack(spacing: SettingsLayout.rowSpacing) {
            VStack(alignment: .leading, spacing: SettingsLayout.textSpacing) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if let description {
                    SettingsDescription(description)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .frame(minHeight: SettingsLayout.rowHeight)
    }
}

private struct SettingsDescription: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let access: PermissionAccess
    let action: () -> Void

    var body: some View {
        SettingsRow(title, description: description) {
            VStack(alignment: .trailing, spacing: SettingsLayout.rowSpacing) {
                Label(access.title, systemImage: statusIcon)
                    .font(.callout)
                    .foregroundStyle(access == .available ? .green : .orange)
                    .fixedSize()
                Button("Open System Settings", action: action)
                    .fixedSize()
            }
        }
    }

    private var statusIcon: String {
        switch access {
        case .available: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .unavailable: return "questionmark.circle.fill"
        }
    }
}

enum LaunchAtLoginManager {
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MenuBox launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}

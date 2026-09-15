import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let store: SettingsStore
    private let actions: SettingsActions

    init(store: SettingsStore, actions: SettingsActions) {
        self.store = store
        self.actions = actions

        let view = SettingsView(store: store, actions: actions)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MenuBox Settings"
        window.setContentSize(NSSize(width: 620, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
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
    var requestScreenRecording: () -> Void
    var setShortcutRecordingActive: (Bool) -> Void
    var setLaunchAtLogin: (Bool) -> Void
}

private enum ShortcutRecordingTarget {
    case menuBarIcon
    case boxUI
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions
    @State private var shortcutRecordingTarget: ShortcutRecordingTarget?
    @State private var shortcutMonitor: Any?
    @State private var isShowingResetConfirmation = false
    private let autoHideDelayOptions: [Double] = [5, 10, 15, 20, 30, 60]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            displayTab
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }
            permissionTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .onDisappear {
            stopShortcutCapture()
        }
    }

    private var generalTab: some View {
        Form {
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
        .formStyle(.grouped)
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

        return HStack {
            Text(title)
            Spacer()
            Text(isRecording ? "Press shortcut" : shortcut.displayTitle)
                .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                .monospaced()
                .frame(width: 96, alignment: .trailing)
            Button(isRecording ? "Cancel" : "Change") {
                if isRecording {
                    stopShortcutCapture()
                } else {
                    startShortcutCapture(target)
                }
            }
            .frame(width: 64)
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
        Form {
            Section("Box Icons") {
                Toggle("Show Box UI alerts", isOn: Binding(
                    get: { store.settings.boxStatusMessagesEnabled },
                    set: { enabled in store.update { $0.boxStatusMessagesEnabled = enabled } }
                ))

                HStack(alignment: .center) {
                    Text("Icons per row")
                    Spacer()
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
                HStack {
                    Button("Show hidden icons") {
                        actions.showHiddenIcons()
                    }
                    Button("Hide again") {
                        actions.hideHiddenIcons()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var permissionTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionRow(
                title: "Accessibility",
                description: "Required to find hidden status icons and open their menus from Box UI.",
                granted: ClickForwarder.accessibilityTrusted,
                actionTitle: "Request Access",
                action: actions.requestAccessibility
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Spacer()
                Button(actionTitle, action: action)
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

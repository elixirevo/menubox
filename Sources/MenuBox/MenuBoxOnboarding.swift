// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore
import MacAppOnboarding
import MacAppSettings
import SwiftUI

/// Owns the app's completion record, independently of release versions and consent.
@MainActor
final class MenuBoxOnboarding {
    static let completionKey = "MenuBox.Onboarding.CompletedVersion"
    static let flowVersion = 1
    private let agreement: TermsAgreementModel
    private var agreementHost: TermsAgreementWindowController?
    private let permissions: PermissionSettingsModel
    private let crashPreference: CrashReportingPreference?
    private let defaults: UserDefaults
    private let onClose: () -> Void
    private(set) var host: OnboardingWindowController?

    var isVisible: Bool {
        [host?.window, agreementHost?.window].contains { $0?.isVisible == true || $0?.isMiniaturized == true }
    }

    init(permissions: PermissionSettingsModel, agreement: TermsAgreementModel, crashPreference: CrashReportingPreference?,
         defaults: UserDefaults = .standard, onClose: @escaping () -> Void = {}) {
        self.permissions = permissions
        self.agreement = agreement
        self.crashPreference = crashPreference
        self.defaults = defaults
        self.onClose = onClose
    }

    /// Reviewing a completed tour does not erase or downgrade the real completion record.
    static func completionStore(defaults: UserDefaults, replay: Bool) -> OnboardingStore {
        var reviewing = replay
        return OnboardingStore(readCompletedVersion: {
            reviewing ? 0 : defaults.integer(forKey: completionKey)
        }, writeCompletedVersion: { version in
            defaults.set(max(version, defaults.integer(forKey: completionKey)), forKey: completionKey)
            reviewing = false
        })
    }

    static func makeModel(permissions: PermissionSettingsModel, agreement: TermsAgreementModel,
                          crashPreference: CrashReportingPreference?,
                          store: OnboardingStore) throws -> OnboardingModel {
        var steps: [OnboardingStep] = [
            .welcome(message: menuBoxLocalized("A tidy menu bar, with your apps still within reach.")),
            .custom(id: "arrange", title: menuBoxLocalized("Choose which icons to hide")) {
                MenuBoxArrangementGuide()
            },
            .custom(id: "box", title: menuBoxLocalized("Your apps in one small box")) {
                MenuBoxBoxGuide()
            },
            .guide(id: "settings", title: menuBoxLocalized("Make MenuBox your own"),
                   message: menuBoxLocalized("Right-click the tape marker to open Settings. Adjust auto-hide in Display and key combinations in Shortcuts. Find this guide and the offline terms in Help & Support."),
                   illustration: .init(Image(systemName: "slider.horizontal.3"),
                                       accessibilityLabel: menuBoxLocalized("MenuBox settings"))),
            .terms(agreement),
            .permissions(permissions)
        ]
        if let crashPreference { steps.append(.diagnostics(crashPreference)) }

        return try OnboardingModel(steps: steps, version: flowVersion, store: store)
    }

    @discardableResult
    func showIfNeeded(replay: Bool = false) -> Bool {
        if let agreementHost, agreementHost.showIfNeeded() { return true }
        if let host, host.showIfNeeded() { return true }
        if !replay, defaults.integer(forKey: Self.completionKey) >= Self.flowVersion,
           agreement.requiresAcceptance {
            let window = TermsAgreementWindowController(
                identity: SettingsIdentity(bundle: .main, icon: NSApp.applicationIconImage),
                model: agreement, autosaveName: "com.elixirevo.MenuBox.TermsAgreement",
                onAccepted: onClose, onQuit: { NSApp.terminate(nil) })
            agreementHost = window
            return window.showIfNeeded()
        }
        guard replay || defaults.integer(forKey: Self.completionKey) < Self.flowVersion else { return false }
        do {
            let model = try Self.makeModel(permissions: permissions, agreement: agreement, crashPreference: crashPreference,
                store: Self.completionStore(defaults: defaults, replay: replay))
            host = OnboardingWindowController(
                identity: SettingsIdentity(bundle: .main, icon: NSApp.applicationIconImage), model: model,
                autosaveName: "com.elixirevo.MenuBox.Onboarding",
                onFinish: onClose, onDismiss: onClose, onQuit: { NSApp.terminate(nil) })
            return host?.showIfNeeded() == true
        } catch {
            NSLog("[MenuBox] Setup could not open: %@", error.localizedDescription)
            return false
        }
    }
}

/// Uses the actual status-item artwork, staying legible in both appearances and languages.
private struct MenuBoxArrangementGuide: View {
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 18) {
                HStack(spacing: 16) {
                    Image(systemName: "headphones")
                    Image(systemName: "cloud")
                    Image(systemName: "doc.on.clipboard")
                }
                .padding(16)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Image(nsImage: StatusIconFactory.tapeIcon()).resizable().frame(width: 28, height: 28)
                Image(systemName: "shippingbox").font(.title).scaleEffect(x: -1, y: 1)
                Image(systemName: "wifi")
            }
            .font(.title2)
            .padding(.vertical, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(menuBoxLocalized("Icons to hide on the left, then the tape marker, box icon and visible icons on the right."))
            Text(menuBoxLocalized("Choose which icons to hide")).font(.largeTitle.bold())
            Text(menuBoxLocalized("Hold ⌘ and drag the tape marker to the right of the icons you want to hide. The icons to its left belong in MenuBox."))
                .font(.title3)
            Text(menuBoxLocalized("By default, click the box icon to show or hide icons, and right-click it to open Box UI. On macOS 27, the tape marker hides along with your icons."))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Mirror the vector symbol just like StatusIconFactory, without enlarging its 18pt bitmap.
private struct MenuBoxBoxGuide: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox").resizable().scaledToFit()
                .scaleEffect(x: -1, y: 1)
                .frame(maxWidth: .infinity).frame(height: 160)
                .accessibilityLabel(menuBoxLocalized("MenuBox box icon"))
            Text(menuBoxLocalized("Your apps in one small box")).font(.largeTitle.bold())
            Text(menuBoxLocalized("Option-click the box icon to open Box UI. Click an app to bring its window forward, or right-click to open its menu when supported."))
                .font(.title3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

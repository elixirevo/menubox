// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore
import MacAppSettings
import SwiftUI
import UniformTypeIdentifiers

/// A disclosure document, independent of terms acceptance and diagnostic consent.
struct MenuBoxPrivacyPolicy {
    static let version = "1.0"
    let text: String
    let languageCode: String

    static func load(localizer: AppLocalizer = .current) throws -> Self {
        let code = localizer.languageCode
        guard let url = Bundle.module.url(forResource: "PrivacyPolicy", withExtension: "txt",
                                          subdirectory: nil, localization: code) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return .init(text: try String(contentsOf: url, encoding: .utf8), languageCode: code)
    }

    var suggestedFilename: String { "MenuBox-Privacy-\(languageCode).txt" }
}

struct MenuBoxPrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    private let document = Result { try MenuBoxPrivacyPolicy.load() }
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsPage {
                SettingsSection(menuBoxLocalized("Privacy Policy")) {
                    Text(menuBoxLocalized("This policy explains data processing. Reading or saving it does not change your consent or privacy choices."))
                    if case let .success(policy) = document {
                        Button(menuBoxLocalized("Save Privacy Policy…")) { save(policy) }
                    }
                    if let saveError { Text(saveError).foregroundStyle(.red) }
                }
                switch document {
                case let .success(policy):
                    SettingsSection(menuBoxLocalized("Full text")) {
                        Text(verbatim: policy.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .failure:
                    Text(menuBoxLocalized("The bundled privacy policy could not be loaded."))
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(menuBoxLocalized("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
        }
        .frame(width: 620, height: 560)
    }

    @MainActor private func save(_ policy: MenuBoxPrivacyPolicy) {
        saveError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = policy.suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try policy.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { saveError = menuBoxLocalized("The privacy policy could not be saved. Please try again.") }
    }
}

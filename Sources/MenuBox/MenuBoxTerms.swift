// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore
import MacAppSettings
import SwiftUI
import UniformTypeIdentifiers

/// App-owned, versioned terms. Reading or saving never records acceptance.
struct MenuBoxTerms {
    let text: String
    let languageCode: String

    static func load(localizer: AppLocalizer = .current) throws -> Self {
        let code = localizer.languageCode
        guard let url = Bundle.module.url(forResource: "TermsOfUse", withExtension: "txt", subdirectory: nil, localization: code) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return .init(text: try String(contentsOf: url, encoding: .utf8), languageCode: code)
    }

    var suggestedFilename: String { "MenuBox-Terms-\(languageCode).txt" }
}

/// The only settings entry is Help & Support; the sheet is a read-only document viewer.
struct MenuBoxTermsSupportSection: View {
    @State private var showsTerms = false

    var body: some View {
        SettingsSection(menuBoxLocalized("Legal Documents")) {
            SettingsRow(menuBoxLocalized("Terms of Use"),
                        detail: menuBoxLocalized("Available offline. Reading or saving these terms does not record agreement.")) {
                Button(menuBoxLocalized("Read Terms…")) { showsTerms = true }
            }
        }
        .sheet(isPresented: $showsTerms) {
            VStack(spacing: 0) {
                SettingsPage { MenuBoxTermsSettings() }
                Divider()
                HStack {
                    Spacer()
                    Button(menuBoxLocalized("Close")) { showsTerms = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding()
            }
            .frame(width: 620, height: 560)
        }
    }
}

private struct MenuBoxTermsSettings: View {
    private let document = Result { try MenuBoxTerms.load() }
    @State private var saveError: String?

    var body: some View {
        switch document {
        case let .success(terms):
            SettingsSection(menuBoxLocalized("Terms of Use")) {
                SettingsRow(menuBoxLocalized("Bundled document"),
                            detail: menuBoxLocalized("Available offline. Reading or saving these terms does not record agreement.")) {
                    Button(menuBoxLocalized("Save Terms…")) { save(terms) }
                }
                SettingsRow("GPL-3.0-only") {
                    Button(menuBoxLocalized("Show License Files…")) { showLicenses() }
                }
                if let saveError { Text(saveError).foregroundStyle(.red) }
            }
            SettingsSection(menuBoxLocalized("Full text")) {
                Text(verbatim: terms.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failure:
            SettingsSection(menuBoxLocalized("Terms of Use")) {
                Text(menuBoxLocalized("The bundled terms could not be loaded."))
            }
        }
    }

    @MainActor
    private func showLicenses() {
        saveError = nil
        guard let url = Bundle.main.url(forResource: "Legal", withExtension: nil),
              NSWorkspace.shared.open(url) else {
            saveError = menuBoxLocalized("The bundled license files could not be opened.")
            return
        }
    }

    @MainActor
    private func save(_ terms: MenuBoxTerms) {
        saveError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = terms.suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try terms.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { saveError = menuBoxLocalized("The terms could not be saved. Please try again.") }
    }
}

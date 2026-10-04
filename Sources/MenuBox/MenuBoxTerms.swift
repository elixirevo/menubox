// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore
import MacAppSettings
import MacAppOnboarding
import SwiftUI
import UniformTypeIdentifiers

/// App-owned, versioned terms. Reading or saving never records acceptance.
struct MenuBoxTerms {
    static let version = "1.1"
    static let acceptanceKey = "MenuBox.Terms.Acceptance"
    let text: String
    let languageCode: String

    static func load(localizer: AppLocalizer = .current) throws -> Self {
        let code = localizer.languageCode
        guard let url = Bundle.module.url(forResource: "TermsOfUse", withExtension: "txt", subdirectory: nil, localization: code) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return .init(text: try String(contentsOf: url, encoding: .utf8), languageCode: code)
    }

    static func agreementDocument(localizer: AppLocalizer = .current, preview: Bool = false) throws -> TermsDocument {
        let terms = try load(localizer: localizer)
        let previewNotice = localizer.string("Preview only. No real agreement is recorded.", bundle: .module)
        let summary = localizer.string("MenuBox now asks for explicit agreement to these terms before use. The app remains free under GPL-3.0-only with its existing brand policy. Crash reporting and macOS permissions are separate choices.", bundle: .module)
        return try TermsDocument(id: preview ? "menubox-preview-terms" : "menubox-terms-of-use",
            version: version, language: terms.languageCode,
            changes: preview ? previewNotice + "\n\n" + summary : summary,
            fullText: preview ? previewNotice + "\n\n" + terms.text : terms.text)
    }

    @MainActor
    static func agreement(defaults: UserDefaults = .standard) throws -> TermsAgreementModel {
        TermsAgreementModel(document: try agreementDocument(),
                            store: TermsAcceptanceStore(defaults: defaults, key: acceptanceKey))
    }

    var suggestedFilename: String { "MenuBox-Terms-\(languageCode).txt" }
}

/// The only settings entry is Help & Support; the sheet is a read-only document viewer.
struct MenuBoxTermsSupportSection: View {
    @State private var showsTerms = false
    @State private var showsPrivacy = false

    var body: some View {
        SettingsSection(menuBoxLocalized("Legal Documents")) {
            SettingsRow(menuBoxLocalized("Terms of Use"),
                        detail: menuBoxLocalized("Available offline. Reading or saving these terms does not record agreement.")) {
                Button(menuBoxLocalized("Read Terms…")) { showsTerms = true }
            }
            SettingsRow(menuBoxLocalized("Privacy Policy"),
                        detail: menuBoxLocalized("How MenuBox handles local data, crash reports, updates and support requests.")) {
                Button(menuBoxLocalized("Read Privacy Policy…")) { showsPrivacy = true }
            }
        }
        .sheet(isPresented: $showsPrivacy) { MenuBoxPrivacyPolicySheet() }
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

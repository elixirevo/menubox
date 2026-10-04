// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import Foundation
import MacAppCore
import MacAppDiagnosticsSentry

/// Only the normal app process owns diagnostics; helpers and previews never start it.
@MainActor
final class MenuBoxDiagnostics {
    let preference: CrashReportingPreference
    private(set) var isConfigured = false
    private(set) var service: SentryDiagnostics?
    private var didStart = false
    private var didPrepare = false
    private var configuration: SentryDiagnosticsConfiguration?
    private let loadConfiguration: () throws -> SentryDiagnosticsConfiguration?
    private let startService: @MainActor (SentryDiagnosticsConfiguration, CrashReportingPreference) throws -> SentryDiagnostics

    var settingsPreference: CrashReportingPreference? { isConfigured ? preference : nil }

    init(preference: CrashReportingPreference? = nil,
         loadConfiguration: @escaping () throws -> SentryDiagnosticsConfiguration? = {
             try MenuBoxDiagnostics.bundledConfiguration()
         },
         startService: @escaping @MainActor (SentryDiagnosticsConfiguration, CrashReportingPreference) throws -> SentryDiagnostics = { configuration, preference in
             let service = SentryDiagnostics(configuration: configuration)
             try service.startIfConsented(preference)
             return service
         }) {
        self.preference = preference ?? CrashReportingPreference()
        self.loadConfiguration = loadConfiguration
        self.startService = startService
    }

    nonisolated static func bundledConfiguration(appBundle: Bundle = .main) throws -> SentryDiagnosticsConfiguration? {
        try .bundled(in: .module, appBundle: appBundle)
    }

    /// Read bundled configuration for consent UI without initializing the SDK.
    func prepare() throws {
        guard !didPrepare else { return }
        configuration = try loadConfiguration()
        isConfigured = configuration != nil
        didPrepare = true
    }

    func start() throws {
        guard !didStart else { return }
        try prepare()
        guard let configuration else { return }
        // Consent is the value at process launch, even if settings change later.
        if preference.activeEnabled {
            service = try startService(configuration, preference)
        }
        didStart = true
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import MacAppCore
import MacAppOnboarding
import MacAppSettings
import XCTest
@testable import MenuBox

@MainActor
final class OnboardingIntegrationTests: XCTestCase {
    private func fixture(accepted: Bool = false) throws -> TermsAgreementModel {
        let document = try MenuBoxTerms.agreementDocument(preview: true)
        var receipt = accepted ? TermsAcceptance(document: document, acceptedAt: Date()) : nil
        return TermsAgreementModel(document: document, store: .init(read: { receipt }, write: { receipt = $0 }))
    }

    func testUsageGuidesAndMandatoryTermsComeBeforeOSSpecificPermissions() throws {
        for diskAccess: PermissionAccess? in [nil, .denied] {
            let permissions = SettingsWindowController.makePermissions(
                snapshot: .init(accessibility: false, fullDiskAccess: diskAccess),
                readDiskAccess: { .denied }, openDiskSettings: {})
            let model = try MenuBoxOnboarding.makeModel(permissions: permissions, agreement: fixture(),
                crashPreference: nil, store: .init(readCompletedVersion: { 0 }, writeCompletedVersion: { _ in }))
            XCTAssertEqual(Array(model.steps.prefix(5).map(\.id)),
                           ["welcome", "custom.arrange", "custom.box", "guide.settings", "terms"])
            XCTAssertEqual(model.steps.filter { $0.id.hasPrefix("permissions.") }.count, diskAccess == nil ? 1 : 2)
            XCTAssertTrue(model.requiresTermsAgreement)
        }
    }

    func testExplicitAgreementIsSeparateFromCompletionPermissionsAndDiagnostics() throws {
        let suite = "MenuBoxTests.Onboarding." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agreement = try MenuBoxTerms.agreement(defaults: defaults)
        var diagnosticWrites = 0
        var permissionRequests = 0
        let permissions = PermissionSettingsModel([
            .init(id: "accessibility", title: "Accessibility", detail: "Test permission", readStatus: { .notGranted },
                  request: { permissionRequests += 1 })
        ])
        let preference = CrashReportingPreference(activeEnabled: false, save: { _ in diagnosticWrites += 1 })
        func make() throws -> OnboardingModel {
            try MenuBoxOnboarding.makeModel(permissions: permissions, agreement: agreement, crashPreference: preference,
                store: MenuBoxOnboarding.completionStore(defaults: defaults, replay: false))
        }
        let model = try make()
        for _ in 0..<4 { XCTAssertFalse(model.advance()) }
        XCTAssertEqual(model.currentStep.id, "terms")
        XCTAssertFalse(model.canAdvance)
        XCTAssertFalse(model.advance())
        XCTAssertNil(defaults.object(forKey: MenuBoxTerms.acceptanceKey))
        agreement.isAcknowledged = true
        XCTAssertNil(defaults.object(forKey: MenuBoxTerms.acceptanceKey), "Checking alone is not agreement")
        XCTAssertFalse(model.advance())
        XCTAssertTrue(agreement.allowsAppUse)
        XCTAssertEqual(defaults.integer(forKey: MenuBoxOnboarding.completionKey), 0)
        XCTAssertTrue(try make().shouldPresent, "Consent is not completion")
        while !model.isLastStep { XCTAssertTrue(model.canAdvance); model.advance() }
        XCTAssertTrue(model.advance())
        XCTAssertFalse(try make().shouldPresent)
        XCTAssertEqual(diagnosticWrites, 0)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertFalse(preference.activeEnabled)
        let saved = try XCTUnwrap(defaults.data(forKey: MenuBoxTerms.acceptanceKey))
        let receipt = try JSONDecoder().decode(TermsAcceptance.self, from: saved)
        XCTAssertEqual(receipt.version, MenuBoxTerms.version)
        XCTAssertEqual(receipt.fullTextSHA256.count, 64)
        SettingsStore(defaults: defaults).resetToDefaults(preservingLoginItem: true)
        XCTAssertEqual(defaults.data(forKey: MenuBoxTerms.acceptanceKey), saved)
        XCTAssertTrue(try MenuBoxTerms.agreement(defaults: defaults).allowsAppUse)
    }

    func testCompletedOnboardingNeverGrantsAgreementAndReplayPreservesRecords() throws {
        let suite = "MenuBoxTests.Onboarding." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(12, forKey: MenuBoxOnboarding.completionKey)
        let agreement = try fixture()
        let pending = try MenuBoxOnboarding.makeModel(permissions: PermissionSettingsModel([]), agreement: agreement,
            crashPreference: nil, store: MenuBoxOnboarding.completionStore(defaults: defaults, replay: false))
        XCTAssertTrue(pending.shouldPresent)
        XCTAssertEqual(pending.currentStep.id, "terms")
        XCTAssertFalse(agreement.allowsAppUse)
        agreement.isAcknowledged = true
        XCTAssertTrue(agreement.accept())
        let receipt = agreement.acceptance
        let replay = try MenuBoxOnboarding.makeModel(permissions: PermissionSettingsModel([]), agreement: agreement,
            crashPreference: nil, store: MenuBoxOnboarding.completionStore(defaults: defaults, replay: true))
        XCTAssertTrue(replay.shouldPresent)
        XCTAssertFalse(replay.requiresTermsAgreement)
        XCTAssertFalse(replay.steps.contains { $0.id == "diagnostics" })
        while !replay.isLastStep { replay.advance() }
        XCTAssertTrue(replay.advance())
        XCTAssertEqual(defaults.integer(forKey: MenuBoxOnboarding.completionKey), 12)
        XCTAssertEqual(agreement.acceptance, receipt)
    }

    func testAppServicesStartOnlyAfterSuccessfulExplicitAcceptanceAndOnlyOnce() throws {
        let agreement = try fixture()
        let gate = MenuBoxLaunchGate(agreement: agreement)
        var starts = 0
        XCTAssertFalse(gate.startIfAllowed { starts += 1 })
        agreement.isAcknowledged = true
        XCTAssertFalse(gate.startIfAllowed { starts += 1 })
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(agreement.accept())
        XCTAssertTrue(gate.startIfAllowed { starts += 1 })
        XCTAssertTrue(gate.startIfAllowed { starts += 1 })
        XCTAssertEqual(starts, 1)
    }

    func testWrongVersionReadFailureAndWriteFailureKeepServicesBlocked() throws {
        let document = try MenuBoxTerms.agreementDocument(preview: true)
        let older = try TermsDocument(id: document.id, version: "older", language: "en", changes: "Old", fullText: "Old")
        for store in [TermsAcceptanceStore(read: { TermsAcceptance(document: older, acceptedAt: Date()) }, write: { _ in }),
                      TermsAcceptanceStore(read: { throw TermsAgreementError.invalidStoredAcceptance }, write: { _ in }),
                      TermsAcceptanceStore(read: { nil }, write: { _ in throw CocoaError(.fileWriteNoPermission) })] {
            let agreement = TermsAgreementModel(document: document, store: store)
            let gate = MenuBoxLaunchGate(agreement: agreement)
            XCTAssertFalse(gate.startIfAllowed { XCTFail("Services started without consent") })
            if agreement.hasReadError || agreement.acceptance == nil {
                agreement.isAcknowledged = true
                XCTAssertFalse(agreement.accept())
                XCTAssertFalse(gate.startIfAllowed { XCTFail("Services started after failed receipt access") })
            }
        }
    }

    func testCorruptStoredAcceptanceIsNotDiscardedOrReplaced() throws {
        let suite = "MenuBoxTests.Terms." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("corrupted", forKey: MenuBoxTerms.acceptanceKey)
        let agreement = try MenuBoxTerms.agreement(defaults: defaults)
        XCTAssertTrue(agreement.hasReadError)
        XCTAssertFalse(agreement.allowsAppUse)
        agreement.isAcknowledged = true
        XCTAssertFalse(agreement.accept())
        XCTAssertEqual(defaults.string(forKey: MenuBoxTerms.acceptanceKey), "corrupted")
    }
}

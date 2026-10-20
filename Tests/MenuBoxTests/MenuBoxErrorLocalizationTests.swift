// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import MacAppCore
import XCTest
@testable import MenuBox

final class MenuBoxErrorLocalizationTests: XCTestCase {
    private let english = AppLocalizer(selection: .english)
    private let korean = AppLocalizer(selection: .korean)

    func testEveryNativeErrorUsesTheSelectedLanguage() {
        let errors: [any MenuBoxLocalizedError] = [
            MenuBarSectionPlanner.Failure.incompleteSnapshot,
            MenuBarSectionPlanner.Failure.missingOrAmbiguousControls("display"),
            MenuBarSectionPlanner.Failure.invalidItemGeometry("display"),
            MenuBarSectionPlanner.Failure.ambiguousGeometry("display"),
            MenuBarSectionPlanner.Failure.applicationSpansBoundary("Example"),
            NativeMenuBarSnapshot.Failure.permission, NativeMenuBarSnapshot.Failure.incomplete,
            NativeMenuBarSnapshot.Failure.boundary, NativeMenuBarSnapshot.Failure.verification,
            NativeMenuBarSnapshot.Failure.restorationPending,
            NativeMenuBarPreferences.Failure.access, NativeMenuBarPreferences.Failure.schema,
            NativeMenuBarPreferences.Failure.missing("Example"), NativeMenuBarPreferences.Failure.shared("Example"),
            NativeMenuBarPreferences.Failure.concurrentChange, NativeMenuBarPreferences.Failure.write,
            NativeSystemMenuBarPreferences.Failure.unsupported("Example"), NativeSystemMenuBarPreferences.Failure.schema,
            NativeSystemMenuBarPreferences.Failure.concurrentChange, NativeSystemMenuBarPreferences.Failure.write,
            NativeMenuBarPlacement.Failure.unavailable, NativeMenuBarPlacement.Failure.ambiguous,
            NativeMenuBarPlacement.Failure.changed, NativeMenuBarPlacement.Failure.pending,
            NativeMenuBarPlacement.Failure.write
        ]
        for error in errors {
            let en = error.errorDescription(using: english)
            let ko = error.errorDescription(using: korean)
            XCTAssertFalse(en.isEmpty)
            XCTAssertNotEqual(ko, en, "\(error) must not fall back to English")
            XCTAssertNotNil(ko.range(of: "[가-힣]", options: .regularExpression), "\(error)")
            XCTAssertFalse(ko.contains("%@"))
            XCTAssertEqual(error.localizedDescription, error.errorDescription(using: .current),
                           "Foundation's error presentation must use the app language")
        }
    }

    func testInvalidGeometryDoesNotTellUserToMoveTheMarker() {
        let error = MenuBarSectionPlanner.Failure.invalidItemGeometry("display")
        XCTAssertEqual(error.errorDescription(using: english),
                       "Some menu bar icons have an invalid size or position. Wait for the menu bar to settle, then try again.")
        XCTAssertEqual(error.errorDescription(using: korean),
                       "일부 메뉴바 아이콘의 크기나 위치 정보를 올바르게 읽지 못했습니다. 메뉴바가 정리될 때까지 잠시 기다린 후 다시 시도해 주세요.")
    }

    func testDynamicAppNamesRemainLiteralInBothLanguages() {
        let name = "Example 100% %@"
        let errors: [any MenuBoxLocalizedError] = [
            MenuBarSectionPlanner.Failure.applicationSpansBoundary(name),
            NativeMenuBarPreferences.Failure.missing(name),
            NativeMenuBarPreferences.Failure.shared(name),
            NativeSystemMenuBarPreferences.Failure.unsupported(name)
        ]
        for localizer in [english, korean] {
            for error in errors {
                XCTAssertTrue(error.errorDescription(using: localizer).contains(name))
            }
        }
    }

    func testErrorChromeAndMenuFailuresHaveKoreanTranslations() {
        XCTAssertEqual(menuBoxLocalized("Couldn’t update menu bar icons", localizer: korean),
                       "메뉴바 아이콘을 변경하지 못했습니다")
        XCTAssertEqual(menuBoxLocalized("OK", localizer: korean), "확인")
        for key in [
            "Could not open %@’s menu", "Could not restore the menu bar: %@",
            "Accessibility access required", "No targets", "Unable to capture the menu bar image.",
            "No icon was selected. Please try again.", "The selected icon could not be found. Please try again.",
            "Opening menu: %@", "Could not restore the icon position", "Menu unavailable: %@",
            "Menu changed: Open it again", "Unsupported app: %@",
            "Allow Screen Recording access, then restart the app.", "Failed"
        ] {
            XCTAssertEqual(menuBoxLocalized(key, localizer: english), key)
            let translation = menuBoxLocalized(key, localizer: korean)
            XCTAssertNotEqual(translation, key)
            XCTAssertEqual(translation.components(separatedBy: "%@").count,
                           key.components(separatedBy: "%@").count, "Preserve format arguments")
        }
    }

    func testSystemLanguageUsesTheSameErrorTranslations() {
        let localizer = AppLocalizer(selection: .system, preferredLanguages: ["ko-KR", "en"])
        XCTAssertEqual(NativeMenuBarSnapshot.Failure.permission.errorDescription(using: localizer),
                       NativeMenuBarSnapshot.Failure.permission.errorDescription(using: korean))
    }
}

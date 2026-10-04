// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import MacAppCore
import XCTest
@testable import MenuBox

final class MenuBoxPrivacyPolicyTests: XCTestCase {
    func testBothLocalizedDocumentsAreCompleteAndContainNoTemplateFields() throws {
        let ko = try MenuBoxPrivacyPolicy.load(localizer: AppLocalizer(selection: .korean))
        let en = try MenuBoxPrivacyPolicy.load(localizer: AppLocalizer(selection: .english))
        XCTAssertTrue(ko.text.hasPrefix("MenuBox 개인정보 처리방침"))
        XCTAssertTrue(en.text.hasPrefix("MenuBox Privacy Policy"))
        XCTAssertTrue(ko.text.contains("방침 버전: " + MenuBoxPrivacyPolicy.version))
        XCTAssertTrue(en.text.contains("Policy version: " + MenuBoxPrivacyPolicy.version))
        XCTAssertTrue(ko.text.contains("12. 변경 안내"))
        XCTAssertTrue(en.text.contains("12. Changes"))
        XCTAssertTrue(ko.text.contains("문의 해결 후 1년 이내 삭제"))
        XCTAssertTrue(en.text.contains("within one year after resolution"))
        for document in [ko, en] {
            XCTAssertTrue(document.text.contains("elixirevo@gmail.com"))
            XCTAssertTrue(document.text.contains("Sentry"))
            XCTAssertTrue(document.text.contains("GitHub"))
            XCTAssertTrue(document.text.contains("Google"))
            XCTAssertFalse(document.text.contains("{{"))
            XCTAssertFalse(document.text.contains("Option A"))
            XCTAssertFalse(document.text.contains("선택 A"))
        }
        XCTAssertEqual(ko.suggestedFilename, "MenuBox-Privacy-ko.txt")
        XCTAssertEqual(en.suggestedFilename, "MenuBox-Privacy-en.txt")
    }

    func testSystemLanguageAndFallbackMatchSettings() throws {
        let ko = try MenuBoxPrivacyPolicy.load(localizer: AppLocalizer(selection: .system, preferredLanguages: ["ko-KR"]))
        let en = try MenuBoxPrivacyPolicy.load(localizer: AppLocalizer(selection: .system, preferredLanguages: ["fr"]))
        XCTAssertEqual(ko.languageCode, "ko")
        XCTAssertEqual(en.languageCode, "en")
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import MacAppCore
import XCTest
@testable import MenuBox

final class MenuBoxTermsTests: XCTestCase {
    func testBothLanguagesLoadCompleteAppOwnedTermsFromResources() throws {
        let korean = try MenuBoxTerms.load(localizer: AppLocalizer(selection: .korean))
        let english = try MenuBoxTerms.load(localizer: AppLocalizer(selection: .english))
        XCTAssertTrue(korean.text.hasPrefix("MenuBox 이용약관"))
        XCTAssertTrue(english.text.hasPrefix("MenuBox Terms of Use"))
        XCTAssertTrue(korean.text.contains("약관 버전: 1.1"))
        XCTAssertTrue(english.text.contains("Terms version: 1.1"))
        XCTAssertTrue(korean.text.contains("제13조 준거법, 분쟁 및 언어"))
        XCTAssertTrue(english.text.contains("13. Governing law, disputes, and language"))
        for document in [korean, english] {
            XCTAssertTrue(document.text.contains("elixirevo@gmail.com"))
            XCTAssertTrue(document.text.contains("GPL-3.0-only"))
            XCTAssertTrue(document.text.contains("Contents/Resources/Legal"))
            XCTAssertFalse(document.text.contains("{{"), "Never ship unresolved template fields")
            XCTAssertFalse(document.text.contains("Option A"))
            XCTAssertFalse(document.text.contains("선택 A"))
        }
        XCTAssertEqual(korean.suggestedFilename, "MenuBox-Terms-ko.txt")
        XCTAssertEqual(english.suggestedFilename, "MenuBox-Terms-en.txt")
    }

    func testSystemLanguageUsesSameResolutionAsSettings() throws {
        let korean = try MenuBoxTerms.load(localizer: AppLocalizer(selection: .system, preferredLanguages: ["ko-KR", "en"]))
        let fallback = try MenuBoxTerms.load(localizer: AppLocalizer(selection: .system, preferredLanguages: ["fr"]))
        XCTAssertEqual(korean.languageCode, "ko")
        XCTAssertEqual(fallback.languageCode, "en")
        XCTAssertTrue(korean.text.hasPrefix("MenuBox 이용약관"))
        XCTAssertTrue(fallback.text.hasPrefix("MenuBox Terms of Use"))
    }
}

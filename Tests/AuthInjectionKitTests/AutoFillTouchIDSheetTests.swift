import XCTest
@testable import AuthInjectionKit

final class AutoFillTouchIDSheetTests: XCTestCase {
    private func b(_ title: String?, subrole: String? = nil) -> ButtonInfo {
        ButtonInfo(subrole: subrole, title: title, frame: .zero)
    }

    func testSheetIdentifierMatchesSafari() {
        // Captured from Safari's AutoFill Touch ID sheet (AXSheet AXIdentifier).
        XCTAssertEqual(AutoFillTouchIDSheet.sheetIdentifier, "AutoFillAuthenticationSheet")
    }

    func testPicksEnterPasswordAsCapturedFromSafari() {
        // Real order from the AX dump: "Enter Password…" then "Cancel".
        // The old findUsePasswordButton took buttons.last → Cancel. Must pick index 0.
        XCTAssertEqual(AutoFillTouchIDSheet.pickPasswordButton(from: [b("Enter Password…"), b("Cancel")]), 0)
    }

    func testPicksEllipsisButtonWhenCancelTitleUnknown() {
        // Locale whose Cancel title isn't in the cancel list: the "…" suffix
        // (macOS convention for "opens more UI") still identifies the password button.
        XCTAssertEqual(AutoFillTouchIDSheet.pickPasswordButton(from: [b("Peida…"), b("Loobu")]), 0)
    }

    func testAcceptsThreeDotEllipsis() {
        XCTAssertEqual(AutoFillTouchIDSheet.pickPasswordButton(from: [b("Cancel"), b("Use Password...")]), 1)
    }

    func testExcludesCancelSubrole() {
        XCTAssertEqual(AutoFillTouchIDSheet.pickPasswordButton(from: [b("X", subrole: "AXCancelButton"), b("Y")]), 1)
    }

    func testNilWhenAmbiguous() {
        // Two non-cancel buttons, neither with an ellipsis → don't guess.
        XCTAssertNil(AutoFillTouchIDSheet.pickPasswordButton(from: [b("Foo"), b("Bar")]))
        // Two ellipsis buttons → don't guess.
        XCTAssertNil(AutoFillTouchIDSheet.pickPasswordButton(from: [b("A…"), b("B…"), b("Cancel")]))
    }

    func testNilWhenOnlyCancelOrEmpty() {
        XCTAssertNil(AutoFillTouchIDSheet.pickPasswordButton(from: []))
        XCTAssertNil(AutoFillTouchIDSheet.pickPasswordButton(from: [b("Cancel")]))
    }
}

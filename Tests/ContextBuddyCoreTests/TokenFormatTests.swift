import XCTest
@testable import ContextBuddyCore

// Issue #47: the popover token row and the status line abbreviate the same way.
// A 1M window is "1M", never "1000k".
final class TokenFormatTests: XCTestCase {
    func testSubThousandPrintsInFull() {
        XCTAssertEqual(TokenFormat.short(0), "0")
        XCTAssertEqual(TokenFormat.short(999), "999")
    }

    func testThousandsTruncateToK() {
        XCTAssertEqual(TokenFormat.short(1_000), "1k")
        XCTAssertEqual(TokenFormat.short(47_823), "47k")
        XCTAssertEqual(TokenFormat.short(176_474), "176k")
        XCTAssertEqual(TokenFormat.short(200_000), "200k")
        XCTAssertEqual(TokenFormat.short(999_999), "999k")
    }

    func testMillionsPrintAsM() {
        XCTAssertEqual(TokenFormat.short(1_000_000), "1M")
        XCTAssertEqual(TokenFormat.short(1_500_000), "1.5M")
        XCTAssertEqual(TokenFormat.short(1_049_999), "1M")
        XCTAssertEqual(TokenFormat.short(2_000_000), "2M")
    }
}

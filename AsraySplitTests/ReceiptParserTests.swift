import XCTest
@testable import AsraySplit

final class ReceiptParserTests: XCTestCase {
    func testParsesReceiptMath() {
        let draft = ReceiptVisionService.parse("CAFE MARGO\nLatte 5.50\nToast 8.00\nSubtotal 13.50\nTax 1.21\nTOTAL 14.71")
        XCTAssertEqual(draft.items.count, 2)
        XCTAssertEqual(draft.subtotal, 13.50, accuracy: 0.001)
        XCTAssertEqual(draft.total, 14.71, accuracy: 0.001)
    }
}

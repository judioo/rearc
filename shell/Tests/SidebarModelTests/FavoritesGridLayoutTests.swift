import XCTest
@testable import SidebarModel

final class FavoritesGridLayoutTests: XCTestCase {
    func testDefaultWidthWrapsAtFour() {
        let grid = FavoritesGridLayout(itemCount: 9, availableWidth: 228 - 16)
        XCTAssertEqual(grid.columns, 4)
        XCTAssertEqual(grid.rows, 3)
        XCTAssertEqual(grid.tileWidth * 4 + FavoritesGridLayout.spacing * 3, 212)
        XCTAssertEqual(grid.height, FavoritesGridLayout.tileHeight * 3 + FavoritesGridLayout.spacing * 2)
    }

    func testEmptyAndPartialRows() {
        XCTAssertEqual(FavoritesGridLayout(itemCount: 0, availableWidth: 212).height, 0)
        let one = FavoritesGridLayout(itemCount: 1, availableWidth: 212)
        XCTAssertEqual(one.columns, 1)
        XCTAssertEqual(one.tileWidth, 212)
        XCTAssertEqual(FavoritesGridLayout(itemCount: 4, availableWidth: 212).rows, 1)
        XCTAssertEqual(FavoritesGridLayout(itemCount: 5, availableWidth: 212).rows, 2)
    }

    func testNarrowAndWideWidthsStayWithinBounds() {
        for width: Double in [0, 30, 89, 90, 137, 138, 185, 186, 212, 500] {
            let grid = FavoritesGridLayout(itemCount: 13, availableWidth: width)
            XCTAssertTrue((1...4).contains(grid.columns))
            XCTAssertGreaterThanOrEqual(grid.tileWidth, 0)
            XCTAssertLessThanOrEqual(grid.tileWidth * Double(grid.columns) + Double(grid.columns - 1) * FavoritesGridLayout.spacing, width)
        }
        XCTAssertEqual(FavoritesGridLayout(itemCount: 5, availableWidth: 137).columns, 2)
        XCTAssertEqual(FavoritesGridLayout(itemCount: 5, availableWidth: 138).columns, 3)
    }

    func testOnlyDoubleClicksBelowAllRowsOpenNewTab() {
        XCTAssertTrue(SidebarEmptySpaceClick.opensNewTab(clickCount: 2, rowIndex: -1, y: 101, rowsBottom: 100))
        XCTAssertFalse(SidebarEmptySpaceClick.opensNewTab(clickCount: 1, rowIndex: -1, y: 101, rowsBottom: 100))
        XCTAssertFalse(SidebarEmptySpaceClick.opensNewTab(clickCount: 2, rowIndex: 4, y: 101, rowsBottom: 100))
        XCTAssertFalse(SidebarEmptySpaceClick.opensNewTab(clickCount: 2, rowIndex: -1, y: 99, rowsBottom: 100))
        XCTAssertFalse(SidebarEmptySpaceClick.opensNewTab(clickCount: 3, rowIndex: -1, y: 101, rowsBottom: 100))
    }
}

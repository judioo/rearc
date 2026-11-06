import Foundation

public enum SidebarEmptySpaceClick {
    public static func opensNewTab(clickCount: Int, rowIndex: Int, y: Double, rowsBottom: Double) -> Bool {
        clickCount == 2 && rowIndex == -1 && y >= rowsBottom
    }
}

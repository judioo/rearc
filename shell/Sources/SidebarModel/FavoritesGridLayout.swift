import Foundation

/// Favorites share the available width, wrapping after at most four tiles.
public struct FavoritesGridLayout: Equatable {
    public let columns: Int
    public let rows: Int
    public let tileWidth: Double
    public let height: Double
    public static let spacing: Double = 6
    public static let tileHeight: Double = 42
    private static let minimumTileWidth: Double = 42

    public init(itemCount: Int, availableWidth: Double) {
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        let capacity = min(4, max(1, floor((width + Self.spacing) / (Self.minimumTileWidth + Self.spacing))))
        columns = min(Int(capacity), max(1, itemCount))
        rows = itemCount > 0 ? (itemCount - 1) / columns + 1 : 0
        tileWidth = max(0, (width - Double(columns - 1) * Self.spacing) / Double(columns))
        height = Double(rows) * Self.tileHeight + Double(max(0, rows - 1)) * Self.spacing
    }
}

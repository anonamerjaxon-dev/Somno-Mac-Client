import Foundation

/// Pure, provider-independent grid drawing algorithms used by the editor tools
/// and by `GameOfLifeProvider`. Kept free of Metal/AppKit so the algorithms can
/// be unit-tested headlessly.
public enum BrushTool {

    /// Bresenham line cells from `(fromRow, fromCol)` to `(toRow, toCol)`,
    /// inclusive of both endpoints.
    public static func lineCells(
        fromRow: Int, fromCol: Int,
        toRow: Int, toCol: Int
    ) -> [(row: Int, col: Int)] {
        var result: [(row: Int, col: Int)] = []
        var r = fromRow
        var c = fromCol
        let dr = abs(toRow - fromRow)
        let dc = abs(toCol - fromCol)
        let stepRow = fromRow < toRow ? 1 : -1
        let stepCol = fromCol < toCol ? 1 : -1
        var err = dr - dc

        while true {
            result.append((row: r, col: c))
            if r == toRow, c == toCol { break }
            let e2 = 2 * err
            if e2 > -dc { err -= dc; r += stepRow }
            if e2 < dr { err += dr; c += stepCol }
        }
        return result
    }

    /// Every cell inside the axis-aligned rectangle spanned by the two corners,
    /// in row-major order.
    public static func rectCells(
        minRow: Int, minCol: Int,
        maxRow: Int, maxCol: Int
    ) -> [(row: Int, col: Int)] {
        let r0 = min(minRow, maxRow)
        let r1 = max(minRow, maxRow)
        let c0 = min(minCol, maxCol)
        let c1 = max(minCol, maxCol)
        var result: [(row: Int, col: Int)] = []
        result.reserveCapacity((r1 - r0 + 1) * (c1 - c0 + 1))
        for r in r0...r1 {
            for c in c0...c1 {
                result.append((row: r, col: c))
            }
        }
        return result
    }

    /// 4-connected flood fill: every cell 4-connected to the start cell that
    /// holds `target` in `grid`, bounded by `width` × `height`. Returns the
    /// visited cells in visit order (empty when the start cell is out of bounds
    /// or already holds a different value).
    public static func floodFillCells(
        _ grid: [UInt8],
        width: Int,
        height: Int,
        startRow: Int,
        startCol: Int,
        target: UInt8
    ) -> [(row: Int, col: Int)] {
        guard width > 0, height > 0,
              startRow >= 0, startRow < height,
              startCol >= 0, startCol < width,
              startRow * width + startCol < grid.count,
              grid[startRow * width + startCol] == target
        else { return [] }

        var seen = [Bool](repeating: false, count: width * height)
        var stack: [(row: Int, col: Int)] = [(startRow, startCol)]
        var visited: [(row: Int, col: Int)] = []

        while let next = stack.popLast() {
            let r = next.row
            let c = next.col
            guard r >= 0, r < height, c >= 0, c < width else { continue }
            let index = r * width + c
            guard !seen[index], grid[index] == target else { continue }
            seen[index] = true
            visited.append(next)
            stack.append((row: r - 1, col: c))
            stack.append((row: r + 1, col: c))
            stack.append((row: r, col: c - 1))
            stack.append((row: r, col: c + 1))
        }
        return visited
    }

    /// Number of alive cells in the grid.
    public static func aliveCount(in grid: [UInt8]) -> Int {
        grid.reduce(into: 0) { total, value in if value != 0 { total += 1 } }
    }

    // MARK: - Pointer-based helpers
    //
    // `GameOfLifeProvider` mutates cells through an `MTLBuffer`'s raw pointer, so
    // the same primitives are exposed against `UnsafeMutablePointer<UInt8>`.
    // Routing both callers through this file keeps the tested Bresenham and
    // seeding code identical to the code the app actually runs.

    public static func setCell(
        _ cells: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        row: Int,
        col: Int,
        alive: Bool
    ) {
        guard width > 0, height > 0,
              row >= 0, row < height,
              col >= 0, col < width
        else { return }
        cells[row * width + col] = alive ? 1 : 0
    }

    /// Draws a Bresenham line into `cells`, clipped to the `width` × `height` grid.
    public static func drawLine(
        _ cells: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        fromRow: Int,
        fromCol: Int,
        toRow: Int,
        toCol: Int,
        alive: Bool
    ) {
        guard width > 0, height > 0 else { return }
        let value: UInt8 = alive ? 1 : 0
        for cell in lineCells(fromRow: fromRow, fromCol: fromCol, toRow: toRow, toCol: toCol) {
            guard cell.row >= 0, cell.row < height,
                  cell.col >= 0, cell.col < width else { continue }
            cells[cell.row * width + cell.col] = value
        }
    }

    /// Fills the rectangle into `cells`, clipped to the `width` × `height` grid.
    public static func fillRect(
        _ cells: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        minRow: Int,
        minCol: Int,
        maxRow: Int,
        maxCol: Int,
        alive: Bool
    ) {
        guard width > 0, height > 0 else { return }
        let r0 = max(0, min(minRow, maxRow))
        let r1 = min(height - 1, max(minRow, maxRow))
        let c0 = max(0, min(minCol, maxCol))
        let c1 = min(width - 1, max(minCol, maxCol))
        guard r0 <= r1, c0 <= c1 else { return }

        let value: UInt8 = alive ? 1 : 0
        for cell in rectCells(minRow: r0, minCol: c0, maxRow: r1, maxCol: c1) {
            cells[cell.row * width + cell.col] = value
        }
    }

    /// Whole-grid random seed at the given density (0…1), clamped.
    ///
    /// This is the single seeding algorithm in the codebase: `randomSeed` below
    /// and `GameOfLifeProvider.randomSeed(density:)` both call it, so the density
    /// that the tests pin is the density the desktop renders.
    public static func seedGrid(
        _ cells: UnsafeMutablePointer<UInt8>,
        count: Int,
        density: Double,
        using generator: inout RandomNumberGenerator
    ) {
        guard count > 0 else { return }
        let clamped = density.isFinite ? min(max(density, 0), 1) : 0.5

        // Density 1.0 is a special case: `UInt8(clamped * 256)` would be 256,
        // which does not fit in a UInt8 and previously wrapped to 0 (filling
        // nothing). Filling explicitly keeps a "100%" seed actually full.
        if clamped >= 1 {
            for index in 0..<count {
                cells[index] = 1
            }
            return
        }

        // Integer threshold over a 0…255 draw: P(alive) = threshold / 256.
        let threshold = UInt8(clamped * 256)
        for index in 0..<count {
            cells[index] = UInt8.random(in: 0...255, using: &generator) < threshold ? 1 : 0
        }
    }

    // MARK: - Mutating helpers

    public static func setCell(
        _ grid: inout [UInt8],
        width: Int,
        height: Int,
        row: Int,
        col: Int,
        alive: Bool
    ) {
        guard width > 0, height > 0,
              row >= 0, row < height,
              col >= 0, col < width,
              row * width + col < grid.count
        else { return }
        grid[row * width + col] = alive ? 1 : 0
    }

    @discardableResult
    public static func toggleCell(
        _ grid: inout [UInt8],
        width: Int,
        height: Int,
        row: Int,
        col: Int
    ) -> Bool {
        guard width > 0, height > 0,
              row >= 0, row < height,
              col >= 0, col < width,
              row * width + col < grid.count
        else { return false }
        let index = row * width + col
        let nowAlive = grid[index] == 0
        grid[index] = nowAlive ? 1 : 0
        return nowAlive
    }

    /// Draws a Bresenham line, clipped to the grid bounds.
    public static func drawLine(
        _ grid: inout [UInt8],
        width: Int,
        height: Int,
        fromRow: Int,
        fromCol: Int,
        toRow: Int,
        toCol: Int,
        alive: Bool
    ) {
        for cell in lineCells(fromRow: fromRow, fromCol: fromCol, toRow: toRow, toCol: toCol) {
            setCell(&grid, width: width, height: height,
                    row: cell.row, col: cell.col, alive: alive)
        }
    }

    /// Fills an axis-aligned rectangle, clipped to the grid bounds.
    public static func fillRect(
        _ grid: inout [UInt8],
        width: Int,
        height: Int,
        minRow: Int,
        minCol: Int,
        maxRow: Int,
        maxCol: Int,
        alive: Bool
    ) {
        let r0 = max(0, min(minRow, maxRow))
        let r1 = min(height - 1, max(minRow, maxRow))
        let c0 = max(0, min(minCol, maxCol))
        let c1 = min(width - 1, max(minCol, maxCol))
        guard height > 0, width > 0, r0 <= r1, c0 <= c1 else { return }
        for r in r0...r1 {
            for c in c0...c1 {
                let index = r * width + c
                guard index < grid.count else { continue }
                grid[index] = alive ? 1 : 0
            }
        }
    }

    /// Fills the connected region containing the start cell with `alive`.
    ///
    /// The region is delimited by cells that already differ from the start
    /// cell, so filling an all-dead area makes it fully alive and filling an
    /// all-alive area with `alive: false` clears it. A no-op fill (region
    /// already equals the requested value) leaves the grid untouched.
    public static func floodFill(
        _ grid: inout [UInt8],
        width: Int,
        height: Int,
        startRow: Int,
        startCol: Int,
        alive: Bool
    ) {
        guard width > 0, height > 0,
              startRow >= 0, startRow < height,
              startCol >= 0, startCol < width,
              startRow * width + startCol < grid.count
        else { return }

        let target = grid[startRow * width + startCol]
        guard (target != 0) != alive else { return }

        let replacement: UInt8 = alive ? 1 : 0
        for cell in floodFillCells(grid, width: width, height: height,
                                   startRow: startRow, startCol: startCol, target: target) {
            let index = cell.row * width + cell.col
            guard index < grid.count else { continue }
            grid[index] = replacement
        }
    }

    /// Whole-grid random seed at the given density (0…1), clamped.
    public static func randomSeed(
        width: Int,
        height: Int,
        density: Double,
        using generator: inout RandomNumberGenerator
    ) -> [UInt8] {
        let count = max(0, width) * max(0, height)
        var grid = [UInt8](repeating: 0, count: count)
        grid.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            seedGrid(base, count: count, density: density, using: &generator)
        }
        return grid
    }

    /// Reshapes `source` from `sourceWidth` × `sourceHeight` into
    /// `width` × `height`, keeping the top-left cells that still fit and
    /// padding with dead cells. Used when a canvas is resized.
    public static func resizedGrid(
        _ source: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        let targetWidth = max(0, width)
        let targetHeight = max(0, height)
        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        guard targetWidth > 0, targetHeight > 0,
              sourceWidth > 0, sourceHeight > 0,
              source.count >= sourceWidth * sourceHeight else { return result }

        let copyRows = min(sourceHeight, targetHeight)
        let copyCols = min(sourceWidth, targetWidth)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                result[r * targetWidth + c] = source[r * sourceWidth + c]
            }
        }
        return result
    }
}
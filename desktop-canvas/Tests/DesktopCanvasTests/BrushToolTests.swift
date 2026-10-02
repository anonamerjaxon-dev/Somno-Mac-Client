import XCTest
@testable import DesktopCanvas

final class BrushToolTests: XCTestCase {

    // MARK: - Line

    func testLineHorizontal() {
        let cells = BrushTool.lineCells(fromRow: 2, fromCol: 1, toRow: 2, toCol: 5)
        XCTAssertEqual(cells.count, 5)
        XCTAssertEqual(cells.map(\.col), [1, 2, 3, 4, 5])
        XCTAssertTrue(cells.allSatisfy { $0.row == 2 })
    }

    func testLineVertical() {
        let cells = BrushTool.lineCells(fromRow: 0, fromCol: 3, toRow: 4, toCol: 3)
        XCTAssertEqual(cells.map(\.row), [0, 1, 2, 3, 4])
        XCTAssertTrue(cells.allSatisfy { $0.col == 3 })
    }

    func testLineDiagonalIsFourConnected() {
        let cells = BrushTool.lineCells(fromRow: 0, fromCol: 0, toRow: 3, toCol: 3)
        XCTAssertEqual(cells.count, 4)
        for (index, cell) in cells.enumerated() {
            XCTAssertEqual(cell.row, index)
            XCTAssertEqual(cell.col, index)
        }
    }

    func testLineEndpointsAreInclusiveAndOrderIndependent() {
        let forward = BrushTool.lineCells(fromRow: 0, fromCol: 0, toRow: 5, toCol: 2)
        let backward = BrushTool.lineCells(fromRow: 5, fromCol: 2, toRow: 0, toCol: 0)
        XCTAssertEqual(forward.count, backward.count)
        XCTAssertEqual(forward.first?.row, 0)
        XCTAssertEqual(forward.first?.col, 0)
        XCTAssertEqual(forward.last?.row, 5)
        XCTAssertEqual(forward.last?.col, 2)
        XCTAssertEqual(Set(forward.map { "\($0.row),\($0.col)" }),
                       Set(backward.map { "\($0.row),\($0.col)" }))
    }

    func testSingleCellLine() {
        let cells = BrushTool.lineCells(fromRow: 7, fromCol: 7, toRow: 7, toCol: 7)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].row, 7)
        XCTAssertEqual(cells[0].col, 7)
    }

    func testLineStepsByAtMostOneCellPerAxis() {
        let cells = BrushTool.lineCells(fromRow: 10, fromCol: 1, toRow: 2, toCol: 14)
        for index in 1..<cells.count {
            let dr = abs(cells[index].row - cells[index - 1].row)
            let dc = abs(cells[index].col - cells[index - 1].col)
            XCTAssertLessThanOrEqual(dr, 1)
            XCTAssertLessThanOrEqual(dc, 1)
            XCTAssertTrue(dr == 1 || dc == 1, "Bresenham line must not stall")
        }
    }

    // MARK: - Rect

    func testRectCellsNormalizesCorners() {
        let cells = BrushTool.rectCells(minRow: 4, minCol: 1, maxRow: 1, maxCol: 3)
        XCTAssertEqual(cells.count, 12)
        XCTAssertEqual(cells.first?.row, 1)
        XCTAssertEqual(cells.first?.col, 1)
        XCTAssertEqual(cells.last?.row, 4)
        XCTAssertEqual(cells.last?.col, 3)
    }

    func testRectCellsIsRowMajor() {
        let cells = BrushTool.rectCells(minRow: 0, minCol: 0, maxRow: 1, maxCol: 1)
        XCTAssertEqual(cells.map { "\($0.row),\($0.col)" }, ["0,0", "0,1", "1,0", "1,1"])
    }

    func testRectCellsSingleCell() {
        let cells = BrushTool.rectCells(minRow: 2, minCol: 2, maxRow: 2, maxCol: 2)
        XCTAssertEqual(cells.count, 1)
    }

    // MARK: - Flood fill

    private func gridFrom(_ rows: [[UInt8]]) -> [UInt8] {
        rows.flatMap { $0 }
    }

    func testFloodFillStopsAtWalls() {
        var grid = gridFrom([
            [0, 0, 0],
            [0, 1, 0],
            [0, 0, 0]
        ])
        BrushTool.floodFill(&grid, width: 3, height: 3, startRow: 0, startCol: 0, alive: true)
        // The dead ring fills; the alive centre is a different value, so it walls the region off.
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 9)
        XCTAssertEqual(grid[4], 1)
    }

    func testFloodFillUsesFourConnectivity() {
        var grid = gridFrom([
            [0, 1, 0],
            [1, 0, 1],
            [0, 1, 0]
        ])
        BrushTool.floodFill(&grid, width: 3, height: 3, startRow: 1, startCol: 1, alive: true)
        // Only the centre is 4-connected to itself; the diagonals are walls.
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 5)
    }

    func testFloodFillOnDeadRegionFills() {
        var grid = gridFrom([
            [0, 0, 0],
            [0, 0, 0],
            [0, 0, 0]
        ])
        BrushTool.floodFill(&grid, width: 3, height: 3, startRow: 1, startCol: 1, alive: true)
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 9)
    }

    func testFloodFillOnAliveRegionKills() {
        var grid = [UInt8](repeating: 1, count: 9)
        BrushTool.floodFill(&grid, width: 3, height: 3, startRow: 1, startCol: 1, alive: false)
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 0)
    }

    func testFloodFillOutOfBoundsIsNoOp() {
        var grid = [UInt8](repeating: 0, count: 9)
        BrushTool.floodFill(&grid, width: 3, height: 3, startRow: -1, startCol: 0, alive: true)
        BrushTool.floodFill(&grid, width: 3, height: 3, startRow: 0, startCol: 9, alive: true)
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 0)
    }

    func testFloodFillCellsTerminatesOnFullyAliveGrid() {
        let full = [UInt8](repeating: 1, count: 16)
        let cells = BrushTool.floodFillCells(full, width: 4, height: 4, startRow: 0, startCol: 0, target: 1)
        XCTAssertEqual(cells.count, 16)
    }

    func testFloodFillCellsIsEmptyWhenStartValueDiffers() {
        let dead = [UInt8](repeating: 0, count: 16)
        XCTAssertTrue(BrushTool.floodFillCells(dead, width: 4, height: 4, startRow: 0, startCol: 0, target: 1).isEmpty)
    }

    // MARK: - Mutating helpers

    func testDrawLineClipsToGridBounds() {
        var grid = [UInt8](repeating: 0, count: 25)
        BrushTool.drawLine(&grid, width: 5, height: 5,
                           fromRow: -3, fromCol: -3, toRow: 1, toCol: 1, alive: true)
        // The line runs (-3,-3) -> (1,1); only (0,0) and (1,1) are inside a 5x5 grid.
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 2)
        XCTAssertEqual(grid[0], 1)
        XCTAssertEqual(grid[1 * 5 + 1], 1)
    }

    func testFillRectClipsToGridBounds() {
        var grid = [UInt8](repeating: 0, count: 25)
        BrushTool.fillRect(&grid, width: 5, height: 5,
                           minRow: -2, minCol: 3, maxRow: 10, maxCol: 10, alive: true)
        // Rows 0...4 and columns 3...4 survive clipping: 5 x 2 = 10 cells.
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 10)
    }

    func testFillRectEraserClears() {
        var grid = [UInt8](repeating: 1, count: 16)
        BrushTool.fillRect(&grid, width: 4, height: 4,
                           minRow: 1, minCol: 1, maxRow: 2, maxCol: 2, alive: false)
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 16 - 4)
    }

    func testSetCellAndToggle() {
        var grid = [UInt8](repeating: 0, count: 9)
        BrushTool.setCell(&grid, width: 3, height: 3, row: 1, col: 1, alive: true)
        XCTAssertEqual(grid[4], 1)
        // toggleCell reports the value the cell ended up with: 1 -> dead.
        XCTAssertFalse(BrushTool.toggleCell(&grid, width: 3, height: 3, row: 1, col: 1))
        XCTAssertEqual(grid[4], 0)
        XCTAssertTrue(BrushTool.toggleCell(&grid, width: 3, height: 3, row: 1, col: 1))
        XCTAssertFalse(BrushTool.toggleCell(&grid, width: 3, height: 3, row: 5, col: 5))
    }

    func testSetCellRejectsOutOfBoundsWithoutCrashing() {
        var grid = [UInt8](repeating: 0, count: 9)
        BrushTool.setCell(&grid, width: 3, height: 3, row: -1, col: 0, alive: true)
        BrushTool.setCell(&grid, width: 3, height: 3, row: 3, col: 3, alive: true)
        BrushTool.setCell(&grid, width: 0, height: 0, row: 0, col: 0, alive: true)
        XCTAssertEqual(BrushTool.aliveCount(in: grid), 0)
    }

    // MARK: - Random seed

    func testRandomSeedDensityClamping() {
        var generator: any RandomNumberGenerator = SystemRandomNumberGenerator()

        let full = BrushTool.randomSeed(width: 64, height: 64, density: 5.0, using: &generator)
        XCTAssertEqual(BrushTool.aliveCount(in: full), 4096, "Density > 1 clamps to 1")

        let empty = BrushTool.randomSeed(width: 64, height: 64, density: -3.0, using: &generator)
        XCTAssertEqual(BrushTool.aliveCount(in: empty), 0, "Density < 0 clamps to 0")

        let nan = BrushTool.randomSeed(width: 64, height: 64, density: .nan, using: &generator)
        XCTAssertEqual(nan.count, 4096)
        XCTAssertGreaterThan(BrushTool.aliveCount(in: nan), 0, "NaN density falls back to 0.5")
    }

    func testRandomSeedHalfDensityIsRoughlyHalf() {
        var generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
        let grid = BrushTool.randomSeed(width: 100, height: 100, density: 0.5, using: &generator)
        let alive = BrushTool.aliveCount(in: grid)
        XCTAssertGreaterThan(alive, 4_000)
        XCTAssertLessThan(alive, 6_000)
    }

    func testRandomSeedOnDegenerateGridIsEmpty() {
        var generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
        XCTAssertTrue(BrushTool.randomSeed(width: 0, height: 10, density: 1, using: &generator).isEmpty)
        XCTAssertTrue(BrushTool.randomSeed(width: 10, height: 0, density: 1, using: &generator).isEmpty)
    }

    // MARK: - Resize

    func testResizedGridPreservesTopLeftContent() {
        let original: [UInt8] = [1, 0, 1,
                                 0, 1, 0,
                                 1, 1, 1]
        let grown = BrushTool.resizedGrid(original, sourceWidth: 3, sourceHeight: 3, width: 4, height: 3)
        XCTAssertEqual(grown.count, 12)
        // The new fourth column is padding; the first three columns are untouched.
        XCTAssertEqual(grown, [1, 0, 1, 0,
                               0, 1, 0, 0,
                               1, 1, 1, 0])
    }

    func testResizedGridTruncatesWhenShrinking() {
        let original: [UInt8] = [1, 1, 1, 1,
                                 1, 1, 1, 1,
                                 1, 1, 1, 1,
                                 1, 1, 1, 1]
        let shrunk = BrushTool.resizedGrid(original, sourceWidth: 4, sourceHeight: 4, width: 2, height: 2)
        XCTAssertEqual(shrunk, [1, 1, 1, 1])
    }

    func testResizedGridHandlesEmptyAndInvalidInput() {
        XCTAssertEqual(
            BrushTool.resizedGrid([], sourceWidth: 0, sourceHeight: 0, width: 3, height: 3),
            [0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertTrue(BrushTool.resizedGrid([1, 1, 1], sourceWidth: 3, sourceHeight: 1, width: 0, height: 0).isEmpty)
        // A grid shorter than its declared shape yields an all-dead target.
        XCTAssertEqual(
            BrushTool.resizedGrid([1, 1], sourceWidth: 4, sourceHeight: 4, width: 2, height: 2),
            [0, 0, 0, 0]
        )
    }

    // MARK: - Cellular automaton stepping

    /// Reference implementation of the Metal compute kernel: wrap-around
    /// neighbours, birth/survival bit masks.
    private func step(_ input: [UInt8], width: Int, height: Int, rule: RuleSet) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                var neighbors = 0
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let r = (row + dr + height) % height
                        let c = (col + dc + width) % width
                        if input[r * width + c] != 0 { neighbors += 1 }
                    }
                }
                let alive = input[row * width + col] != 0
                let survives = rule.survival.contains(neighbors)
                let born = rule.birth.contains(neighbors)
                output[row * width + col] = (alive ? survives : born) ? 1 : 0
            }
        }
        return output
    }

    func testConwayBlockIsStillLife() {
        let grid: [UInt8] = [
            0, 0, 0, 0,
            0, 1, 1, 0,
            0, 1, 1, 0,
            0, 0, 0, 0
        ]
        let next = step(grid, width: 4, height: 4, rule: .conway)
        XCTAssertEqual(next, grid, "A 2×2 block is a Conway still life")
    }

    func testConwayBlinkerOscillates() {
        // A 3-wide world wraps the blinker onto itself, so the period-2 behaviour
        // only shows on a world larger than the blinker.
        let horizontal: [UInt8] = [
            0, 0, 0, 0, 0,
            1, 1, 1, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ]
        let vertical = step(horizontal, width: 5, height: 5, rule: .conway)
        // The two end cells die (0 neighbours), the middle survives (2), and the
        // cells directly above and below the middle are born (3).
        XCTAssertEqual(vertical, [
            0, 1, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ], "A horizontal blinker becomes a vertical one")
        XCTAssertEqual(step(vertical, width: 5, height: 5, rule: .conway), horizontal,
                       "A vertical blinker becomes a horizontal one again")
    }

    func testHighLifeReplicatesWhereConwayDoesNot() {
        // A lonely cell in a 3x3 world: the centre dies (no neighbours) and no
        // dead cell sees three neighbours, so both rules reach an empty world.
        let single: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0, 0]
        let dead = [UInt8](repeating: 0, count: 9)
        XCTAssertEqual(step(single, width: 3, height: 3, rule: .conway), dead)
        XCTAssertEqual(step(single, width: 3, height: 3, rule: .highLife), dead)

        // Six live neighbours around the dead cell at (1, 1). A 5x5 world keeps
        // (1, 1) away from every edge, so the wrap-around cannot inflate the count.
        let sixNeighbour: [UInt8] = [
            1, 1, 0, 0, 0,
            1, 0, 1, 0, 0,
            1, 1, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ]
        let centre = 1 * 5 + 1
        XCTAssertEqual(step(sixNeighbour, width: 5, height: 5, rule: .conway)[centre], 0,
                       "Conway: a dead cell with six neighbours stays dead")
        XCTAssertEqual(step(sixNeighbour, width: 5, height: 5, rule: .highLife)[centre], 1,
                       "HighLife: a dead cell with six neighbours is born")
    }

    func testWrapAroundNeighboursAtEdges() {
        // Single alive cell in a 1×1 world has no neighbours, so it dies.
        let lonely = step([1], width: 1, height: 1, rule: .conway)
        XCTAssertEqual(lonely, [0])
    }

    func testEmptyGridStaysEmpty() {
        let empty = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(step(empty, width: 8, height: 8, rule: .conway), empty)
    }

    func testSeedsRuleBlowsUpFromTwoAdjacentCells() {
        let seed: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 0, 0]
        let next = step(seed, width: 3, height: 3, rule: .seeds)
        // A new cell is born exactly on the two cells that see both seeds.
        XCTAssertEqual(next[0], 0, "Seed survives on 1 neighbour? no")
        XCTAssertEqual(next[1], 0)
        XCTAssertEqual(next[3], 1, "Cell below-left sees both seeds and is born")
        XCTAssertEqual(next[5], 1, "Cell below-right sees both seeds and is born")
    }
}
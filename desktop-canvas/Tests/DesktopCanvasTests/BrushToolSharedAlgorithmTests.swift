import XCTest
@testable import DesktopCanvas

/// Covers the pointer-based `BrushTool` helpers that `GameOfLifeProvider` now
/// uses, plus the single seeding algorithm shared by the provider and the array
/// API. These paths had no tests before.
final class BrushToolSharedAlgorithmTests: XCTestCase {

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Runs `body` with a zeroed buffer of `count` bytes, then hands the bytes
    /// back so assertions can inspect them.
    private func withBuffer(count: Int, _ body: (UnsafeMutablePointer<UInt8>) -> Void) -> [UInt8] {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer {
            buffer.deinitialize(count: count)
            buffer.deallocate()
        }
        body(buffer)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    // MARK: - Seeding

    func testSeedGridDensityOneFillsEveryCell() {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 1)
        let cells = withBuffer(count: 4096) {
            BrushTool.seedGrid($0, count: 4096, density: 1.0, using: &generator)
        }
        XCTAssertEqual(cells.filter { $0 == 1 }.count, 4096)
    }

    func testSeedGridDensityZeroLeavesEveryCellDead() {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 2)
        let cells = withBuffer(count: 4096) {
            BrushTool.seedGrid($0, count: 4096, density: 0.0, using: &generator)
        }
        XCTAssertEqual(cells.filter { $0 == 1 }.count, 0)
    }

    func testSeedGridClampsOutOfRangeDensity() {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 3)
        let full = withBuffer(count: 256) {
            BrushTool.seedGrid($0, count: 256, density: 5.0, using: &generator)
        }
        XCTAssertEqual(full.filter { $0 == 1 }.count, 256)

        let empty = withBuffer(count: 256) {
            BrushTool.seedGrid($0, count: 256, density: -3.0, using: &generator)
        }
        XCTAssertEqual(empty.filter { $0 == 1 }.count, 0)
    }

    func testSeedGridNanDensityStillSeedsSomeCells() {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 4)
        let cells = withBuffer(count: 4096) {
            BrushTool.seedGrid($0, count: 4096, density: .nan, using: &generator)
        }
        let alive = cells.filter { $0 == 1 }.count
        XCTAssertGreaterThan(alive, 0)
        XCTAssertLessThan(alive, 4096)
    }

    func testSeedGridHalfDensityIsRoughlyHalf() {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 5)
        let cells = withBuffer(count: 100 * 100) {
            BrushTool.seedGrid($0, count: 10_000, density: 0.5, using: &generator)
        }
        let alive = cells.filter { $0 == 1 }.count
        XCTAssertGreaterThan(alive, 4000)
        XCTAssertLessThan(alive, 6000)
    }

    func testSeedGridWithZeroCountDoesNothing() {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 6)
        // A zero-capacity buffer must not be dereferenced.
        BrushTool.seedGrid(UnsafeMutablePointer<UInt8>.allocate(capacity: 1), count: 0,
                           density: 1.0, using: &generator)
    }

    func testArrayRandomSeedDelegatesToSeedGrid() {
        var pointerGenerator: any RandomNumberGenerator = SeededGenerator(seed: 7)
        let viaPointer = withBuffer(count: 25 * 25) {
            BrushTool.seedGrid($0, count: 625, density: 0.4, using: &pointerGenerator)
        }
        var arrayGenerator: any RandomNumberGenerator = SeededGenerator(seed: 7)
        let viaArray = BrushTool.randomSeed(width: 25, height: 25, density: 0.4, using: &arrayGenerator)
        XCTAssertEqual(viaArray, viaPointer)
    }

    // MARK: - Pointer drawing matches the array API

    func testPointerDrawLineMatchesArrayDrawLine() {
        let width = 20
        let height = 20
        let viaArray = { () -> [UInt8] in
            var grid = [UInt8](repeating: 0, count: width * height)
            BrushTool.drawLine(&grid, width: width, height: height,
                               fromRow: 2, fromCol: 3, toRow: 17, toCol: 11, alive: true)
            return grid
        }()

        let viaPointer = withBuffer(count: width * height) {
            BrushTool.drawLine($0, width: width, height: height,
                               fromRow: 2, fromCol: 3, toRow: 17, toCol: 11, alive: true)
        }

        XCTAssertEqual(viaPointer, viaArray)
    }

    func testPointerFillRectMatchesArrayFillRect() {
        let width = 20
        let height = 20
        let viaArray = { () -> [UInt8] in
            var grid = [UInt8](repeating: 0, count: width * height)
            BrushTool.fillRect(&grid, width: width, height: height,
                               minRow: 4, minCol: 5, maxRow: 12, maxCol: 15, alive: true)
            return grid
        }()

        let viaPointer = withBuffer(count: width * height) {
            BrushTool.fillRect($0, width: width, height: height,
                               minRow: 4, minCol: 5, maxRow: 12, maxCol: 15, alive: true)
        }

        XCTAssertEqual(viaPointer, viaArray)
    }

    func testPointerFillRectClipsToBounds() {
        let width = 10
        let height = 10
        let cells = withBuffer(count: width * height) {
            BrushTool.fillRect($0, width: width, height: height,
                               minRow: -5, minCol: -5, maxRow: 3, maxCol: 3, alive: true)
        }
        XCTAssertEqual(cells.filter { $0 == 1 }.count, 16)
        XCTAssertEqual(cells[0], 1)
        XCTAssertEqual(cells[3 * width + 3], 1)
        XCTAssertEqual(cells[4 * width + 4], 0)
    }

    func testPointerLineDrawingIsClippedNotTrap() {
        let width = 10
        let height = 10
        // Endpoints far outside the grid: the shared lineCells output is filtered
        // by setCell, so this must not crash or wrap into memory.
        let cells = withBuffer(count: width * height) {
            BrushTool.drawLine($0, width: width, height: height,
                               fromRow: -20, fromCol: -20, toRow: 40, toCol: 40, alive: true)
        }
        XCTAssertEqual(cells.filter { $0 == 1 }.count, 10)
    }

    func testPointerSetCellOutOfBoundsIsNoOp() {
        let cells = withBuffer(count: 4) {
            BrushTool.setCell($0, width: 2, height: 2, row: 5, col: 5, alive: true)
        }
        XCTAssertEqual(cells, [0, 0, 0, 0])
    }

    func testPointerSetCellCanClear() {
        let cells = withBuffer(count: 4) {
            BrushTool.setCell($0, width: 2, height: 2, row: 0, col: 0, alive: true)
            BrushTool.setCell($0, width: 2, height: 2, row: 1, col: 1, alive: true)
            BrushTool.setCell($0, width: 2, height: 2, row: 0, col: 0, alive: false)
        }
        XCTAssertEqual(cells, [0, 0, 0, 1])
    }
}

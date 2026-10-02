import XCTest
@testable import DesktopCanvas

final class CanvasLayoutCodableTests: XCTestCase {

    private func makeLayout() -> CanvasLayout {
        CanvasLayout(
            name: "Round Trip",
            canvases: [
                CanvasModel(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    type: .gameOfLife,
                    frame: CGRect(x: 100, y: 200, width: 320, height: 240),
                    gameOfLifeConfig: GameOfLifeConfig(
                        ruleSet: .highLife,
                        cellSize: 6,
                        aliveColor: CodableColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1),
                        deadColor: CodableColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1),
                        marginColor: CodableColor(red: 0, green: 0, blue: 0.1, alpha: 1),
                        generationsPerSecond: 45,
                        gridState: [
                            [true, false, true],
                            [false, true, false],
                            [true, true, false]
                        ],
                        paused: true
                    )
                ),
                CanvasModel(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    type: .video,
                    frame: CGRect(x: 600, y: 40, width: 480, height: 270),
                    videoConfig: VideoConfig(
                        videoURL: URL(fileURLWithPath: "/tmp/clip.mp4"),
                        volume: 0.75,
                        loop: false,
                        naturalSize: CGSize(width: 1920, height: 1080)
                    )
                )
            ],
            backgroundColor: CodableColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1)
        )
    }

    func testCanvasLayoutRoundTripThroughJSON() throws {
        let layout = makeLayout()
        let data = try JSONEncoder.dc.encode(layout)
        let decoded = try JSONDecoder.dc.decode(CanvasLayout.self, from: data)

        XCTAssertEqual(decoded.name, layout.name)
        XCTAssertEqual(decoded.canvases.count, 2)
        XCTAssertEqual(decoded.backgroundColor, layout.backgroundColor)

        let original = layout.canvases[0]
        let roundTripped = decoded.canvases[0]
        XCTAssertEqual(roundTripped.id, original.id)
        XCTAssertEqual(roundTripped.type, original.type)
        XCTAssertEqual(roundTripped.frame, original.frame)
        XCTAssertEqual(roundTripped.gameOfLifeConfig, original.gameOfLifeConfig)
        XCTAssertEqual(roundTripped.gameOfLifeConfig?.gridState?.count, 3)
        XCTAssertEqual(roundTripped.gameOfLifeConfig?.paused, true)
        XCTAssertEqual(roundTripped.gameOfLifeConfig?.ruleSet, .highLife)

        let video = decoded.canvases[1]
        XCTAssertEqual(video.type, .video)
        XCTAssertEqual(video.videoConfig?.videoURL.lastPathComponent, "clip.mp4")
        XCTAssertEqual(video.videoConfig?.volume, 0.75)
        XCTAssertEqual(video.videoConfig?.loop, false)
        XCTAssertEqual(video.videoConfig?.naturalSize, CGSize(width: 1920, height: 1080))
        XCTAssertNil(video.gameOfLifeConfig)
    }

    func testLayoutSaveAndLoadFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-layout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = makeLayout()
        try layout.save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let loaded = try CanvasLayout.load(from: url)
        XCTAssertEqual(loaded.canvases.count, 2)
        XCTAssertEqual(loaded.canvases[0].gameOfLifeConfig?.cellSize, 6)
    }

    func testEncodingIsStableForEqualLayouts() throws {
        let layout = makeLayout()
        let first = try JSONEncoder.dc.encode(layout)
        let second = try JSONEncoder.dc.encode(layout)
        XCTAssertEqual(first, second, "Sorted keys must make encoding byte-stable")
    }

    func testFrameDecodesFromFourValueArray() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "type": "video",
          "frame": [10, 20, 200, 100],
          "videoConfig": { "videoURL": "file:///tmp/a.mov", "volume": 0.5, "loop": true }
        }
        """
        let canvas = try JSONDecoder.dc.decode(CanvasModel.self, from: Data(json.utf8))
        XCTAssertEqual(canvas.frame, CGRect(x: 10, y: 20, width: 200, height: 100))
        XCTAssertEqual(canvas.type, .video)
    }

    func testFrameWithWrongArityIsRejected() {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "type": "video",
          "frame": [10, 20, 200],
          "videoConfig": { "videoURL": "file:///tmp/a.mov", "volume": 0.5, "loop": true }
        }
        """
        XCTAssertThrowsError(try JSONDecoder.dc.decode(CanvasModel.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testDecodedFrameIsClampedToMinimumCanvasSize() {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "type": "video",
          "frame": [0, 0, 4, 8],
          "videoConfig": { "videoURL": "file:///tmp/a.mov", "volume": 0.0, "loop": true }
        }
        """
        let canvas = try? JSONDecoder.dc.decode(CanvasModel.self, from: Data(json.utf8))
        XCTAssertEqual(canvas?.frame.width, 32)
        XCTAssertEqual(canvas?.frame.height, 32)
    }

    func testInMemoryInitClampsFrameSizeToo() {
        let canvas = CanvasModel(type: .video, frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(canvas.frame.size, CGSize(width: 32, height: 32))
    }

    func testEqualityIncludesContentNotJustID() {
        let id = UUID()
        let a = CanvasModel(
            id: id, type: .gameOfLife, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            gameOfLifeConfig: GameOfLifeConfig(cellSize: 4)
        )
        let b = CanvasModel(
            id: id, type: .gameOfLife, frame: CGRect(x: 10, y: 0, width: 100, height: 100),
            gameOfLifeConfig: GameOfLifeConfig(cellSize: 4)
        )
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, b, "A moved canvas must not compare equal to its old position")

        var c = b
        c.gameOfLifeConfig?.cellSize = 8
        XCTAssertNotEqual(b, c, "A config edit must not compare equal")

        var d = b
        d.type = .video
        XCTAssertNotEqual(b, d, "A type switch must not compare equal")
    }

    func testCodableColorRoundTrip() throws {
        let color = CodableColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)
        let data = try JSONEncoder.dc.encode(color)
        let decoded = try JSONDecoder.dc.decode(CodableColor.self, from: data)
        XCTAssertEqual(decoded, color)
    }
}

final class GameOfLifeConfigClampTests: XCTestCase {

    func testZeroCellSizeIsClampedToMinimum() {
        XCTAssertEqual(GameOfLifeConfig(cellSize: 0).cellSize, GameOfLifeConfig.minimumCellSize)
        XCTAssertEqual(GameOfLifeConfig(cellSize: -5).cellSize, GameOfLifeConfig.minimumCellSize)
        XCTAssertEqual(GameOfLifeConfig(cellSize: 1).cellSize, 2)
    }

    func testCellSizeAboveMaximumIsClamped() {
        XCTAssertEqual(
            GameOfLifeConfig(cellSize: .max).cellSize,
            GameOfLifeConfig.maximumCellSize
        )
    }

    func testValidCellSizeIsPreserved() {
        XCTAssertEqual(GameOfLifeConfig(cellSize: 4).cellSize, 4)
        XCTAssertEqual(GameOfLifeConfig(cellSize: 64).cellSize, 64)
    }

    func testDecodeClampsCorruptCellSize() throws {
        let json = """
        { "cellSize": 0, "generationsPerSecond": 10 }
        """
        let config = try JSONDecoder.dc.decode(GameOfLifeConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.cellSize, 2)
        XCTAssertEqual(config.generationsPerSecond, 10)
        XCTAssertEqual(config.ruleSet, .conway)
    }

    func testDecodeSurvivesCorruptPresetJSONWithZeroCellSize() throws {
        let json = """
        {
          "name": "Corrupt",
          "canvases": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "type": "gameOfLife",
              "frame": [0, 0, 800, 600],
              "gameOfLifeConfig": { "cellSize": 0, "generationsPerSecond": 30 }
            }
          ]
        }
        """
        let layout = try JSONDecoder.dc.decode(CanvasLayout.self, from: Data(json.utf8))
        let config = try XCTUnwrap(layout.canvases[0].gameOfLifeConfig)
        XCTAssertEqual(config.cellSize, 2)

        // The exact expression that trapped with cellSize == 0.
        let (cols, rows) = GameOfLifeConfig.gridDimensions(
            for: layout.canvases[0].frame,
            cellSize: config.cellSize
        )
        XCTAssertEqual(cols, 400)
        XCTAssertEqual(rows, 300)
    }

    func testGridDimensionsNeverTrapOnZeroCellSize() {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let (cols, rows) = GameOfLifeConfig.gridDimensions(for: frame, cellSize: 0)
        XCTAssertEqual(cols, 320)
        XCTAssertEqual(rows, 240)
    }

    func testGridDimensionsFloorToWholeCellsAndStayPositive() {
        let frame = CGRect(x: 0, y: 0, width: 101, height: 55)
        let (cols, rows) = GameOfLifeConfig.gridDimensions(for: frame, cellSize: 8)
        XCTAssertEqual(cols, 12)
        XCTAssertEqual(rows, 6)
    }

    func testGridDimensionsAtLeastOneCellForTinyFrame() {
        let (cols, rows) = GameOfLifeConfig.gridDimensions(
            for: CGRect(x: 0, y: 0, width: 4, height: 4),
            cellSize: 64
        )
        XCTAssertEqual(cols, 1)
        XCTAssertEqual(rows, 1)
    }

    func testGridDimensionsHandleNonFiniteFrame() {
        let (cols, rows) = GameOfLifeConfig.gridDimensions(
            for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.nan),
            cellSize: 8
        )
        XCTAssertEqual(cols, 1)
        XCTAssertEqual(rows, 1)
    }

    func testNonFiniteGenerationsPerSecondFallsBackToDefault() {
        XCTAssertEqual(GameOfLifeConfig(generationsPerSecond: .infinity).generationsPerSecond, 30)
        XCTAssertEqual(GameOfLifeConfig(generationsPerSecond: .nan).generationsPerSecond, 30)
        XCTAssertEqual(GameOfLifeConfig(generationsPerSecond: -5).generationsPerSecond, 0)
    }

    func testZeroCellSizeNeverProducesNonFiniteCellCount() {
        var total = 0
        for cellSize in [Int.min, -1, 0, 1] {
            let (cols, rows) = GameOfLifeConfig.gridDimensions(
                for: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                cellSize: cellSize
            )
            total += cols * rows
            XCTAssertGreaterThan(cols, 0)
            XCTAssertGreaterThan(rows, 0)
        }
        XCTAssertGreaterThan(total, 0)
    }
}
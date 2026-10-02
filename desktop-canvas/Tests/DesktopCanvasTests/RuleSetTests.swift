import XCTest
@testable import DesktopCanvas

final class RuleSetTests: XCTestCase {

    func testConwayNotation() {
        let rule = try? XCTUnwrap(RuleSet(bSNotation: "B3/S23"))
        XCTAssertEqual(rule?.birth, [3])
        XCTAssertEqual(rule?.survival, [2, 3])
    }

    func testEmptySurvivalSetIsLegal() throws {
        let rule = try XCTUnwrap(RuleSet(bSNotation: "B2/S"))
        XCTAssertEqual(rule.birth, [2])
        XCTAssertTrue(rule.survival.isEmpty)
    }

    func testMultiDigitCountsAreParsed() throws {
        let rule = try XCTUnwrap(RuleSet(bSNotation: "B3678/S34678"))
        XCTAssertEqual(rule.birth, [3, 6, 7, 8])
        XCTAssertEqual(rule.survival, [3, 4, 6, 7, 8])
    }

    func testDuplicatesAreCollapsed() throws {
        let rule = try XCTUnwrap(RuleSet(bSNotation: "B33/S222"))
        XCTAssertEqual(rule.birth, [3])
        XCTAssertEqual(rule.survival, [2])
    }

    func testNotationIsCaseInsensitiveAndTrimmed() throws {
        let rule = try XCTUnwrap(RuleSet(bSNotation: "  b3/s23  "))
        XCTAssertEqual(rule.birth, [3])
        XCTAssertEqual(rule.survival, [2, 3])
    }

    func testNotationRoundTrip() throws {
        let rule = try XCTUnwrap(RuleSet(bSNotation: "B4678/S35678"))
        XCTAssertEqual(rule.bSNotation, "B4678/S35678")
    }

    func testConwayNotationRoundTrip() {
        XCTAssertEqual(RuleSet.conway.bSNotation, "B3/S23")
    }

    func testMalformedNotationIsRejected() {
        let rejected = [
            "",
            "3/23",
            "B3",
            "S23",
            "B3/",
            "/S23",
            "B/S",
            "B33/3",
            "B3/2O3"
        ]
        for notation in rejected {
            XCTAssertNil(RuleSet(bSNotation: notation), "Should reject \"\(notation)\"")
        }
    }

    func testAllPresetsParseAndUseExpectedRules() {
        XCTAssertEqual(RuleSet.presets.count, 9)
        XCTAssertEqual(RuleSet.presets[0].name, "Conway")
        XCTAssertEqual(RuleSet.presets[0].birth, [3])
        XCTAssertEqual(RuleSet.presets[0].survival, [2, 3])

        let expected: [(String, Set<Int>, Set<Int>)] = [
            ("Conway",    [3],         [2, 3]),
            ("HighLife",  [3, 6],      [2, 3]),
            ("Day & Night", [3, 6, 7, 8], [3, 4, 6, 7, 8]),
            ("Seeds",     [2],         []),
            ("Maze",      [3],         [1, 2, 3, 4, 5]),
            ("Anneal",    [4, 6, 7, 8], [3, 5, 6, 7, 8]),
            ("2x2",       [3, 6],      [1, 2, 5]),
            ("Morley",    [3, 6, 8],   [2, 4, 5]),
            ("Diamoeba",  [3, 5, 6, 7, 8], [5, 6, 7, 8])
        ]
        XCTAssertEqual(RuleSet.presets.count, expected.count)
        for (index, entry) in expected.enumerated() {
            let preset = RuleSet.presets[index]
            XCTAssertEqual(preset.name, entry.0, "preset #\(index) name")
            XCTAssertEqual(preset.birth, entry.1, "\(entry.0) birth")
            XCTAssertEqual(preset.survival, entry.2, "\(entry.0) survival")
        }
    }

    func testPresetNamesAreUnique() {
        let names = Set(RuleSet.presets.map(\.name))
        XCTAssertEqual(names.count, RuleSet.presets.count)
    }

    func testPresetCodableRoundTrip() throws {
        for preset in RuleSet.presets {
            let data = try JSONEncoder.dc.encode(preset)
            let decoded = try JSONDecoder.dc.decode(RuleSet.self, from: data)
            XCTAssertEqual(decoded, preset)
        }
    }

    func testRuleSetInsideConfigCorruptJSONIsRejected() {
        let json = """
        { "cellSize": 8, "ruleSet": { "name": "Broken", "birth": "three", "survival": [2] } }
        """
        XCTAssertThrowsError(try JSONDecoder.dc.decode(GameOfLifeConfig.self, from: Data(json.utf8)))
    }

    func testRuleSetWithNonIntegerSurvivalIsRejected() {
        let json = """
        { "name": "Broken", "birth": [3], "survival": ["2"] }
        """
        XCTAssertThrowsError(try JSONDecoder.dc.decode(RuleSet.self, from: Data(json.utf8)))
    }

    func testDeadRuleThatCanNeitherBirthNorSurviveIsRejected() {
        // "B/S" kills every cell on the first generation, so it is rejected as
        // a typo rather than silently wiping the canvas.
        XCTAssertNil(RuleSet(bSNotation: "B/S"))
    }

    func testEquatableAndHashable() {
        let a = RuleSet.conway
        let b = RuleSet.conway
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertNotEqual(a, .highLife)
    }
}

final class ApplyResultTests: XCTestCase {

    private func canvas(
        _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 200, _ h: CGFloat = 200
    ) -> CanvasModel {
        CanvasModel(
            type: .gameOfLife,
            frame: CGRect(x: x, y: y, width: w, height: h),
            gameOfLifeConfig: GameOfLifeConfig(cellSize: 8)
        )
    }

    func testNonOverlappingLayoutPassesValidation() {
        let canvases = [canvas(0, 0), canvas(400, 0), canvas(800, 0)]
        XCTAssertNoThrow(try OverlapResolver.validate(canvases))
    }

    func testOverlappingLayoutThrowsValidationError() {
        let a = canvas(0, 0)
        let b = canvas(100, 100)
        XCTAssertThrowsError(try OverlapResolver.validate([a, b])) { error in
            guard case OverlapResolver.ValidationError.overlappingCanvases(let pairs) = error else {
                return XCTFail("Expected overlappingCanvases, got \(error)")
            }
            XCTAssertEqual(pairs.count, 1)
            XCTAssertEqual(pairs.first?.0, a.id)
            XCTAssertEqual(pairs.first?.1, b.id)
        }
    }

    func testApplyRejectsOverlappingLayoutWithoutTouchingTheDesktop() {
        let result = DesktopCanvas.shared.apply(
            layout: CanvasLayout(name: "Overlap", canvases: [canvas(0, 0), canvas(50, 50)])
        )
        guard case .error(let message) = result else {
            return XCTFail("Expected .error, got \(result)")
        }
        XCTAssertTrue(message.contains("overlapping"), "message was: \(message)")
    }

    func testApplyAcceptsWellFormedLayout() {
        let result = DesktopCanvas.shared.apply(
            layout: CanvasLayout(name: "OK", canvases: [canvas(0, 0), canvas(400, 0)])
        )
        DesktopCanvas.shared.stop()

        switch result {
        case .ok:
            break
        case .warning:
            break
        case .error(let message):
            XCTFail("Unexpected error: \(message)")
        }
    }

    func testApplyOnEmptyLayoutSucceeds() {
        let result = DesktopCanvas.shared.apply(layout: CanvasLayout(name: "Empty", canvases: []))
        DesktopCanvas.shared.stop()
        if case .error(let message) = result {
            XCTFail("Unexpected error: \(message)")
        }
    }

    func testApplyWarnsOnHugeCellCounts() {
        // 20 canvases of 3000×3000 points at cellSize 2 = 2.25M cells each.
        var canvases: [CanvasModel] = []
        for index in 0..<5 {
            let model = CanvasModel(
                type: .gameOfLife,
                frame: CGRect(x: CGFloat(index) * 3200, y: 0, width: 3000, height: 3000),
                gameOfLifeConfig: GameOfLifeConfig(cellSize: 2)
            )
            canvases.append(model)
        }
        let result = DesktopCanvas.shared.apply(layout: CanvasLayout(name: "Huge", canvases: canvases))
        DesktopCanvas.shared.stop()

        guard case .warning(let message) = result else {
            return XCTFail("Expected .warning for >10M cells, got \(result)")
        }
        XCTAssertTrue(message.contains("exceeds recommended limit"), "message was: \(message)")
    }

    func testCellCountUsesClampedCellSizeForCorruptConfig() {
        let corrupt = CanvasModel(
            type: .gameOfLife,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            gameOfLifeConfig: GameOfLifeConfig(cellSize: 0)
        )
        XCTAssertEqual(corrupt.gameOfLifeConfig?.cellSize, 2)
        let (cols, rows) = GameOfLifeConfig.gridDimensions(
            for: corrupt.frame,
            cellSize: corrupt.gameOfLifeConfig?.cellSize ?? 0
        )
        XCTAssertEqual(cols * rows, 250_000)
    }

    func testRefreshWithoutApplyIsSafe() {
        DesktopCanvas.shared.refresh()
        DesktopCanvas.shared.refresh(with: CanvasLayout(name: "X", canvases: []))
    }

    func testStopIsIdempotent() {
        DesktopCanvas.shared.stop()
        DesktopCanvas.shared.stop()
    }
}
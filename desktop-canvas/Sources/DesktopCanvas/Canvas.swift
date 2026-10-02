import Foundation
import CoreGraphics

public enum CanvasType: String, Codable, CaseIterable {
    case gameOfLife
    case video
}

public struct GameOfLifeConfig: Codable, Equatable {
    public var ruleSet: RuleSet
    public var cellSize: Int
    public var aliveColor: CodableColor
    public var deadColor: CodableColor
    public var marginColor: CodableColor
    public var generationsPerSecond: Double
    public var gridState: [[Bool]]?
    public var paused: Bool

    /// Smallest legal cell size in points. A `cellSize` of 0 makes
    /// `frame.width / cellSize` infinite and traps on `Int(Double.infinity)`,
    /// so it is rejected at every construction site.
    public static let minimumCellSize = 2
    /// Largest cell size accepted from a preset file; anything above this
    /// collapses the grid to a single cell.
    public static let maximumCellSize = 1024

    public static func clampCellSize(_ value: Int) -> Int {
        min(max(value, minimumCellSize), maximumCellSize)
    }

    /// Grid dimensions for a canvas frame. Always at least 1×1 and free of
    /// non-finite intermediates.
    public static func gridDimensions(for frame: CGRect, cellSize: Int) -> (cols: Int, rows: Int) {
        let size = clampCellSize(cellSize)
        let width = frame.width.isFinite ? max(frame.width, 0) : 0
        let height = frame.height.isFinite ? max(frame.height, 0) : 0
        let cols = Int(floor(width / CGFloat(size)))
        let rows = Int(floor(height / CGFloat(size)))
        return (max(cols, 1), max(rows, 1))
    }

    public init(
        ruleSet: RuleSet = .conway,
        cellSize: Int = 8,
        aliveColor: CodableColor = CodableColor(red: 0.2, green: 0.9, blue: 0.3),
        deadColor: CodableColor = CodableColor(red: 0.05, green: 0.05, blue: 0.05),
        marginColor: CodableColor = CodableColor(red: 0, green: 0, blue: 0),
        generationsPerSecond: Double = 30,
        gridState: [[Bool]]? = nil,
        paused: Bool = false
    ) {
        self.ruleSet = ruleSet
        self.cellSize = Self.clampCellSize(cellSize)
        self.aliveColor = aliveColor
        self.deadColor = deadColor
        self.marginColor = marginColor
        self.generationsPerSecond = generationsPerSecond.isFinite ? max(generationsPerSecond, 0) : 30
        self.gridState = gridState
        self.paused = paused
    }

    public static let `default` = GameOfLifeConfig()
}

extension GameOfLifeConfig {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCellSize = try container.decodeIfPresent(Int.self, forKey: .cellSize) ?? 8
        let rawSpeed = try container.decodeIfPresent(Double.self, forKey: .generationsPerSecond) ?? 30
        self.init(
            ruleSet: try container.decodeIfPresent(RuleSet.self, forKey: .ruleSet) ?? .conway,
            cellSize: rawCellSize,
            aliveColor: try container.decodeIfPresent(CodableColor.self, forKey: .aliveColor)
                ?? CodableColor(red: 0.2, green: 0.9, blue: 0.3),
            deadColor: try container.decodeIfPresent(CodableColor.self, forKey: .deadColor)
                ?? CodableColor(red: 0.05, green: 0.05, blue: 0.05),
            marginColor: try container.decodeIfPresent(CodableColor.self, forKey: .marginColor)
                ?? CodableColor(red: 0, green: 0, blue: 0),
            generationsPerSecond: rawSpeed,
            gridState: try container.decodeIfPresent([[Bool]].self, forKey: .gridState),
            paused: try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        )
    }
}

public struct VideoConfig: Codable, Equatable {
    public var videoURL: URL
    public var volume: Double
    public var loop: Bool
    public var naturalSize: CGSize?

    public init(
        videoURL: URL = URL(fileURLWithPath: ""),
        volume: Double = 0.0,
        loop: Bool = true,
        naturalSize: CGSize? = nil
    ) {
        self.videoURL = videoURL
        self.volume = volume
        self.loop = loop
        self.naturalSize = naturalSize
    }

    public static let `default` = VideoConfig()
}

public struct CanvasModel: Identifiable, Equatable {
    public var id: UUID
    public var type: CanvasType
    public var frame: CGRect
    public var gameOfLifeConfig: GameOfLifeConfig?
    public var videoConfig: VideoConfig?

    public static func == (lhs: CanvasModel, rhs: CanvasModel) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.frame == rhs.frame
            && lhs.gameOfLifeConfig == rhs.gameOfLifeConfig
            && lhs.videoConfig == rhs.videoConfig
    }

    public init(
        id: UUID = UUID(),
        type: CanvasType,
        frame: CGRect,
        gameOfLifeConfig: GameOfLifeConfig? = nil,
        videoConfig: VideoConfig? = nil
    ) {
        self.id = id
        self.type = type
        self.frame = CGRect(
            origin: CGPoint(x: frame.origin.x, y: frame.origin.y),
            size: CGSize(
                width: max(frame.size.width, 32),
                height: max(frame.size.height, 32)
            )
        )
        self.gameOfLifeConfig = gameOfLifeConfig
        self.videoConfig = videoConfig
    }
}

extension CanvasModel: Codable {
    enum CodingKeys: String, CodingKey {
        case id, type, frame, gameOfLifeConfig, videoConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(CanvasType.self, forKey: .type)
        gameOfLifeConfig = try container.decodeIfPresent(GameOfLifeConfig.self, forKey: .gameOfLifeConfig)
        videoConfig = try container.decodeIfPresent(VideoConfig.self, forKey: .videoConfig)

        let rectValues = try container.decode([Double].self, forKey: .frame)
        guard rectValues.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .frame,
                in: container,
                debugDescription: "CGRect requires exactly 4 values"
            )
        }
        frame = CGRect(
            origin: CGPoint(x: rectValues[0], y: rectValues[1]),
            size: CGSize(
                width: max(rectValues[2], 32),
                height: max(rectValues[3], 32)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(gameOfLifeConfig, forKey: .gameOfLifeConfig)
        try container.encodeIfPresent(videoConfig, forKey: .videoConfig)
        try container.encode(
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
            forKey: .frame
        )
    }
}
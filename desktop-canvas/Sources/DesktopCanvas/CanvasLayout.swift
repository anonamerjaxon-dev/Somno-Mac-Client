import Foundation

/// Shared coders. `.sortedKeys` makes every emitted preset byte-stable, so an
/// unchanged layout re-encodes to identical bytes and the last-used file does
/// not need rewriting.
extension JSONEncoder {
    static var dc: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var dc: JSONDecoder {
        JSONDecoder()
    }
}

public struct CanvasLayout: Codable {
    public var name: String
    public var canvases: [CanvasModel]
    public var backgroundColor: CodableColor?

    public init(name: String, canvases: [CanvasModel], backgroundColor: CodableColor? = nil) {
        self.name = name
        self.canvases = canvases
        self.backgroundColor = backgroundColor
    }

    public static func load(from url: URL) throws -> CanvasLayout {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.dc.decode(CanvasLayout.self, from: data)
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder.dc.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
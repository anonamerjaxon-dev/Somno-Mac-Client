import Foundation

public struct RuleSet: Codable, Equatable, Hashable {
    public var name: String
    public var birth: Set<Int>
    public var survival: Set<Int>

    public init(name: String, birth: Set<Int>, survival: Set<Int>) {
        self.name = name
        self.birth = birth
        self.survival = survival
    }

    /// Parses `B<counts>/S<counts>` notation, e.g. `B3/S23`.
    ///
    /// Whitespace is ignored and the letters are case-insensitive. Duplicate
    /// counts are collapsed (`B33/S23` is `B3/S23`). A count outside 0…8, any
    /// other junk, and a rule that can neither birth nor keep a cell alive
    /// (`B/S`) are rejected.
    public init?(bSNotation: String) {
        let parts = bSNotation.split(separator: "/")
        guard parts.count == 2 else { return nil }

        let birthPart = parts[0].trimmingWhitespace()
        let survivalPart = parts[1].trimmingWhitespace()

        guard let birthLetter = birthPart.first,
              birthLetter.uppercased() == "B",
              let survivalLetter = survivalPart.first,
              survivalLetter.uppercased() == "S" else { return nil }

        guard let birthSet = Self.counts(birthPart.dropFirst()),
              let survivalSet = Self.counts(survivalPart.dropFirst()),
              !birthSet.isEmpty || !survivalSet.isEmpty else { return nil }

        self.name = "Custom"
        self.birth = birthSet
        self.survival = survivalSet
    }

    /// Every character must be an ASCII digit; a cell has 8 neighbours, so
    /// anything outside 0…8 cannot be honoured by the compute kernel.
    private static func counts(_ digits: Substring) -> Set<Int>? {
        var result: Set<Int> = []
        for character in digits {
            guard let digit = character.wholeNumberValue, character.isASCII, character.isNumber,
                  (0...8).contains(digit) else { return nil }
            result.insert(digit)
        }
        return result
    }

    public var bSNotation: String {
        let b = birth.sorted().map(String.init).joined()
        let s = survival.sorted().map(String.init).joined()
        return "B\(b)/S\(s)"
    }

    public static let conway   = RuleSet(name: "Conway",      birth: [3],             survival: [2, 3])
    public static let highLife = RuleSet(name: "HighLife",    birth: [3, 6],          survival: [2, 3])
    public static let dayNight = RuleSet(name: "Day & Night", birth: [3, 6, 7, 8],    survival: [3, 4, 6, 7, 8])
    public static let seeds    = RuleSet(name: "Seeds",       birth: [2],             survival: [])
    public static let maze     = RuleSet(name: "Maze",        birth: [3],             survival: [1, 2, 3, 4, 5])
    public static let anneal   = RuleSet(name: "Anneal",      birth: [4, 6, 7, 8],    survival: [3, 5, 6, 7, 8])
    public static let twoByTwo = RuleSet(name: "2x2",         birth: [3, 6],          survival: [1, 2, 5])
    public static let morley   = RuleSet(name: "Morley",      birth: [3, 6, 8],       survival: [2, 4, 5])
    public static let diamoeba = RuleSet(name: "Diamoeba",    birth: [3, 5, 6, 7, 8], survival: [5, 6, 7, 8])

    public static let presets: [RuleSet] = [
        .conway, .highLife, .dayNight, .seeds, .maze,
        .anneal, .twoByTwo, .morley, .diamoeba
    ]
}

private extension Substring {
    /// Drops surrounding whitespace without losing interior characters.
    func trimmingWhitespace() -> Substring {
        var slice = self[...]
        while let first = slice.first, first == " " || first == "\t" || first == "\n" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" || last == "\n" {
            slice = slice.dropLast()
        }
        return slice
    }
}
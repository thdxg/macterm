import Foundation

/// A string made ready to be matched against many times: folded once, so the
/// matcher compares integers in a tight loop instead of re-lowercasing and
/// re-walking `String`s per keystroke.
///
/// - `scalars` is the text case- and diacritic-folded, one Unicode scalar
///   per element (`é` → `e`, `ß` → `ss`; ASCII is lowercased in place, the
///   common case, without touching Foundation).
/// - `bonus` is, per folded scalar, what matching there is worth on top of a
///   plain match: the start of a word, a path component, a camelCase hump —
///   fzf's boundary rules, read from the *unfolded* text so `gitStatus` still
///   has its hump after lowercasing.
/// - `mask` is a 64-bit set of the characters present, so a candidate missing
///   any of the query's characters is rejected with one AND.
/// - `sourceOffsets` maps each folded scalar back to its scalar offset in the
///   original string, for highlighting what matched.
struct SearchText {
    let scalars: [UInt32]
    let bonus: [Int16]
    let mask: UInt64
    let sourceOffsets: [Int32]
    /// The original string's length in scalars: fzf's tiebreak prefers the
    /// shorter of two equal matches.
    let length: Int

    init(_ string: String) {
        var scalars: [UInt32] = []
        var bonus: [Int16] = []
        var offsets: [Int32] = []
        scalars.reserveCapacity(string.unicodeScalars.count)
        bonus.reserveCapacity(string.unicodeScalars.count)
        offsets.reserveCapacity(string.unicodeScalars.count)
        var mask: UInt64 = 0
        var previous = CharClass.white
        var offset: Int32 = 0
        for scalar in string.unicodeScalars {
            let cls = CharClass(scalar)
            let here = SearchScoring.bonus(previous: previous, current: cls)
            var first = true
            Self.fold(scalar) { folded in
                scalars.append(folded)
                // An expansion (`ß` → `ss`) is one character: only its first
                // scalar starts whatever the original character started.
                bonus.append(first ? here : 0)
                offsets.append(offset)
                mask |= Self.maskBit(folded)
                first = false
            }
            previous = cls
            offset += 1
        }
        self.scalars = scalars
        self.bonus = bonus
        self.mask = mask
        sourceOffsets = offsets
        length = Int(offset)
    }

    /// `string` folded the way `SearchText` folds, for a query term.
    static func foldedScalars(_ string: some StringProtocol) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            fold(scalar) { out.append($0) }
        }
        return out
    }

    static func mask(of scalars: [UInt32]) -> UInt64 {
        scalars.reduce(0) { $0 | maskBit($1) }
    }

    /// Case- and diacritic-folds one scalar into `emit`. ASCII skips
    /// Foundation entirely; anything else goes through `folding(options:)`,
    /// the same fold `localizedStandardContains`-style search uses.
    @inline(__always)
    static func fold(_ scalar: Unicode.Scalar, _ emit: (UInt32) -> Void) {
        let value = scalar.value
        if value < 0x80 {
            emit(value >= 0x41 && value <= 0x5A ? value + 0x20 : value)
            return
        }
        let folded = String(scalar).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for out in folded.unicodeScalars {
            emit(out.value)
        }
    }

    /// One of 64 bits per folded scalar: letters and digits get their own,
    /// everything else shares the rest. A false "present" only costs a scan;
    /// a false "absent" can't happen, since equal scalars map to equal bits.
    @inline(__always)
    static func maskBit(_ value: UInt32) -> UInt64 {
        switch value {
        case 0x61 ... 0x7A: 1 << UInt64(value - 0x61)
        case 0x30 ... 0x39: 1 << UInt64(26 + value - 0x30)
        default: 1 << UInt64(36 + value % 28)
        }
    }
}

/// fzf's character classes, which decide where a word starts.
enum CharClass: Int8 {
    case white
    case nonWord
    case delimiter
    case lower
    case upper
    case letter
    case number

    init(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        if value < 0x80 {
            switch value {
            case 0x61 ... 0x7A: self = .lower
            case 0x41 ... 0x5A: self = .upper
            case 0x30 ... 0x39: self = .number
            case 0x20,
                 0x09,
                 0x0A,
                 0x0D: self = .white
            // `/` `,` `:` `;` `|` separate the parts of a path or a list.
            case 0x2F,
                 0x2C,
                 0x3A,
                 0x3B,
                 0x7C: self = .delimiter
            default: self = .nonWord
            }
            return
        }
        let properties = scalar.properties
        if properties.isWhitespace {
            self = .white
        } else if properties.isLowercase {
            self = .lower
        } else if properties.isUppercase {
            self = .upper
        } else if properties.numericType != nil {
            self = .number
        } else if properties.isAlphabetic {
            self = .letter
        } else {
            self = .nonWord
        }
    }

    var isWord: Bool { rawValue > CharClass.delimiter.rawValue }
}

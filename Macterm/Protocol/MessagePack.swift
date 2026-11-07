import Foundation

/// MessagePack for the protocol (design/003 §2). It follows the Zig codec in
/// `server/src/protocol/msgpack.zig` byte for byte, so that a value that one
/// side encodes, the other side encodes again to the same bytes:
///
/// - An integer takes the smallest form that holds it.
/// - A struct is a map with string keys. An optional field that is nil is
///   left out.
/// - A decoder skips a key that it does not know, and refuses a key that
///   comes two times.
/// - A str must be valid UTF-8. Bytes that are not text are a bin.
///
/// The types of the messages are generated from the Zig schema
/// (`MactermProtocol.generated.swift`).
protocol ProtocolValue: Equatable, Sendable {
    init(from reader: inout MessagePackReader) throws
    func encode(to writer: inout MessagePackWriter)
}

enum MessagePackError: Error, Equatable {
    /// The input ends inside a value.
    case endOfInput
    /// The value has another type than the field.
    case wrongType
    /// An integer does not fit the field.
    case overflow
    case invalidUTF8
    case unknownEnumTag(String)
    case missingField(String)
    case duplicateField(String)
    /// The value is nested deeper than `MessagePackReader.maxDepth`.
    case tooDeep
    /// The arrays need more than `MessagePackReader.maxAllocation` bytes.
    case tooLarge
    /// Bytes follow the value.
    case trailingBytes
    /// The type byte that MessagePack does not define (0xc1).
    case invalidFormat
}

/// Bytes that are not text: a path or a command line that is not UTF-8.
struct ProtocolBin: ProtocolValue {
    var bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    init(from reader: inout MessagePackReader) throws {
        bytes = try reader.readBinary()
    }

    func encode(to writer: inout MessagePackWriter) {
        writer.writeBinary(bytes)
    }
}

/// A password or another secret (design/006 §4). On the wire it is a bin.
/// Its descriptions print no bytes, so that no log line carries one.
struct ProtocolSecret: ProtocolValue, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    init(from reader: inout MessagePackReader) throws {
        bytes = try reader.readBinary()
    }

    func encode(to writer: inout MessagePackWriter) {
        writer.writeBinary(bytes)
    }

    var description: String {
        "<secret>"
    }

    var debugDescription: String {
        "<secret>"
    }

    var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

/// One encoded value, kept as bytes. A request keeps its arguments as raw
/// bytes until it knows the method.
struct ProtocolRaw: ProtocolValue {
    var bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    /// Encodes `value` and keeps the bytes.
    init(encoding value: some ProtocolValue) {
        var writer = MessagePackWriter()
        value.encode(to: &writer)
        bytes = writer.data
    }

    init(from reader: inout MessagePackReader) throws {
        bytes = try reader.readRaw()
    }

    func encode(to writer: inout MessagePackWriter) {
        writer.writeRaw(bytes)
    }

    func decode<T: ProtocolValue>(_: T.Type) throws -> T {
        try MessagePackReader.decode(T.self, from: bytes)
    }
}

// MARK: - Writer

struct MessagePackWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data {
        Data(bytes)
    }

    static func encode(_ value: some ProtocolValue) -> Data {
        var writer = MessagePackWriter()
        value.encode(to: &writer)
        return writer.data
    }

    mutating func writeNil() {
        bytes.append(0xC0)
    }

    mutating func writeBool(_ value: Bool) {
        bytes.append(value ? 0xC3 : 0xC2)
    }

    mutating func writeUnsigned(_ value: UInt64) {
        switch value {
        case 0 ... 0x7F:
            bytes.append(UInt8(value))
        case 0x80 ... 0xFF:
            bytes.append(0xCC)
            bytes.append(UInt8(value))
        case 0x100 ... 0xFFFF:
            bytes.append(0xCD)
            appendBig(UInt16(value))
        case 0x10000 ... 0xFFFF_FFFF:
            bytes.append(0xCE)
            appendBig(UInt32(value))
        default:
            bytes.append(0xCF)
            appendBig(value)
        }
    }

    mutating func writeSigned(_ value: Int64) {
        if value >= 0 {
            return writeUnsigned(UInt64(value))
        }
        switch value {
        case -32 ..< 0:
            bytes.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int8.min) ..< -32:
            bytes.append(0xD0)
            bytes.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int16.min) ..< Int64(Int8.min):
            bytes.append(0xD1)
            appendBig(UInt16(bitPattern: Int16(value)))
        case Int64(Int32.min) ..< Int64(Int16.min):
            bytes.append(0xD2)
            appendBig(UInt32(bitPattern: Int32(value)))
        default:
            bytes.append(0xD3)
            appendBig(UInt64(bitPattern: value))
        }
    }

    mutating func writeString(_ value: String) {
        let utf8 = Array(value.utf8)
        switch utf8.count {
        case 0 ... 31:
            bytes.append(0xA0 | UInt8(utf8.count))
        case 32 ... 0xFF:
            bytes.append(0xD9)
            bytes.append(UInt8(utf8.count))
        case 0x100 ... 0xFFFF:
            bytes.append(0xDA)
            appendBig(UInt16(utf8.count))
        default:
            bytes.append(0xDB)
            appendBig(UInt32(utf8.count))
        }
        bytes.append(contentsOf: utf8)
    }

    mutating func writeBinary(_ value: Data) {
        switch value.count {
        case 0 ... 0xFF:
            bytes.append(0xC4)
            bytes.append(UInt8(value.count))
        case 0x100 ... 0xFFFF:
            bytes.append(0xC5)
            appendBig(UInt16(value.count))
        default:
            bytes.append(0xC6)
            appendBig(UInt32(value.count))
        }
        bytes.append(contentsOf: value)
    }

    mutating func writeArrayHeader(_ count: Int) {
        writeHeader(count, fix: 0x90, maxFix: 15, sixteen: 0xDC, thirtyTwo: 0xDD)
    }

    mutating func writeMapHeader(_ count: Int) {
        writeHeader(count, fix: 0x80, maxFix: 15, sixteen: 0xDE, thirtyTwo: 0xDF)
    }

    /// Writes bytes that already hold one encoded value.
    mutating func writeRaw(_ value: Data) {
        bytes.append(contentsOf: value)
    }

    private mutating func writeHeader(_ count: Int, fix: UInt8, maxFix: Int, sixteen: UInt8, thirtyTwo: UInt8) {
        if count <= maxFix {
            bytes.append(fix | UInt8(count))
        } else if count <= 0xFFFF {
            bytes.append(sixteen)
            appendBig(UInt16(count))
        } else {
            bytes.append(thirtyTwo)
            appendBig(UInt32(count))
        }
    }

    private mutating func appendBig(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
}

// MARK: - Reader

/// Reads MessagePack from untrusted input: a host's server can send
/// anything, so every length and every depth is checked before use.
struct MessagePackReader {
    /// The deepest nesting that the reader accepts. Each level is a stack
    /// frame.
    static let maxDepth = 32
    /// The most memory that one decode may allocate for arrays. One byte of
    /// input can be an element of many bytes in memory.
    static let maxAllocation = 1024 * 1024

    private let bytes: [UInt8]
    private(set) var position = 0
    private var depth = 0
    private var allocated = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool {
        position == bytes.count
    }

    /// Decodes one value of type `T` that fills all of `data`.
    static func decode<T: ProtocolValue>(_: T.Type, from data: Data) throws -> T {
        var reader = MessagePackReader(data)
        let value = try T(from: &reader)
        guard reader.isAtEnd else { throw MessagePackError.trailingBytes }
        return value
    }

    /// The value of a field that has no default: an error if the map did
    /// not have it.
    static func required<T>(_ value: T?, _ key: String) throws -> T {
        guard let value else { throw MessagePackError.missingField(key) }
        return value
    }

    func peek() throws -> UInt8 {
        guard position < bytes.count else { throw MessagePackError.endOfInput }
        return bytes[position]
    }

    mutating func readBool() throws -> Bool {
        switch try byte() {
        case 0xC2: false
        case 0xC3: true
        default: throw MessagePackError.wrongType
        }
    }

    mutating func readInteger<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let b = try byte()
        let value: T? = switch b {
        case 0x00 ... 0x7F: T(exactly: b)
        case 0xE0 ... 0xFF: T(exactly: Int8(bitPattern: b))
        case 0xCC: try T(exactly: big(UInt8.self))
        case 0xCD: try T(exactly: big(UInt16.self))
        case 0xCE: try T(exactly: big(UInt32.self))
        case 0xCF: try T(exactly: big(UInt64.self))
        case 0xD0: try T(exactly: Int8(bitPattern: big(UInt8.self)))
        case 0xD1: try T(exactly: Int16(bitPattern: big(UInt16.self)))
        case 0xD2: try T(exactly: Int32(bitPattern: big(UInt32.self)))
        case 0xD3: try T(exactly: Int64(bitPattern: big(UInt64.self)))
        default: throw MessagePackError.wrongType
        }
        guard let value else { throw MessagePackError.overflow }
        return value
    }

    mutating func readString() throws -> String {
        let b = try byte()
        let length = switch b {
        case 0xA0 ... 0xBF: Int(b & 0x1F)
        case 0xD9: try Int(big(UInt8.self))
        case 0xDA: try Int(big(UInt16.self))
        case 0xDB: try Int(big(UInt32.self))
        default: throw MessagePackError.wrongType
        }
        let slice = try take(length)
        guard let string = String(bytes: slice, encoding: .utf8) else { throw MessagePackError.invalidUTF8 }
        return string
    }

    mutating func readBinary() throws -> Data {
        let length = switch try byte() {
        case 0xC4: try Int(big(UInt8.self))
        case 0xC5: try Int(big(UInt16.self))
        case 0xC6: try Int(big(UInt32.self))
        default: throw MessagePackError.wrongType
        }
        return try Data(take(length))
    }

    /// Reads one value of any type and returns its bytes as they are.
    mutating func readRaw() throws -> Data {
        let start = position
        try skip()
        return Data(bytes[start ..< position])
    }

    /// Nil for a MessagePack nil, else a value of `T`.
    mutating func readOptional<T: ProtocolValue>(_: T.Type) throws -> T? {
        if try peek() == 0xC0 {
            position += 1
            return nil
        }
        return try T(from: &self)
    }

    mutating func readArrayLength() throws -> Int {
        let b = try byte()
        return switch b {
        case 0x90 ... 0x9F: Int(b & 0x0F)
        case 0xDC: try Int(big(UInt16.self))
        case 0xDD: try Int(big(UInt32.self))
        default: throw MessagePackError.wrongType
        }
    }

    mutating func readMapLength() throws -> Int {
        let b = try byte()
        return switch b {
        case 0x80 ... 0x8F: Int(b & 0x0F)
        case 0xDE: try Int(big(UInt16.self))
        case 0xDF: try Int(big(UInt32.self))
        default: throw MessagePackError.wrongType
        }
    }

    /// Reads an array. A length over the rest of the input is false, so it is
    /// refused before any allocation.
    mutating func readArray<T: ProtocolValue>(_: T.Type) throws -> [T] {
        let count = try readArrayLength()
        guard count <= bytes.count - position else { throw MessagePackError.endOfInput }
        try enter()
        defer { depth -= 1 }
        let size = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard !size.overflow, size.partialValue <= Self.maxAllocation - allocated else { throw MessagePackError.tooLarge }
        allocated += size.partialValue
        var items: [T] = []
        items.reserveCapacity(count)
        for _ in 0 ..< count {
            try items.append(T(from: &self))
        }
        return items
    }

    /// Reads a map with string keys. `field` reads the value of a key that
    /// it knows and returns true, or returns false and reads nothing: the
    /// reader then skips the value.
    mutating func readMap(_ field: (String, inout MessagePackReader) throws -> Bool) throws {
        let count = try readMapLength()
        try enter()
        defer { depth -= 1 }
        var seen: Set<String> = []
        for _ in 0 ..< count {
            let key = try readString()
            if try field(key, &self) {
                guard seen.insert(key).inserted else { throw MessagePackError.duplicateField(key) }
            } else {
                try skip()
            }
        }
    }

    /// Reads past one value of any type, also one that the protocol never
    /// decodes (a float, an ext). This is how a reader ignores a key that it
    /// does not know.
    mutating func skip() throws {
        let b = try byte()
        switch b {
        case 0x00 ... 0x7F,
             0xE0 ... 0xFF,
             0xC0,
             0xC2,
             0xC3: break
        case 0xC1: throw MessagePackError.invalidFormat
        case 0xA0 ... 0xBF: _ = try take(Int(b & 0x1F))
        case 0x80 ... 0x8F: try skipItems(Int(b & 0x0F) * 2)
        case 0x90 ... 0x9F: try skipItems(Int(b & 0x0F))
        case 0xCC,
             0xD0: _ = try take(1)
        case 0xCD,
             0xD1: _ = try take(2)
        case 0xCA,
             0xCE,
             0xD2: _ = try take(4)
        case 0xCB,
             0xCF,
             0xD3: _ = try take(8)
        case 0xC4,
             0xD9: _ = try take(Int(big(UInt8.self)))
        case 0xC5,
             0xDA: _ = try take(Int(big(UInt16.self)))
        case 0xC6,
             0xDB: _ = try take(Int(big(UInt32.self)))
        case 0xDC: try skipItems(Int(big(UInt16.self)))
        case 0xDD: try skipItems(Int(big(UInt32.self)))
        case 0xDE: try skipItems(Int(big(UInt16.self)) * 2)
        case 0xDF: try skipItems(Int(big(UInt32.self)) * 2)
        case 0xD4: _ = try take(2)
        case 0xD5: _ = try take(3)
        case 0xD6: _ = try take(5)
        case 0xD7: _ = try take(9)
        case 0xD8: _ = try take(17)
        case 0xC7: _ = try take(Int(big(UInt8.self)) + 1)
        case 0xC8: _ = try take(Int(big(UInt16.self)) + 1)
        case 0xC9: _ = try take(Int(big(UInt32.self)) + 1)
        default: throw MessagePackError.invalidFormat
        }
    }

    private mutating func skipItems(_ count: Int) throws {
        try enter()
        defer { depth -= 1 }
        for _ in 0 ..< count {
            try skip()
        }
    }

    private mutating func enter() throws {
        guard depth < Self.maxDepth else { throw MessagePackError.tooDeep }
        depth += 1
    }

    private mutating func byte() throws -> UInt8 {
        let b = try peek()
        position += 1
        return b
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= bytes.count - position else { throw MessagePackError.endOfInput }
        defer { position += count }
        return bytes[position ..< position + count]
    }

    private mutating func big<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> T {
        try take(MemoryLayout<T>.size).reduce(0) { $0 << 8 | T($1) }
    }
}

// MARK: - Conformances

extension Bool: ProtocolValue {
    init(from reader: inout MessagePackReader) throws {
        self = try reader.readBool()
    }

    func encode(to writer: inout MessagePackWriter) {
        writer.writeBool(self)
    }
}

extension String: ProtocolValue {
    init(from reader: inout MessagePackReader) throws {
        self = try reader.readString()
    }

    func encode(to writer: inout MessagePackWriter) {
        writer.writeString(self)
    }
}

extension Array: ProtocolValue where Element: ProtocolValue {
    init(from reader: inout MessagePackReader) throws {
        self = try reader.readArray(Element.self)
    }

    func encode(to writer: inout MessagePackWriter) {
        writer.writeArrayHeader(count)
        for item in self {
            item.encode(to: &writer)
        }
    }
}

/// The integer types of the schema: `u8` to `u64` and `i8` to `i64`.
protocol ProtocolInteger: FixedWidthInteger, ProtocolValue {}

extension ProtocolInteger {
    init(from reader: inout MessagePackReader) throws {
        self = try reader.readInteger(Self.self)
    }

    func encode(to writer: inout MessagePackWriter) {
        if Self.isSigned {
            writer.writeSigned(Int64(self))
        } else {
            writer.writeUnsigned(UInt64(self))
        }
    }
}

extension UInt8: ProtocolInteger {}
extension UInt16: ProtocolInteger {}
extension UInt32: ProtocolInteger {}
extension UInt64: ProtocolInteger {}
extension Int8: ProtocolInteger {}
extension Int16: ProtocolInteger {}
extension Int32: ProtocolInteger {}
extension Int64: ProtocolInteger {}

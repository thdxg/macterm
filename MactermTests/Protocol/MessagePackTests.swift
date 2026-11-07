import Foundation
@testable import Macterm
import Testing

/// The same cases as the tests of `server/src/protocol/msgpack.zig`, so that
/// the two codecs keep one format.
struct MessagePackTests {
    private static func encode(_ value: some ProtocolValue) -> [UInt8] {
        Array(MessagePackWriter.encode(value))
    }

    private static func decode<T: ProtocolValue>(_: T.Type, _ bytes: [UInt8]) throws -> T {
        try MessagePackReader.decode(T.self, from: Data(bytes))
    }

    private struct Sample: ProtocolValue {
        var name: String
        var note: String?
        var tags: [String]

        init(name: String, note: String? = nil, tags: [String]) {
            self.name = name
            self.note = note
            self.tags = tags
        }

        init(from reader: inout MessagePackReader) throws {
            var name: String?
            var note: String?
            var tags: [String]?
            try reader.readMap { key, reader in
                switch key {
                case "name": name = try String(from: &reader)
                case "note": note = try reader.readOptional(String.self)
                case "tags": tags = try [String](from: &reader)
                default: return false
                }
                return true
            }
            self.name = try MessagePackReader.required(name, "name")
            self.note = note
            self.tags = try MessagePackReader.required(tags, "tags")
        }

        func encode(to writer: inout MessagePackWriter) {
            writer.writeMapHeader(note == nil ? 2 : 3)
            writer.writeString("name")
            name.encode(to: &writer)
            if let note {
                writer.writeString("note")
                note.encode(to: &writer)
            }
            writer.writeString("tags")
            tags.encode(to: &writer)
        }
    }

    @Test
    func the_encoder_writes_the_bytes_of_the_spec() {
        let long = String(repeating: "x", count: 65536)
        #expect(Self.encode(true) == [0xC3])
        #expect(Self.encode("") == [0xA0])
        #expect(Self.encode(String(long.prefix(31))).first == 0xBF)
        #expect(Self.encode(String(long.prefix(32))).prefix(2) == [0xD9, 32])
        #expect(Self.encode(String(long.prefix(256))).prefix(3) == [0xDA, 1, 0])
        #expect(Self.encode(long).prefix(5) == [0xDB, 0, 1, 0, 0])
        let bytes = Data(repeating: 0x78, count: 65536)
        #expect(Self.encode(ProtocolBin(bytes.prefix(255))).prefix(2) == [0xC4, 255])
        #expect(Self.encode(ProtocolBin(bytes.prefix(256))).prefix(3) == [0xC5, 1, 0])
        #expect(Self.encode(ProtocolSecret(bytes)).prefix(5) == [0xC6, 0, 1, 0, 0])
        #expect(Self.encode([UInt16(1), 2]) == [0x92, 1, 2])
        #expect(Self.encode([UInt16](repeating: 1, count: 16)).prefix(3) == [0xDC, 0, 16])
        #expect(Self.encode(Sample(name: "a", tags: [])) == [0x82, 0xA4, 0x6E, 0x61, 0x6D, 0x65, 0xA1, 0x61, 0xA4, 0x74, 0x61, 0x67, 0x73, 0x90])
    }

    @Test
    func integers_use_the_smallest_form_and_keep_their_value() throws {
        let cases: [(Int64, Int)] = [
            (0, 1), (127, 1), (128, 2), (255, 2), (256, 3), (65536, 5), (1 << 40, 9),
            (-1, 1), (-32, 1), (-33, 2), (-200, 3), (-70000, 5), (Int64.min, 9),
        ]
        for (value, length) in cases {
            let bytes = Self.encode(value)
            #expect(bytes.count == length, "\(value)")
            #expect(try Self.decode(Int64.self, bytes) == value)
        }
        #expect(try Self.decode(UInt64.self, Self.encode(UInt64.max)) == UInt64.max)
        // An unsigned value takes the same form as a signed one.
        #expect(Self.encode(UInt32(300)) == Self.encode(Int64(300)))
    }

    @Test
    func an_integer_that_does_not_fit_the_field_is_refused() {
        #expect(throws: MessagePackError.overflow) { try Self.decode(UInt8.self, Self.encode(UInt32(300))) }
        #expect(throws: MessagePackError.overflow) { try Self.decode(UInt32.self, Self.encode(Int32(-1))) }
    }

    @Test
    func strings_bin_and_secrets_keep_every_length_form() throws {
        for count in [0, 31, 32, 255, 256, 65535, 65536] {
            let text = String(repeating: "x", count: count)
            #expect(try Self.decode(String.self, Self.encode(text)) == text)
            let bytes = Data(repeating: 0xFF, count: count)
            #expect(try Self.decode(ProtocolBin.self, Self.encode(ProtocolBin(bytes))).bytes == bytes)
            #expect(try Self.decode(ProtocolSecret.self, Self.encode(ProtocolSecret(bytes))).bytes == bytes)
        }
    }

    @Test
    func a_str_that_is_not_UTF8_is_refused_and_bin_carries_it() throws {
        #expect(throws: MessagePackError.invalidUTF8) { try Self.decode(String.self, [0xA2, 0xFF, 0xFE]) }
        #expect(try Self.decode(ProtocolBin.self, [0xC4, 2, 0xFF, 0xFE]).bytes == Data([0xFF, 0xFE]))
    }

    @Test
    func a_secret_prints_no_bytes() {
        let secret = ProtocolSecret(Data("hunter2".utf8))
        #expect("\(secret)" == "<secret>")
        #expect(String(reflecting: secret) == "<secret>")
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("hunter2"))
    }

    @Test
    func a_struct_round_trips_and_a_nil_optional_is_left_out() throws {
        let sample = Sample(name: "pane", tags: ["a", "b"])
        let bytes = Self.encode(sample)
        #expect(bytes.first == 0x82)
        #expect(try Self.decode(Sample.self, bytes) == sample)
        let noted = Sample(name: "pane", note: "n", tags: [])
        #expect(try Self.decode(Sample.self, Self.encode(noted)) == noted)
    }

    @Test
    func decode_skips_unknown_keys_floats_and_ext_values() throws {
        // {"a": 1.5 (f64), "b": fixext1, "name": "x", "tags": [], "z": {"deep": [1, 70000]}}
        let bytes: [UInt8] = [0x85, 0xA1, 0x61, 0xCB, 0, 0, 0, 0, 0, 0, 0, 0]
            + [0xA1, 0x62, 0xD4, 1, 2]
            + [0xA4, 0x6E, 0x61, 0x6D, 0x65, 0xA1, 0x78]
            + [0xA4, 0x74, 0x61, 0x67, 0x73, 0x90]
            + [0xA1, 0x7A, 0x81, 0xA4, 0x64, 0x65, 0x65, 0x70, 0x92, 1, 0xCE, 0, 1, 0x11, 0x70]
        #expect(try Self.decode(Sample.self, bytes) == Sample(name: "x", tags: []))
    }

    @Test
    func a_missing_field_is_refused_and_a_nil_value_reads_as_nil() throws {
        #expect(throws: MessagePackError.missingField("tags")) {
            try Self.decode(Sample.self, [0x81, 0xA4, 0x6E, 0x61, 0x6D, 0x65, 0xA1, 0x78])
        }
        let withNil: [UInt8] = [0x83, 0xA4, 0x6E, 0x61, 0x6D, 0x65, 0xA1, 0x78, 0xA4, 0x6E, 0x6F, 0x74, 0x65, 0xC0]
            + [0xA4, 0x74, 0x61, 0x67, 0x73, 0x90]
        #expect(try Self.decode(Sample.self, withNil).note == nil)
    }

    @Test
    func hostile_input_fails_cleanly() throws {
        let good = Self.encode([UInt32(1), 2, 300])
        for count in 0 ..< good.count {
            #expect(throws: MessagePackError.endOfInput) { try Self.decode([UInt32].self, Array(good.prefix(count))) }
        }
        // An array that claims more items than there are bytes.
        #expect(throws: MessagePackError.endOfInput) { try Self.decode([UInt32].self, [0xDD, 0xFF, 0xFF, 0xFF, 0xFF]) }
        // Deep nesting in a key that is not known.
        let deep: [UInt8] = [0x81, 0xA1, 0x7A] + [UInt8](repeating: 0x91, count: 99) + [0x90]
        #expect(throws: MessagePackError.tooDeep) { try Self.decode(Sample.self, deep) }
        // Many small items that need much more memory than their bytes.
        let wide: [UInt8] = [0xDD, 0, 1, 0x86, 0xA0] + [UInt8](repeating: 0xA0, count: 100_000)
        #expect(throws: MessagePackError.tooLarge) { try Self.decode([String].self, wide) }
        #expect(throws: MessagePackError.trailingBytes) { try Self.decode(UInt8.self, [1, 2]) }
        let duplicate: [UInt8] = [0x82, 0xA4, 0x74, 0x61, 0x67, 0x73, 0x90, 0xA4, 0x74, 0x61, 0x67, 0x73, 0x90]
        #expect(throws: MessagePackError.duplicateField("tags")) { try Self.decode(Sample.self, duplicate) }
        let reserved: [UInt8] = [0x81, 0xA1, 0x7A, 0xC1]
        #expect(throws: MessagePackError.invalidFormat) { try Self.decode(Sample.self, reserved) }
    }

    @Test
    func an_unknown_enum_tag_is_unknown_where_the_enum_has_it() throws {
        #expect(try Self.decode(MactermProtocol.Role.self, Self.encode("relay")) == .unknown)
        #expect(try Self.decode(MactermProtocol.Role.self, Self.encode("cli")) == .cli)
    }
}

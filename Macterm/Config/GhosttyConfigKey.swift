import AppKit
import GhosttyKit

/// A ghostty config key paired with the C shape libghostty's
/// `ghostty_config_get` writes for it.
///
/// The getter takes a `void*` and fills it according to the key's Zig type
/// (`src/config/c_get.zig`), so the caller has to hand it the right out
/// parameter — and nothing in the C API says which. Two bugs came from
/// guessing: an enum read through a `ghostty_string_s` comes back with `len`
/// 0 (`window-colorspace`, `macos-hidden`), because libghostty writes an
/// enum's `@tagName` as a bare NUL-terminated pointer. Pairing the shape with
/// the key *at the declaration* makes the pairing unforgeable at the fourteen
/// places a key is read; `GhosttyApp.read` is the one generic reader.
///
/// The factories below are the shapes Macterm reads today. Add one per new
/// C shape, not per key — and check `c_get.zig` first: a `ghostty_string_s`
/// is NOT among the shapes the getter writes, and a key whose Zig type has no
/// `cval` (the `command` union) fails the getter outright rather than
/// arriving in some shape.
struct GhosttyConfigKey<Value> {
    /// ghostty's spelling of the key — a wire contract with libghostty.
    let name: String
    private let decode: @Sendable (ghostty_config_t) -> Value?

    private init(_ name: String, decode: @escaping @Sendable (ghostty_config_t) -> Value?) {
        self.name = name
        self.decode = decode
    }

    /// The key's value off a finalized config, or nil when the getter fails
    /// (an unknown key) or the value is unset.
    func read(from config: ghostty_config_t) -> Value? {
        decode(config)
    }

    /// One `ghostty_config_get` call with `value` as the out parameter.
    fileprivate static func get(_ config: ghostty_config_t, _ name: String, into value: inout some Any) -> Bool {
        ghostty_config_get(config, &value, name, UInt(name.utf8.count))
    }
}

extension GhosttyConfigKey where Value == Bool {
    /// A `bool` key. The getter writes over the default it is handed, so a
    /// failed read leaves the caller's fallback in place.
    static func bool(_ name: String) -> Self {
        Self(name) { config in
            var value = false
            return get(config, name, into: &value) ? value : nil
        }
    }
}

extension GhosttyConfigKey where Value == Double {
    /// An `f64` key.
    static func double(_ name: String) -> Self {
        Self(name) { config in
            var value = 0.0
            return get(config, name, into: &value) ? value : nil
        }
    }
}

extension GhosttyConfigKey where Value == CUnsignedInt {
    /// A packed-struct key (a bit set such as `bell-features`), read as its
    /// backing unsigned integer.
    static func packed(_ name: String) -> Self {
        Self(name) { config in
            var value: CUnsignedInt = 0
            return get(config, name, into: &value) ? value : nil
        }
    }
}

extension GhosttyConfigKey where Value == String {
    /// An enum key, read as its ghostty tag name (`macos-hidden` → `never`),
    /// or an optional `?[:0]const u8` key (`macos-custom-icon`). Both arrive
    /// as a bare NUL-terminated pointer — NOT a `ghostty_string_s`, whose
    /// `len` would stay 0. An unset optional is the case to watch: the
    /// getter writes a null pointer and still returns *true*, so the pointer
    /// rather than the return value says the key is unset.
    static func tag(_ name: String) -> Self {
        Self(name) { config in
            var ptr: UnsafePointer<CChar>?
            guard get(config, name, into: &ptr), let ptr else { return nil }
            return String(cString: ptr)
        }
    }

    /// A `Path` key (`bell-audio-path`), which arrives as a
    /// `ghostty_config_path_s`. Empty means unset and reads as nil.
    static func path(_ name: String) -> Self {
        Self(name) { config in
            var value = ghostty_config_path_s()
            guard get(config, name, into: &value), let ptr = value.path else { return nil }
            let path = String(cString: ptr)
            return path.isEmpty ? nil : path
        }
    }
}

extension GhosttyConfigKey where Value == NSColor {
    /// A `Color` key, arriving as 8-bit sRGB components.
    static func color(_ name: String) -> Self {
        Self(name) { config in
            var color = ghostty_config_color_s()
            guard get(config, name, into: &color) else { return nil }
            return nsColor(color)
        }
    }
}

extension GhosttyConfigKey where Value == [NSColor] {
    /// The 256-entry `palette` key.
    static func palette(_ name: String) -> Self {
        Self(name) { config in
            var palette = ghostty_config_palette_s()
            guard get(config, name, into: &palette) else { return nil }
            return withUnsafePointer(to: &palette.colors) {
                $0.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { colors in
                    (0 ..< 256).map { nsColor(colors[$0]) }
                }
            }
        }
    }
}

private func nsColor(_ c: ghostty_config_color_s) -> NSColor {
    NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
}

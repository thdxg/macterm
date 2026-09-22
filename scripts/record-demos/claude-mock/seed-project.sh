#!/bin/bash
# Write the small Swift package demo 7 shows Claude Code touring, and the
# notes file the Helix pane edits. Regenerated before every take, so a stray
# keystroke from the last one never shows up in the next.
#
#   seed-project.sh <dir>
set -euo pipefail
dir="$1"
rm -rf "$dir"
mkdir -p "$dir/Sources/Starfield"
cd "$dir"

cat > Package.swift <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "starfield",
    targets: [
        .executableTarget(name: "Starfield", path: "Sources/Starfield"),
    ]
)
SWIFT

cat > Sources/Starfield/Star.swift <<'SWIFT'
/// One star: where it is, how far away, and how bright that makes it.
struct Star {
    var x: Double
    var y: Double
    var z: Double

    /// Four grey levels, near to far. The renderer maps these to ANSI 256
    /// colours 255, 250, 245 and 240.
    var brightness: Int {
        switch z {
        case ..<0.25: return 3
        case ..<0.5: return 2
        case ..<0.75: return 1
        default: return 0
        }
    }

    var glyph: Character {
        ["·", "•", "◦", "*"][brightness]
    }
}
SWIFT

cat > Sources/Starfield/Field.swift <<'SWIFT'
/// The star population. Stars drift toward the viewer and are recycled at
/// the far plane, so the count never changes.
struct Field {
    var stars: [Star]
    var speed: Double

    init(count: Int, speed: Double) {
        self.speed = speed
        stars = (0..<count).map { _ in Field.spawn(depth: .random(in: 0.05...1.0)) }
    }

    static func spawn(depth: Double) -> Star {
        Star(x: .random(in: -1...1), y: .random(in: -1...1), z: depth)
    }

    mutating func advance(by dt: Double) {
        for i in stars.indices {
            stars[i].z -= speed * dt
            if stars[i].z <= 0.02 {
                stars[i] = Field.spawn(depth: 1.0)
            }
        }
    }
}
SWIFT

cat > Sources/Starfield/Renderer.swift <<'SWIFT'
/// Projects a Field onto the terminal grid and writes it as text. One
/// buffer, reused every frame; one cursor-home escape instead of a clear,
/// which is what keeps the output flicker-free.
struct Renderer {
    let columns: Int
    let rows: Int
    private var buffer = ""

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        buffer.reserveCapacity(columns * rows * 12)
    }

    mutating func render(_ field: Field) -> String {
        var cells = Array(repeating: " ", count: columns * rows)
        var levels = Array(repeating: -1, count: columns * rows)
        for star in field.stars {
            let px = Int((star.x / star.z + 1) * 0.5 * Double(columns - 1))
            let py = Int((star.y / star.z + 1) * 0.5 * Double(rows - 1))
            guard (0..<columns).contains(px), (0..<rows).contains(py) else { continue }
            let i = py * columns + px
            if star.brightness > levels[i] {
                levels[i] = star.brightness
                cells[i] = String(star.glyph)
            }
        }
        buffer.removeAll(keepingCapacity: true)
        buffer += "\u{1b}[H"
        for row in 0..<rows {
            for col in 0..<columns {
                let i = row * columns + col
                if levels[i] >= 0 {
                    buffer += "\u{1b}[38;5;\(240 + levels[i] * 5)m\(cells[i])"
                } else {
                    buffer += " "
                }
            }
            buffer += "\u{1b}[0m\n"
        }
        return buffer
    }
}
SWIFT

cat > Sources/Starfield/main.swift <<'SWIFT'
import Dispatch
import Foundation

/// Usage: starfield [--density N] [--speed S]
var density = 40.0
var speed = 0.35
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--density": density = min(max(Double(args.next() ?? "") ?? density, 8), 400)
    case "--speed": speed = min(max(Double(args.next() ?? "") ?? speed, 0.02), 3)
    default: break
    }
}

var size = winsize()
_ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
let columns = Int(size.ws_col == 0 ? 80 : size.ws_col)
let rows = Int(size.ws_row == 0 ? 24 : size.ws_row) - 1

var field = Field(count: max(1, columns * rows / Int(density)), speed: speed)
var renderer = Renderer(columns: columns, rows: rows)

print("\u{1b}[?25l\u{1b}[2J", terminator: "")
let timer = DispatchSource.makeTimerSource()
timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
timer.setEventHandler {
    field.advance(by: 1.0 / 60.0)
    FileHandle.standardOutput.write(renderer.render(field).data(using: .utf8)!)
}
timer.resume()
signal(SIGINT) { _ in
    print("\u{1b}[?25h\u{1b}[0m")
    exit(0)
}
dispatchMain()
SWIFT

cat > README.md <<'MD'
# starfield

A drifting starfield for the terminal, written to try out flicker-free
full-screen output from Swift.

    swift run starfield --density 40 --speed 0.35
MD

cat > notes.md <<'MD'
# Working notes

The renderer writes every frame with a single cursor-home escape instead
of clearing the screen. Clearing produced a visible flash on slower
terminals; overwriting in place does not, and it also means a dropped frame
leaves the previous one on screen rather than a blank.

Depth drives everything visual. Brightness is four grey levels picked by
distance, and the glyph changes with it, so a star reads as a faint dot far
away and a bright asterisk just before it passes the viewer.

## Ideas

- A warp burst on keypress: multiply speed for a few frames and stretch each
  glyph into a short streak along its motion vector.
- Colour by temperature instead of depth, sampled from a small blackbody
  table, so the field looks less uniform.
- A `--seed` flag, so a run can be reproduced when tuning the projection.

## Open questions

Whether the frame loop should skip a frame when the terminal is slow, or
render anyway and let the terminal fall behind. Skipping keeps the motion
honest; rendering anyway is simpler and what the current code does.
MD
git init -q . 2>/dev/null && git add -A >/dev/null && git -c user.name=demo -c user.email=demo@example.com commit -qm "starfield" >/dev/null || true
echo "seeded $dir"

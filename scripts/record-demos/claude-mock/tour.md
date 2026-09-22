Here's a tour of **starfield**, a small Swift package that renders a drifting starfield in the terminal.

## Layout

```
Package.swift
Sources/Starfield/
  main.swift      entry point: argument parsing and the frame loop
  Field.swift     the star population and its per-frame update
  Star.swift      one star: position, depth, brightness
  Renderer.swift  turns a Field into rows of text for the terminal
notes.md          working notes and ideas
```

## How a frame is drawn

1. `main.swift` reads the terminal size, builds a `Field` with one star per 40 cells, and enters a loop that targets 60 frames per second.
2. Each tick, `Field.advance(by:)` moves every star toward the viewer. A star that passes the near plane is recycled at a random position far away, so the population never changes size.
3. `Renderer.render(_:)` projects each star to a cell, picks a glyph from `·•◦*` by depth, and writes the rows with one cursor-home escape per frame rather than clearing the screen, which is what keeps it flicker-free.
4. Brightness is depth-based: `Star.brightness` maps the distance to one of four ANSI grey levels, so far stars read as faint dots and near ones as bright asterisks.

## Things worth knowing

- The frame loop uses `DispatchSourceTimer` rather than `Thread.sleep`, so a slow terminal drops frames instead of drifting.
- `Renderer` owns the only `String` buffer and reuses it every frame; nothing allocates in the hot path.
- The `--density` and `--speed` flags in `main.swift` are the only configuration. Both are clamped so a typo can't produce an empty or solid screen.
- `notes.md` lists two open ideas: a warp burst on keypress, and colour by temperature instead of depth.

## Where to start

`Sources/Starfield/Field.swift` is the heart of it and fits on one screen. Read `advance(by:)` first, then `Renderer.render(_:)`, and the rest follows.

Want me to walk through one of those files line by line?

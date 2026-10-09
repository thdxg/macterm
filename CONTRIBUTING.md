# Contributing to Macterm

Thank you for your interest in Macterm. Macterm is a macOS terminal emulator. It uses SwiftUI and libghostty.

This guide is for work on the app. To contribute an extension, see the [`extensions`](extensions/) folder.

## Setup

You need macOS 26 or later and a full installation of Xcode 26. The Command Line Tools are not enough. `xcodebuild` needs the Xcode app to build the macOS app target. The code uses macOS 26 SDK APIs behind `#available` checks. The shipped app runs on macOS 14 or later.

CI builds with one pinned Xcode version (`.github/actions/select-xcode`). A green CI run therefore names a known toolchain. Any Xcode 26 works on your Mac. CI does not catch a failure that only occurs with an Xcode 26.x older than the pin. That is how [#340](https://github.com/thdxg/macterm/pull/340) reached main.

Install the tools:

```bash
mise install
```

Download the build files:

```bash
mise run setup
```

`mise install` installs the pinned tools: `gh`, `swiftformat`, `swiftlint`, `xcodegen` and `xcbeautify`. `mise run setup` downloads the pre-built `GhosttyKit.xcframework` and the bundled ghostty resources. Git ignores these build files. **Run `mise run setup` in every new checkout, including a git worktree.** The app does not build without it.

For a tour of the code and the architecture, read [CLAUDE.md](CLAUDE.md).

## Running the app

```bash
mise run run
```

This task formats and lints the code. Then it builds and starts the Debug app. Debug builds have their own bundle ID and their own Application Support folder. They never change the data of your release install.

```bash
mise run logs
```

This task streams live logs from the Debug app. Add `--release` to read the logs of the release app. Add `--last 30m` to read past logs instead of a live stream.

## Tasks

Run each task with `mise run <name>`:

| Task | What it does |
| --- | --- |
| `setup` | Downloads GhosttyKit and the bundled ghostty resources |
| `run` | Builds and starts the Debug app |
| `logs` | Streams live logs from the Debug app |
| `format` | Fixes formatting with swiftformat (`--check` only checks) |
| `lint` | Runs swiftlint |
| `test` | Runs the Swift unit tests |
| `e2e` | Builds the Debug app and runs the end-to-end tests against it |
| `build` | Makes a release build and a DMG |
| `install` | Builds the release app and installs it in `/Applications` |
| `bench` | Makes a release build and measures the resources that each window state uses |
| `clean` | Removes `build/` and the generated `Macterm.xcodeproj` |

### The `--verbose` flag

Every task accepts `-v` and `--verbose`. Without the flag, a task shows a spinner and hides its output. It prints the output only when the task fails. With the flag, the task streams all of its output as it runs:

```bash
mise run test --verbose
```

Use the flag when you want the `xcodebuild`, swiftlint or pytest output. Use it also after a failure, to watch the next attempt. CI always uses the verbose form.

## Before you commit

Run the checks that CI runs:

```bash
mise run format
```

```bash
mise run lint
```

```bash
mise run test
```

CI blocks your PR when one of these checks fails. Run them on your Mac first to keep the loop fast. `mise run run` already runs format and lint. `mise run build` also runs the tests.

## Tests

- **Unit tests** are in `MactermTests/`. Run them with `mise run test`. Each production type has one `XxxTests.swift` file, in the same path as the source. The tests run inside the Debug app. They cover the model, persistence, palette and hotkey logic. They do not cover SwiftUI views or the libghostty bindings.
- **End-to-end tests** are in `e2e/`. Run them with `mise run e2e`. This pytest suite starts the real app in an isolated environment. It controls the app with the bundled `macterm` CLI. You need `python3`. The script makes its own virtual environment in `build/`. The app takes about 15 to 30 seconds to start, so these tests are slower than the unit tests. Do not run them before every commit. Run them when you change panes, sessions, layouts or the control socket.

## Pull requests

- Keep each change small and focused. Put unrelated work in separate commits or separate PRs.
- Write each commit subject as `<type>: <description>`. For example: `fix: option key reaches terminal programs as alt modifier`. The types are `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`, `style`, `build`, `ci` and `revert`.
- Do not add AI sign-off lines to commits, such as `Co-Authored-By: Claude`.
- **PRs merge by squash.** Write the PR title as a good squash subject.
- If your PR conflicts with `main`, **merge `main` into your branch**. Do not rebase the branch onto `main`.
- A bot adds the `area:*` labels from the files that you change. A maintainer adds the type label: `enhancement`, `bug`, `chore` or `documentation`. The type label decides the section of the release notes for your PR.
- xcodegen generates the Xcode project from [`project.yml`](project.yml). Do not edit `Macterm.xcodeproj/`. Git ignores it, and the next generation removes your changes.

## Docs

- `CLAUDE.md` is a symlink to [`AGENTS.md`](AGENTS.md). Edit `AGENTS.md`.
- The user docs are in [`website/docs/pages/`](website/docs/pages). Each page is one Markdown file. To build and serve the site on your Mac, run `cd website && bun install && bun run dev`. You need [Bun](https://bun.sh) and [Caddy](https://caddyserver.com).
- Write all text in ASD-STE100 style. Read [`WRITING.md`](WRITING.md) for the Macterm word list.

## Reporting issues

Report issues at https://github.com/thdxg/macterm/issues. Include the steps to reproduce the problem and your macOS version. Run `mise run logs --last 30m` to get the related log output.

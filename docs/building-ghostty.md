# GhosttyKit

Macterm depends on libghostty compiled as a static library inside `GhosttyKit.xcframework/`. The xcframework is built and released via GitHub Actions on the [macterm-app/ghostty](https://github.com/macterm-app/ghostty) fork.

## Local Setup

```bash
scripts/setup.sh
```

This downloads the latest pre-built `GhosttyKit.xcframework` from the fork's releases and syncs the header into `GhosttyKit/ghostty.h`.

## Rebuilding GhosttyKit

To build a new version of the xcframework (e.g. after ghostty updates):

1. Go to [macterm-app/ghostty Actions](https://github.com/macterm-app/ghostty/actions)
2. Run the "Build GhosttyKit" workflow
3. Once complete, re-run `scripts/setup.sh` locally (delete the old xcframework first)

```bash
rm -rf GhosttyKit.xcframework
scripts/setup.sh
```

## How it works

1. The fork's "Build GhosttyKit" workflow builds libghostty with Zig on a macOS runner
2. It produces a universal xcframework (arm64 + x86_64) and publishes it as a GitHub release
3. `scripts/setup.sh` downloads the latest release and extracts it
4. `Package.swift` links against `GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a`

## Syncing the fork

The fork auto-syncs from upstream ghostty daily via the "Sync Upstream" workflow.

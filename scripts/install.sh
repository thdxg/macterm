#!/usr/bin/env bash
set -euo pipefail

rm -rf /Applications/Macterm.app
ditto ./build/Macterm.app /Applications/Macterm.app

codesign --verify --deep --strict --verbose=2 /Applications/Macterm.app

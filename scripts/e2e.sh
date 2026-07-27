#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
VENV="$PROJECT_ROOT/build/e2e-venv"

# Ensure GhosttyKit + bundled resources are present before xcodegen resolves
# the folder references. Idempotent; no-op in CI where setup already ran.
"$PROJECT_ROOT/scripts/setup.sh"

xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

# Debug configuration: correctness, not performance, is under test — and it
# shares CI's Debug DerivedData cache with the unit-test job instead of
# paying for a second Release build. (MACTERM_BENCHMARK, which the harness
# uses for headless control, is env-gated, so it works in any configuration.)
xcodebuild \
  -project Macterm.xcodeproj \
  -scheme Macterm \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  ONLY_ACTIVE_ARCH=YES \
  build \
  | (xcbeautify --quiet 2>/dev/null || cat)

# pytest lives in a project-local venv (stdlib venv + pip) so the suite needs
# no system-wide Python packages. Idempotent, cached under build/. Pinned for
# the same reason mise.toml pins tools: test-runner output is part of the CI
# contract, and a floating version can flip main red on untouched code.
if [ ! -x "$VENV/bin/pytest" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet pytest==8.4.1
fi

"$VENV/bin/pytest" e2e -v \
  --app "$DERIVED_DATA/Build/Products/Debug/Macterm.app"

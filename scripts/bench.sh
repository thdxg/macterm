#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
OUT_DIR="$PROJECT_ROOT/build/benchmark"

# Ensure GhosttyKit + bundled resources are present before xcodegen resolves
# the folder references. Idempotent; no-op in CI where setup already ran.
"$PROJECT_ROOT/scripts/setup.sh"

xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

# Release configuration so the numbers reflect what ships. ONLY_ACTIVE_ARCH
# skips the other half of the universal binary — the benchmark only runs on
# the build machine's own arch.
xcodebuild \
  -project Macterm.xcodeproj \
  -scheme Macterm \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ONLY_ACTIVE_ARCH=YES \
  build \
  | (xcbeautify --quiet 2>/dev/null || cat)

# On top of the idle states, BENCH_WORKLOAD busy tabs (2x2 grids spawned via
# the bundled macterm CLI) are sampled as workload-* states; 0 skips them.
python3 "$PROJECT_ROOT/scripts/benchmark.py" run \
  --app "$DERIVED_DATA/Build/Products/Release/Macterm.app" \
  --out "$OUT_DIR/results.json" \
  --seconds "${BENCH_SECONDS:-30}" \
  --workload "${BENCH_WORKLOAD:-2}"

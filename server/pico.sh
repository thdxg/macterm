#!/usr/bin/env bash
set -xeo pipefail

# This is a little experiement seeing how we could use zmx as a job engine for CI

export ZMX_SESSION_PREFIX="ci-"

zmx run build podman build -t zig .

zmx run fmt -d podman run --rm -it -v "$(pwd)":/app zig zig fmt --check .
zmx run test -d podman run --rm -it -v "$(pwd)":/app zig zig build test --summary all
zmx run integration -d podman run --rm -it -v "$(pwd)":/app zig zig build test-integration
zmx wait "*"

zmx kill "*"
echo "success!"

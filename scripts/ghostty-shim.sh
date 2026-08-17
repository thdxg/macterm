#!/bin/sh
# Macterm's stand-in for the ghostty CLI, bundled at
# Contents/Resources/ssh-bridge/ghostty by the "Bundle macterm CLI"
# post-build step.
#
# MactermConfig.regenerate points GHOSTTY_BIN_DIR here, and the bundled
# shell-integration `ssh` wrapper (the ssh-env/ssh-terminfo features) execs
# "$GHOSTTY_BIN_DIR/ghostty" +ssh -- an action this shim serves natively via
# `macterm ssh`, so those features work with no Ghostty.app installed. It
# implements nothing else, which is why it lives in its own directory rather
# than Resources/bin or Contents/MacOS: both of those land on pane PATHs
# (EnvironmentSetup prepends bin; libghostty appends the exe dir), and a bare
# `ghostty` that only answers +ssh must never be reachable by name.
if [ "$1" != "+ssh" ]; then
  echo "this is Macterm's ghostty shim; only +ssh is supported (install Ghostty.app for the real CLI)" >&2
  exit 1
fi
shift
exec "$(dirname "$0")/../bin/macterm" ssh "$@"

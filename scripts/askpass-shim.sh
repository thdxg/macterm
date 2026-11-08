#!/bin/sh
# The SSH_ASKPASS of a host's ssh master in Macterm (SSHMasters), bundled at
# Contents/Resources/ssh-bridge/macterm-askpass by the "Bundle macterm CLI"
# post-build step. ssh runs askpass with one argument, the prompt, and
# SSH_ASKPASS takes a program and no arguments, so this shim adds the verb.
#
# It must exec: the app answers only a process whose parent is its ssh
# (LOCAL_PEERPID), and exec keeps this pid for `macterm askpass`.
exec "$(dirname "$0")/../bin/macterm" askpass "$@"

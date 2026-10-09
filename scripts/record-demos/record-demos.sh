#!/bin/bash
# Record the feature demos the website plays — keyboard-driven, no cursor.
#
#   ./scripts/record-demos/record-demos.sh check          preflight only
#   ./scripts/record-demos/record-demos.sh all            record every demo
#   ./scripts/record-demos/record-demos.sh 1 3            record only those demos
#   ./scripts/record-demos/record-demos.sh web            re-encode them into assets/demo/
#   ./scripts/record-demos/record-demos.sh remote-up [password]  bring the ssh container up alone
#   ./scripts/record-demos/record-demos.sh remote-down    and tear it down
#   ./scripts/record-demos/record-demos.sh quick-prefs    set the quick-terminal geometry (needs an app restart)
#   ./scripts/record-demos/record-demos.sh quick-restore  put that geometry back
#   ./scripts/record-demos/record-demos.sh anim-prefs     turn every animation on (needs an app restart)
#   ./scripts/record-demos/record-demos.sh anim-restore   put the animation settings back
#   ./scripts/record-demos/record-demos.sh claude-up      start demo 7's offline Claude Code alone
#   ./scripts/record-demos/record-demos.sh claude-down    and stop it
#   ./scripts/record-demos/record-demos.sh scroll-test    one trackpad scroll into the window, to check direction
#
# It drives the INSTALLED app (/Applications/Macterm.app) through synthetic
# keystrokes, so it needs Accessibility and Screen Recording granted to
# whatever runs it, ffmpeg on PATH, podman for demos 5 and 10, and `claude` (Claude
# Code) on PATH for demo 7 — which runs it against a local stand-in for the
# API, so no account and no network are involved.
#
# You place the Macterm window; the script refuses to record until it sits at
# the canonical rect below, so every clip lines up. The capture region includes
# a margin of wallpaper around the window, so nothing else may be on screen
# behind it: under a tiling window manager (AeroSpace) give Macterm a workspace
# of its own for the session and float it there. Recordings go to
# $MACTERM_DEMOS_OUT (default ~/Desktop/macterm-demos); `web` is the only step
# that writes into the repo.
#
# Demos: 1 splits · 2 sidebar and tabs · 3 command palette and layouts ·
#        4 quick terminal · 5 remote project (podman) · 6 tab switcher ·
#        7 animations (Claude Code scrollback, a split, the cursor in Helix) ·
#        8 a folder dropped on the Dock tile · 9 desktop widgets beside the
#        system's · 10 saving and autofilling an ssh password (podman) ·
#        11 a custom palette: a Git palette's nested screens and a run action
set -euo pipefail

# ---------------------------------------------------------------- constants --
# where you put the window (points): right of the desktop widgets in the
# top-left columns (the system's and a Macterm one reaching column 6) and
# below the desktop icons in the top-right corner, so the frame shows neither
WIN_X=1330 WIN_Y=411 WIN_W=1600 WIN_H=870
MARGIN=40                                   # wallpaper visible around it
TOLERANCE=6                                 # slack when checking the rect

REGION_X=$((WIN_X - MARGIN)) REGION_Y=$((WIN_Y - MARGIN))
REGION_W=$((WIN_W + MARGIN * 2)) REGION_H=$((WIN_H + MARGIN * 2))

# the quick-terminal panel, centred in the same frame at 75% of the window
QT_W=1200 QT_H=640
QT_X=$((WIN_X + (WIN_W - QT_W) / 2)) QT_Y=$((WIN_Y + (WIN_H - QT_H) / 2))

# The ephemeral "remote host" demo 5 records against. RHOST is an ssh alias
# this script installs in ~/.ssh/config and removes again afterwards. The block
# is prepended, so it wins even if a host of the same name is already there,
# and remote_up refuses to record unless the alias answers with the image's
# own marker — a name collision can never point the demo at a real machine.
RHOST=demo-box
RUSER=demo
RPORT=2222
CNAME=macterm-demo          # the container's own name (podman)
RIMAGE=macterm-demo-remote
RDIR=/workspace
RMARKER=macterm-demo-container   # /etc/macterm-demo, baked into the image
RPASSWORD=tidepool42lantern      # demo 10 types it, key by key: lowercase and digits only

# Demo 7's Claude Code talks to a mock of the API on this port (claude-mock/
# server.py), started by claude_up. The scrolling it shows arrived with the
# GhosttyKit in 1.29.3 (and the tip builds just before it); an older app
# records the same keystrokes with nothing moving, so claude_up checks the
# installed binary for that kit rather than trusting a version string.
CLAUDE_PORT=8765
ANIM_KIT_SYMBOL=ghost_rows       # a shader uniform only the new kit has

# Demo 11's palette. The installed app reads the extensions in
# ~/.config/macterm/extensions/ again each time that the palette opens. The
# take therefore writes its own extension there, with a name of its own. Its
# extension.yaml has PAL_MARK as its first line. The EXIT trap below removes
# the extension (and only a folder with the mark), however the run ends.
EXT_ROOT="$HOME/.config/macterm/extensions"
PAL_EXT="$EXT_ROOT/macterm-demo-git"
PAL_MANIFEST="$PAL_EXT/extension.yaml"
PAL_FILE="$PAL_EXT/palettes/git.yaml"
PAL_MARK="# written by record-demos.sh for demo 11; removed when the take ends"

MACTERM=/Applications/Macterm.app/Contents/Resources/bin/macterm
# opencode offers its own update in a dialog over the TUI when one is out,
# which is not what demos 2 and 6 are about (the prefix is nushell's syntax,
# and every POSIX shell's)
OPENCODE="OPENCODE_DISABLE_AUTOUPDATE=1 opencode"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# Masters and finished clips are hundreds of megabytes and are not repo
# content, so they land outside it. Only `web` writes into the tree, and only
# the small re-encodes the site actually serves.
OUT="${MACTERM_DEMOS_OUT:-$HOME/Desktop/macterm-demos}"
WORK="$OUT/.work"; RAW="$WORK/raw"
mkdir -p "$RAW"

say() { printf '\033[1m==\033[0m %s\n' "$*"; }
die() { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\033[31m!!\033[0m aborted at line %s\n" "$LINENO" >&2' ERR
# however the run ends, a desktop demo 8 rearranged is put back
trap '[ -f "$WORK/desktop-view.plist" ] && { desk_view restore; killall Finder 2>/dev/null; }; [ -f "$WORK/create-desktop.was" ] && desk_icons restore; [ "$(head -n 1 "$PAL_MANIFEST" 2>/dev/null)" = "$PAL_MARK" ] && rm -rf "$PAL_EXT"; true' EXIT

# ------------------------------------------------------------------ helpers --
osa() { osascript -e "$1"; }
sysev() { osa "tell application \"System Events\" $1"; }

screen_size() {  # points, "W H"
  osascript -l JavaScript -e 'ObjC.import("AppKit"); var f=$.NSScreen.mainScreen.frame.size; f.width+" "+f.height'
}
visible_size() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); var v=$.NSScreen.mainScreen.visibleFrame.size; v.width+" "+v.height'
}
park_cursor() {  # bottom-right corner, outside every capture region
  read -r sw sh <<< "$(screen_size)"
  osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGWarpMouseCursorPosition(\$.CGPointMake($sw-18, $sh-12)); 'ok'" >/dev/null
}
window_rect() {  # "x y w h" of the main terminal window
  osa 'tell application "System Events" to tell process "Macterm"
        repeat with w in windows
          if name of w is not "" then
            set {p, s} to {position of w, size of w}
            return (item 1 of p as text) & " " & (item 2 of p as text) & " " & (item 1 of s as text) & " " & (item 2 of s as text)
          end if
        end repeat
      end tell'
}
# Is the quick terminal's panel up? By its size, not by counting windows:
# every desktop widget is a window of the process too.
qt_visible() {
  winlist | awk -F'|' -v w="$QT_W" -v h="$QT_H" '
    $1 == "Macterm" && ($5 - w) ^ 2 <= 64 && ($6 - h) ^ 2 <= 64 { found = 1 } END { exit !found }'
}

# Always address the terminal window by name: the quick-terminal panel is an
# unnamed window of the same process and is often window 1.
set_window_rect() {  # set_window_rect <x> <y> <w> <h>
  # position and size go one at a time: setting both on a loop reference is
  # refused with -10003
  osa "tell application \"System Events\" to tell process \"Macterm\"
         repeat with w in windows
           if name of w is not \"\" then
             set position of w to {$1, $2}
             set size of w to {$3, $4}
             return
           end if
         end repeat
       end tell" >/dev/null 2>&1 || true
}
near() { [ "$(( $1 - $2 ))" -le "$TOLERANCE" ] && [ "$(( $2 - $1 ))" -le "$TOLERANCE" ]; }

focus_app() { sysev 'to set frontmost of process "Macterm" to true' >/dev/null 2>&1 || true; }

# --------------------------------------------------------------- preflight ---
preflight() {
  command -v ffmpeg >/dev/null || die "ffmpeg not found (brew install ffmpeg)"
  [ -x "$MACTERM" ] || die "bundled CLI missing: $MACTERM"
  "$MACTERM" status >/dev/null || die "Macterm is not running"

  read -r wx wy ww wh <<< "$(window_rect)"
  if ! { near "$wx" $WIN_X && near "$wy" $WIN_Y && near "$ww" $WIN_W && near "$wh" $WIN_H; }; then
    cat >&2 <<EOF
!! window is at ${wx},${wy} ${ww}x${wh} — needs ${WIN_X},${WIN_Y} ${WIN_W}x${WIN_H}

   Put it there (it must be floating, not tiled), e.g.:

     aerospace layout floating
     osascript -e 'tell application "System Events" to tell process "Macterm" \\
       to tell window 1 to set {position, size} to {{$WIN_X, $WIN_Y}, {$WIN_W, $WIN_H}}'
EOF
    exit 1
  fi
  say "window ${wx},${wy} ${ww}x${wh}  →  capture ${REGION_X},${REGION_Y} ${REGION_W}x${REGION_H}"
  # the clips show the window taking on the running program's background
  [ "$(defaults read com.thdxg.macterm macterm.window.adaptiveTerminalChromeEnabled 2>/dev/null)" = 1 ] \
    || die "adaptive background is off — turn it on (Settings → Appearance), or: defaults write com.thdxg.macterm macterm.window.adaptiveTerminalChromeEnabled -bool true, then relaunch"

  local shown; shown="$(shown_repo)"
  if [ -n "$shown" ] && ! git -C "$shown" diff --quiet -- AGENTS.md; then
    die "$shown/AGENTS.md has uncommitted edits — demo 1 shows that file. git restore it first."
  fi
  say "preflight ok — leave the mouse alone while it records"
}

# the avfoundation screen index moves when Continuity cameras come and go
screen_device() {
  # ffmpeg always exits non-zero when it is only listing devices
  { ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true; } \
    | awk -F'[][]' '/Capture screen 0/ {print $4; exit}'
}

# ------------------------------------------------------------- the driver ----
write_lib() {
  cat > "$WORK/lib.applescript" <<'EOF'
on kc(c, mods)
	tell application "System Events" to key code c using mods
end kc
on kcp(c)
	tell application "System Events" to key code c
end kcp
on ks(s, mods)
	tell application "System Events" to keystroke s using mods
end ks
on typeText(s, d)
	repeat with i from 1 to (count of s)
		tell application "System Events" to keystroke (character i of s)
		delay d
	end repeat
end typeText
on typeLine(s, d)
	typeText(s, d)
	delay 0.35
	tell application "System Events" to key code 36
end typeLine
EOF
  cat > "$WORK/type.applescript" <<'EOF'
on run argv
	set s to item 1 of argv
	set d to (item 2 of argv) as real
	repeat with i from 1 to (count of s)
		tell application "System Events" to keystroke (character i of s)
		delay d
	end repeat
end run
EOF
}

# ------------------------------------------------------- keyboard + prompt --
# Chords go by key code, which is what a real keyboard sends and keeps every
# awkward character (\, ], `) out of the AppleScript string.
CMD="command down"; SHIFT="shift down"; CTRL="control down"
K_RET=36 K_ESC=53 K_D=2 K_T=17 K_P=35 K_W=13
K_H=4 K_J=38 K_K=40 K_L=37 K_RBRACK=30 K_LBRACK=33 K_BSLASH=42 K_BACKTICK=50

kc() {  # kc <keycode> [modifier list]
  if [ -n "${2:-}" ]; then
    osa "tell application \"System Events\" to key code $1 using {$2}" >/dev/null
  else
    osa "tell application \"System Events\" to key code $1" >/dev/null
  fi
}
ktype() { osascript "$WORK/type.applescript" "$1" "${2:-0.05}" >/dev/null; }
kline() { ktype "$1" "${2:-0.05}"; sleep 0.3; kc $K_RET; }

# Type a command only once the pane is actually showing a prompt — a fixed
# delay races ssh on the remote demo, and a command typed into a pane that is
# still connecting lands with no prompt in front of it.
prompt_now() {  # is this pane showing a shell prompt right now?
  local last
  # a pane with no surface yet answers with an error, which is just "not
  # ready" — and must not take the script down through pipefail
  last="$( { "$MACTERM" pane dump "$@" 2>/dev/null || true; } | awk 'NF {l = $0} END {print l}' )"
  case "$last" in
    *'$'|*'$ '|*'#'|*'# '|*'%'|*'% '|*'⟩'|*'⟩ '|*'❯'|*'❯ ') return 0 ;;
  esac
  return 1
}

wait_prompt() {  # wait_prompt [pane dump selectors...]
  local i=0
  while [ $i -lt 60 ]; do
    prompt_now "$@" && { sleep 0.25; return 0; }
    # A remote pane starts up blank: the shell printed its prompt before zmx
    # had a client, so the screen stays empty until something writes again.
    # Ctrl-L asks the shell for a fresh one. A local pane never gets here —
    # its prompt is already on screen at the first check.
    [ $((i % 6)) -eq 5 ] && kc $K_L "$CTRL"
    sleep 0.25; i=$((i + 1))
  done
  printf '\033[33m..\033[0m no prompt after 15s, typing anyway\n'
}

# record <name> <driver-function> [region] [noactivate]
# The driver sets the pace (it waits on prompts), so capture stops when the
# driver returns plus a tail; -t is only a safety net. The cursor is left out
# of every clip unless CAPTURE_CURSOR=1 — the demos about a mouse gesture —
# and then it is also left where the demo put it, instead of parked.
CAPTURE_CURSOR=0
record() {
  local name="$1" driver="$2" region="${3:-$REGION_X,$REGION_Y,$REGION_W,$REGION_H}" mode="${4:-}" dur=180
  local rx ry rw rh; IFS=, read -r rx ry rw rh <<< "$region"
  local out="$RAW/$name.mov" log="$RAW/$name.log"
  local dev; dev="$(screen_device)"; [ -n "$dev" ] || die "no screen-capture device"
  rm -f "$out"
  [ "$CAPTURE_CURSOR" = 1 ] || park_cursor
  if [ "$mode" = quiet ]; then
    # focus, but type nothing: the pane is showing a program (Claude Code)
    # for which the Escape/Return settle below would be input
    focus_app; sleep 0.8
  elif [ "$mode" != noactivate ]; then
    focus_app
    # settle before the camera rolls: Escape clears a stray palette or alert,
    # and the empty Return hands a vi-mode line editor back to insert mode
    sleep 0.4; sysev 'to key code 53' >/dev/null
    sleep 0.3; sysev 'to key code 53' >/dev/null
    sleep 0.3; sysev 'to key code 36' >/dev/null
    sleep 0.5
    # that Return leaves an empty prompt on screen; clear it, but ONLY when a
    # shell is focused — in an editor those keys would be commands, not text
    local last
    last="$( { "$MACTERM" pane dump 2>/dev/null || true; } | awk 'NF {l = $0} END {print l}' )"
    case "$last" in
      *'$'|*'$ '|*'#'|*'# '|*'%'|*'% '|*'⟩'|*'⟩ '|*'❯'|*'❯ ')
        ktype "clear" 0.01; kc $K_RET; sleep 0.6 ;;
    esac
  fi
  sleep 0.8
  # the hardware H.264 encoder stops at 4096 pixels wide, so a frame too wide
  # to keep at 2x (demo 9's full-height desktop) is captured at 1x
  local fit=""; [ $((rw * 2)) -gt 4096 ] && fit=",scale=$rw:$rh"
  ffmpeg -hide_banner -loglevel warning -f avfoundation -capture_cursor "$CAPTURE_CURSOR" -framerate 60 \
    -i "$dev:none" -t "$dur" -vf "crop=$((rw*2)):$((rh*2)):$((rx*2)):$((ry*2))$fit" \
    -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p "$out" >"$log" 2>&1 &
  local ff=$! waited=0
  while [ ! -s "$out" ]; do
    sleep 0.1; waited=$((waited+1))
    [ $waited -gt 100 ] && { cat "$log" >&2; kill $ff 2>/dev/null; die "capture never started"; }
  done
  local t0 s e; t0=$(date +%s.%N); sleep 1.0; s=$(date +%s.%N)
  "$driver"
  e=$(date +%s.%N)
  sleep 1.5                      # tail, then stop rather than wait out -t
  kill -INT $ff 2>/dev/null || true
  wait $ff 2>/dev/null || true
  python3 - "$name" "$t0" "$s" "$e" <<'PY' > "$RAW/$name.trim"
import sys
name, t0, s, e = sys.argv[1], *map(float, sys.argv[2:5])
print("%.2f %.2f" % (max(0.0, s - t0 - 0.8), e - t0 + 1.0))
PY
  say "captured $name ($(cut -d' ' -f2 < "$RAW/$name.trim")s of action)"
}

encode() {  # encode <name> <outfile>
  local name="$1" file="$2" start end
  read -r start end < "$RAW/$name.trim"
  ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$RAW/$name.mov" \
    -vf "scale=$REGION_W:$REGION_H:flags=lanczos" -c:v libx264 -preset slow -crf 20 \
    -pix_fmt yuv420p -movflags +faststart -an "$OUT/$file" -y
  say "wrote $file"
}

# helix auto-saves on focus loss, so a keystroke that lands in an editor pane
# is written to disk. Only the files a demo actually OPENS belong here — a
# blanket list reverts unrelated work in passing.
# The checkout is the macterm PROJECT's, the one its panes open files in —
# not necessarily the one this script runs from (a worktree, say).
shown_repo() {
  local dir
  dir="$("$MACTERM" project list 2>/dev/null | awk '$2 == "macterm" || $3 == "macterm" { print $NF; exit }')"
  git -C "${dir:-$REPO}" rev-parse --show-toplevel 2>/dev/null || true
}
guard_repo() {
  local repo f; repo="$(shown_repo)"
  [ -n "$repo" ] || return 0
  for f in AGENTS.md; do
    if ! git -C "$repo" diff --quiet -- "$f"; then
      git -C "$repo" restore "$f"
      printf '\033[33m..\033[0m stray edit to %s reverted\n' "$repo/$f"
    fi
  done
}

reset_project() {  # one empty tab in the macterm project
  local n=0
  while "$MACTERM" tab list --project macterm 2>/dev/null | grep -q '^tab:'; do
    "$MACTERM" tab close 1 --project macterm --force >/dev/null 2>&1 || break
    sleep 0.7
    n=$((n + 1)); [ $n -gt 12 ] && break
  done
  # the shell in a brand-new pane drops keystrokes typed before its line
  # editor is up, so give it room before anything types into it
  "$MACTERM" tab new --project macterm >/dev/null; sleep 4
  "$MACTERM" project select macterm >/dev/null; sleep 0.5
}

# ------------------------------------------------------------------ demos ----
# Each demo is a driver run while the camera rolls. Anything typed into a shell
# goes through wait_prompt first, so a command never lands in a pane that is
# still starting (or, on the remote, still connecting).

drive1() {
  sleep 0.6
  wait_prompt;                kline "hx AGENTS.md" 0.055
  sleep 1.4
  kc $K_D "$CMD"; sleep 0.6                        # split (split-auto)
  wait_prompt --pane 2;       kline "macterm tutor" 0.055
  sleep 1.4
  kc $K_D "$CMD"; sleep 0.6
  wait_prompt --pane 3;       kline "git --no-pager log --oneline -12" 0.05
  sleep 1.5
  kc $K_K "$CMD, $CTRL"; sleep 0.7                 # focus up
  kc $K_H "$CMD, $CTRL"; sleep 0.7                 # left
  kc $K_L "$CMD, $CTRL"; sleep 0.7                 # right
  kc $K_J "$CMD, $CTRL"; sleep 0.9                 # down
  kc $K_RET "$CMD, $SHIFT"; sleep 1.5              # zoom
  kc $K_RET "$CMD, $SHIFT"; sleep 1.1              # unzoom
  local i; for i in 1 2 3 4; do kc $K_H "$CMD, $SHIFT"; sleep 0.25; done
  sleep 0.9
  kc $K_W "$CMD"; sleep 1.6                        # close the pane
}

demo1() {  # splits, keyboard navigation, zoom, resize, close
  say "demo 1 — splits and navigation"
  reset_project
  record splits drive1
  guard_repo
  encode splits 01-splits-and-navigation.mp4
}

drive2() {
  sleep 0.6
  kc $K_BSLASH "$CMD"; sleep 1.4                   # sidebar away
  kc $K_BSLASH "$CMD"; sleep 1.3                   # and back
  kc $K_RBRACK "$CTRL"; sleep 2.0                  # to the opencode tab
  kc $K_BSLASH "$CMD"; sleep 2.2                   # full-screen TUI
  kc $K_BSLASH "$CMD"; sleep 1.6
  kc $K_LBRACK "$CTRL"; sleep 1.6                  # back to the editor
}

demo2() {  # sidebar toggle, including over a full-screen TUI, across tabs
  say "demo 2 — sidebar and tabs"
  reset_project
  "$MACTERM" pane run "hx AGENTS.md" >/dev/null; sleep 3
  "$MACTERM" tab new --project macterm --run "$OPENCODE" >/dev/null; sleep 8
  "$MACTERM" tab select 1 --project macterm >/dev/null; sleep 1.5
  record sidebar-tabs drive2
  guard_repo
  encode sidebar-tabs 02-sidebar-and-tabs.mp4
}

# Demo 3 opens a directory as a new project from the palette. Everything it
# cleans up is matched by that directory's PATH, never by name: a project of
# yours may share the name (a `website` of your own was nearly removed once).
D3_DIR="$HOME/dev/macterm/website/docs"
D3_NAME="$(basename "$D3_DIR")"
d3_cleanup() {
  local n
  n="$("$MACTERM" project list 2>/dev/null | awk -v p="$D3_DIR" '$NF == p { sub("project:", "", $1); print $1; exit }')"
  [ -n "$n" ] && "$MACTERM" project remove "$n" --force >/dev/null 2>&1 || true
  local short="~${D3_DIR#"$HOME"}" f
  for f in "$HOME"/.config/macterm/projects/*.yaml; do
    [ -f "$f" ] || continue
    grep -Eq "^path: *['\"]?($D3_DIR|$short)['\"]? *$" "$f" && rm -f "$f"
  done
  return 0
}

drive3() {
  sleep 0.6
  kc $K_P "$CMD"; sleep 0.9
  ktype "~${D3_DIR#"$HOME"}" 0.045; sleep 1.0
  kc $K_RET; sleep 1.8                             # opens it as a new project
  wait_prompt --project "$D3_NAME" --pane 1
  kc $K_D "$CMD"; sleep 0.6
  wait_prompt --project "$D3_NAME" --pane 2;  kline "ls pages" 0.045
  sleep 1.4
  kc $K_P "$CMD"; sleep 0.9
  ktype "save layout" 0.05; sleep 0.9
  kc $K_RET; sleep 1.6
  kc $K_D "$CMD"; sleep 1.0                        # wander off the saved shape
  kc $K_D "$CMD"; sleep 1.2
  kc $K_P "$CMD"; sleep 0.9
  ktype "apply layout" 0.05; sleep 0.9
  kc $K_RET; sleep 1.1
  kc $K_RET; sleep 2.2                             # confirm "Apply layout?"
}

demo3() {  # command palette: new project, save layout, modify, apply layout
  say "demo 3 — command palette and layouts"
  [ -d "$D3_DIR" ] || die "$D3_DIR is missing"
  d3_cleanup
  "$MACTERM" project select macterm >/dev/null; "$MACTERM" tab select 1 --project macterm >/dev/null
  sleep 1.5
  record palette-layouts drive3
  guard_repo
  encode palette-layouts 03-command-palette-and-layouts.mp4
  d3_cleanup                                       # leave the tree as we found it
}

# The panel's panes are not addressable through the CLI (it resolves panes
# inside projects, and the quick terminal is not one), so this demo cannot
# wait on a prompt the way the others do — its panes are long-lived idle
# shells that already show one, and the split's new shell gets a fixed beat.
qt_ready() {  # the panel must be up AND Macterm frontmost, or a keystroke
              # would land in whatever app is — Finder renames files with it
  local fm; fm="$(osa 'tell application "System Events" to get name of first process whose frontmost is true')"
  qt_visible && [ "$fm" = "Macterm" ] && return 0
  printf '\033[31m!!\033[0m quick terminal not focused (front: %s) — not typing\n' "$fm" >&2
  return 1
}

drive4() {
  sleep 1.0
  kc $K_BACKTICK "$CTRL"; sleep 1.3                # summon
  qt_ready || return 0
  kline "macterm --help" 0.055
  sleep 1.8
  kc $K_D "$CMD"; sleep 1.7                        # split inside the panel
  qt_ready || return 0
  kline "macterm tutor" 0.055
  sleep 1.8
  kc $K_BACKTICK "$CTRL"; sleep 1.4                # dismiss
  kc $K_BACKTICK "$CTRL"; sleep 1.8                # summon again, still there
  kc $K_BACKTICK "$CTRL"; sleep 1.4
}

demo4() {  # quick terminal: summon, split, dismiss, summon again
  say "demo 4 — quick terminal"
  focus_app; sleep 0.4
  if qt_visible; then                              # start from hidden
    kc $K_BACKTICK "$CTRL"; sleep 1.2
  fi
  # Park the terminal window off-screen rather than closing it. The panel is
  # a non-activating overlay: with no window at all Macterm cannot be the
  # frontmost app, and every keystroke meant for the panel would go to the
  # app that is. Parked, it keeps the app frontmost and stays out of frame.
  local sw sh; read -r sw sh <<< "$(screen_size)"
  local px=$((${sw%.*} - 108)) py=$((${sh%.*} - 92))
  set_window_rect "$px" "$py" "$WIN_W" "$WIN_H"
  focus_app; sleep 0.8
  record quick-terminal drive4
  encode quick-terminal 04-quick-terminal.mp4
  # close the pane this demo added, leaving the panel as it was
  sleep 0.5
  if ! qt_visible; then kc $K_BACKTICK "$CTRL"; sleep 1.5; fi
  if qt_ready; then
    kc $K_W "$CMD"; sleep 1.2
    ktype "clear" 0.02; kc $K_RET; sleep 0.6
  fi
  kc $K_BACKTICK "$CTRL"; sleep 1
  # and put the window back where you had it
  set_window_rect "$WIN_X" "$WIN_Y" "$WIN_W" "$WIN_H"
  sleep 0.5
}

drive5() {
  sleep 0.6
  kc $K_P "$CMD"; sleep 0.9
  ktype "demo@demo-box:/workspace" 0.045; sleep 1.0
  kc $K_RET                                        # ssh connects while we wait
  wait_prompt --project workspace --pane 1;  kline "uname -sr && ls" 0.05
  sleep 1.6
  kc $K_D "$CMD"; sleep 0.6                        # a second remote pane
  wait_prompt --project workspace --pane 2;  kline "cat README.md" 0.05
  sleep 1.8
  kc $K_T "$CMD"; sleep 0.8                        # a second remote tab
  wait_prompt --project workspace --tab 2 --pane 1; kline "vim src/server.c" 0.05
  sleep 2.8
}

demo5() {  # a remote project: ssh host, splits, a second tab, vim
  say "demo 5 — remote project"
  remote_up
  "$MACTERM" project remove workspace --force >/dev/null 2>&1 || true
  reset_project
  record remote-project drive5
  encode remote-project 05-remote-project.mp4
  remote_down
  "$MACTERM" project select macterm >/dev/null 2>&1 || true
}

# ----------------------------------------------------- the ephemeral host ----
# A container with sshd, vim and zmx. Macterm's remote panes are zmx sessions
# ON THE HOST, and zmx ships macOS binaries only, so the image builds it from
# source — slow once, cached after.
remote_up() {  # remote_up [key|password] — how the pane's ssh logs in
  local auth="${1:-key}" dir="$HERE/remote"
  [ -f "$dir/Containerfile" ] || die "missing $dir/Containerfile"
  command -v podman >/dev/null || die "podman not found (brew install podman)"
  if ! podman info >/dev/null 2>&1; then
    say "starting the podman machine"
    podman machine start >/dev/null 2>&1 || true
    local i=0
    until podman info >/dev/null 2>&1; do
      sleep 2; i=$((i + 1)); [ $i -gt 45 ] && die "the podman machine did not come up (podman machine init?)"
    done
  fi
  if [ ! -f "$dir/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -C "$RHOST" -f "$dir/id_ed25519" >/dev/null
  fi
  cp "$dir/id_ed25519.pub" "$dir/authorized_keys"
  chmod 600 "$dir/id_ed25519"
  say "building $RIMAGE (first run compiles zmx: ~3 min)"
  podman build -q --build-arg DEMO_PASSWORD="$RPASSWORD" -t "$RIMAGE" -f "$dir/Containerfile" "$dir" >/dev/null
  podman rm -f "$CNAME" >/dev/null 2>&1 || true
  # the prompt inside the pane should read like the host the demo names
  podman run -d --name "$CNAME" --hostname "$RHOST" \
    -p "127.0.0.1:$RPORT:22" "$RIMAGE" >/dev/null

  # the pane's ssh and every background probe use the user's own client, so
  # the connection details have to live in ~/.ssh/config — first, since ssh
  # keeps the first value it finds for each keyword. Rewritten every time,
  # because the two demos want different logins from the same alias.
  local cfg="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"; touch "$cfg"; chmod 600 "$cfg"
  remove_ssh_block
  {
    echo "# >>> $RHOST (record-demos.sh) >>>"
    echo "Host $RHOST"
    # localhost, not 127.0.0.1: ssh names it in the password prompt demo 10
    # shows; IPv4 only, since the container is published on 127.0.0.1 alone
    echo "  HostName localhost"
    echo "  AddressFamily inet"
    echo "  Port $RPORT"
    echo "  User $RUSER"
    if [ "$auth" = password ]; then
      # demo 10 is about the password prompt, so the pane must get one: no
      # key, no agent, and no multiplexing — a second pane riding the first
      # one's connection would never ask
      echo "  PubkeyAuthentication no"
      echo "  PreferredAuthentications password"
      echo "  ControlMaster no"
      echo "  ControlPath none"
    else
      echo "  IdentityFile $dir/id_ed25519"
      echo "  IdentitiesOnly yes"
    fi
    echo "  StrictHostKeyChecking no"
    echo "  UserKnownHostsFile /dev/null"
    echo "  LogLevel ERROR"       # or every pane opens with a known-hosts warning
    echo "# <<< $RHOST (record-demos.sh) <<<"
    echo
    cat "$cfg"
  } > "$cfg.record-demos" && mv "$cfg.record-demos" "$cfg"
  chmod 600 "$cfg"

  local i=0
  until rssh true 2>/dev/null; do
    sleep 1; i=$((i + 1)); [ $i -gt 30 ] && { remote_down; die "$RHOST never answered ssh"; }
  done
  # never record against something that is not the container: the alias
  # shadows a real host of the same name, so this check is load-bearing
  local marker; marker="$(rssh 'cat /etc/macterm-demo 2>/dev/null' || true)"
  [ "$marker" = "$RMARKER" ] || { remote_down; die "$RUSER@$RHOST is not the demo container — aborting"; }
  say "remote host up ($RUSER@$RHOST, $auth login, $(rssh 'zmx --version | head -1'))"
}

# The recorder's own ssh: always the key, whatever the alias's block asks the
# pane to use (command-line options win over ~/.ssh/config), so the checks
# above go through the same alias — and so the same HostName — as the pane.
rssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 \
    -o PubkeyAuthentication=yes -o PreferredAuthentications=publickey \
    -o IdentityFile="$HERE/remote/id_ed25519" -o IdentitiesOnly=yes \
    "$RUSER@$RHOST" "$@"
}

remove_ssh_block() {
  grep -q "$RHOST (record-demos.sh)" "$HOME/.ssh/config" 2>/dev/null || return 0
  python3 - "$HOME/.ssh/config" "$RHOST" <<'PY2'
import re, sys
path, host = sys.argv[1], sys.argv[2]
text = open(path).read()
block = re.compile(r"\n?# >>> %s \(record-demos\.sh\) >>>.*?# <<< %s \(record-demos\.sh\) <<<\n?"
                   % (re.escape(host), re.escape(host)), re.S)
open(path, "w").write(block.sub("\n", text).lstrip("\n"))
PY2
}

remote_down() {
  # kill the project first: removing it ends the zmx sessions over ssh, which
  # needs the container still alive
  "$MACTERM" project remove workspace --force >/dev/null 2>&1 || true
  podman rm -f "$CNAME" >/dev/null 2>&1 || true
  remove_ssh_block
  say "remote host torn down"
}

# ------------------------------------------------------- website variants ----
# The landing page plays these inline, stacked, so they are re-encoded smaller
# than the masters and given a poster frame. Written straight into the repo's
# assets/, which website/public/assets symlinks (and the Dockerfile copies), so
# they are served at /assets/demo/… with no build step.
WEB_DIR="$REPO/assets/demo"
WEB_WIDTH=1400

web_assets() {
  command -v ffmpeg >/dev/null || die "ffmpeg not found"
  mkdir -p "$WEB_DIR"
  local pair name src out
  for pair in \
    "01-splits:01-splits-and-navigation" \
    "02-sidebar:02-sidebar-and-tabs" \
    "03-palette:03-command-palette-and-layouts" \
    "04-quick-terminal:04-quick-terminal" \
    "05-remote:05-remote-project" \
    "06-tab-switcher:06-tab-switcher" \
    "07-animations:07-animations" \
    "08-open-folder:08-open-folder" \
    "09-widgets:09-desktop-widgets" \
    "10-passwords:10-passwords" \
    "11-palettes:11-custom-palettes"
  do
    name="${pair%%:*}"; src="$OUT/${pair#*:}.mp4"
    [ -f "$src" ] || { printf '\033[33m..\033[0m no %s, skipping\n' "$src"; continue; }
    out="$WEB_DIR/$name"
    ffmpeg -hide_banner -loglevel error -i "$src" \
      -vf "scale=$WEB_WIDTH:-2:flags=lanczos" -c:v libx264 -preset slow -crf 26 \
      -pix_fmt yuv420p -movflags +faststart -an "$out.mp4" -y
    # poster: the first frame, so the stack has something to show before play.
    # ffmpeg here has no webp encoder, so it hands a PNG to cwebp.
    ffmpeg -hide_banner -loglevel error -ss 0.2 -i "$src" -frames:v 1 \
      -vf "scale=$WEB_WIDTH:-2:flags=lanczos" "$out.png" -y
    cwebp -quiet -q 78 "$out.png" -o "$out.webp"
    rm -f "$out.png"
    printf '   %-18s %5sKB mp4  %4sKB poster\n' "$name" \
      "$(( $(stat -f%z "$out.mp4") / 1024 ))" "$(( $(stat -f%z "$out.webp") / 1024 ))"
  done
  say "website assets written to $WEB_DIR"
}

# ── tab switcher ────────────────────────────────────────────────────────────
# The overlay lives exactly as long as the recent-tab chord's MODIFIER is held:
# AppState commits the cycle on the flags-changed event when it drops. System
# Events cannot hold a modifier across statements — `keystroke … using {control
# down}` presses and releases it with the key — so hold.js posts the events at
# CGEvent level instead, from osascript, which already holds the Accessibility
# grant those need.
recent_tab_chord() {
  defaults read com.thdxg.macterm macterm.hotkey.recent_tab 2>/dev/null || echo "ctrl+tab"
}

hold_cycle() {  # hold_cycle <taps> [seconds to leave the overlay up]
  local chord mod mask
  chord="$(recent_tab_chord)"
  case "$chord" in
    ctrl+tab)           mod=59; mask=262144 ;;
    shift+tab)          mod=56; mask=131072 ;;
    cmd+tab)            mod=55; mask=1048576 ;;
    alt+tab|option+tab) mod=58; mask=524288 ;;
    *)
      printf '\033[33m..\033[0m recent-tab is bound to %s; the switcher demo needs <modifier>+tab\n' "$chord"
      return 0 ;;
  esac
  osascript -l JavaScript "$HERE/hold.js" "$mod" "$mask" 48 "$1" 0.55 "${2:-1.2}" >/dev/null
}

drive6() {
  sleep 0.9
  hold_cycle 1 1.3      # one card over — the tab you were just in
  sleep 1.6
  hold_cycle 2 1.8      # the overlay stays up as long as the chord is held
  sleep 1.6
  hold_cycle 3 2.0
  sleep 1.7
}

demo6() {  # the tab switcher, over tabs that are actually doing something
  say "demo 6 — tab switcher"
  reset_project
  # A tab per kind of thing you would really have open, two of them split and
  # several redrawing on their own: the switcher's cards are LIVE previews, so
  # a set of still tabs would undersell the whole feature.
  "$MACTERM" pane run "btop --update 100" >/dev/null; sleep 3
  "$MACTERM" tab new --project macterm --run "hx AGENTS.md" >/dev/null; sleep 3
  "$MACTERM" pane split --project macterm --tab 2 --direction down --run top >/dev/null; sleep 2.5
  "$MACTERM" tab new --project macterm --run "$OPENCODE" >/dev/null; sleep 8
  "$MACTERM" tab new --project macterm --run "git --no-pager log --oneline -20" >/dev/null; sleep 2.5
  "$MACTERM" pane split --project macterm --tab 4 --direction right --run "btop --update 100" >/dev/null; sleep 3
  "$MACTERM" tab new --project macterm --run "macterm tutor" >/dev/null; sleep 2.5
  "$MACTERM" tab select 1 --project macterm >/dev/null; sleep 2
  record tab-switcher drive6
  guard_repo
  encode tab-switcher 06-tab-switcher.mp4
  # btop and top do not stop on their own; leave the project as one idle tab
  reset_project
}

# ── animations ──────────────────────────────────────────────────────────────
# Smooth scrolling through a Claude Code transcript, a split growing in, and
# the cursor gliding (with its trail) around a file in Helix. Everything the
# clip shows is generated: claude-mock/server.py stands in for the API and
# streams a canned tour of a small Swift package that seed-project.sh writes
# fresh each run, so the transcript is the same on every take and nothing
# leaves the machine. The tour is answered BEFORE the camera rolls; the clip
# opens on the finished session and scrolls back through it.
CDEMO="$WORK/demo7"                 # mock pid, Claude Code's config dir, the project
CPROJ="$CDEMO/starfield"
K_G=5 K_E=14 K_B=11 K_O=31

app_version() { defaults read /Applications/Macterm.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo 0; }

app_has_anim_kit() {  # does the installed app link a GhosttyKit with the region animation?
  # grep -c, not -q: under pipefail an early exit would fail `strings` with SIGPIPE
  [ "$(strings /Applications/Macterm.app/Contents/MacOS/Macterm 2>/dev/null | grep -c "$ANIM_KIT_SYMBOL")" -gt 0 ]
}

anim_pref() { defaults read com.thdxg.macterm "macterm.terminal.$1" 2>/dev/null || echo default; }

# The control socket does not say whether the sidebar is showing, but the
# toolbar button does: its description reads "Show Sidebar" while hidden and
# "Hide Sidebar" while visible. Demo 7 wants the whole width for its two panes.
sidebar_visible() {
  [ "$(osa 'tell application "System Events" to tell process "Macterm" to get description of (first button of toolbar 1 of window 1 whose description contains "Sidebar")' 2>/dev/null)" = "Hide Sidebar" ]
}
SIDEBAR_WAS_VISIBLE=0
hide_sidebar_for_demo() {
  if sidebar_visible; then
    SIDEBAR_WAS_VISIBLE=1
    focus_app; sleep 0.3; kc $K_BSLASH "$CMD"; sleep 1.0
  fi
}
restore_sidebar() {
  if [ "$SIDEBAR_WAS_VISIBLE" = 1 ] && ! sidebar_visible; then
    focus_app; sleep 0.3; kc $K_BSLASH "$CMD"; sleep 0.6
  fi
}

claude_up() {
  command -v claude >/dev/null || die "claude (Claude Code) not on PATH — demo 7 needs it"
  app_has_anim_kit \
    || die "installed Macterm ($(app_version)) predates the scrolling animation; demo 7 needs 1.29.3 or newer"
  local k; for k in smoothScrolling smoothCursor cursorTrail animatedSplits; do
    [ "$(anim_pref $k)" = 1 ] || die "macterm.terminal.$k is off — run: $0 anim-prefs, then relaunch Macterm"
  done
  mkdir -p "$CDEMO/claude-home"
  "$HERE/claude-mock/seed-project.sh" "$CPROJ" >/dev/null

  claude_down_mock
  python3 -u "$HERE/claude-mock/server.py" "$CLAUDE_PORT" -v >"$CDEMO/mock.log" 2>&1 &
  echo $! > "$CDEMO/mock.pid"
  local i=0
  until curl -fs "http://127.0.0.1:$CLAUDE_PORT/health" >/dev/null 2>&1; do
    sleep 0.2; i=$((i + 1)); [ $i -gt 25 ] && { cat "$CDEMO/mock.log" >&2; die "mock API never answered"; }
  done

  # Claude Code's own state, kept out of ~/.claude: onboarding done, the
  # project trusted, and the dummy key pre-approved (it remembers keys by
  # their last 20 characters), so nothing asks a question on screen.
  local key="sk-ant-api03-macterm-demo-0000000000000000000000000000"
  python3 - "$CDEMO/claude-home/.claude.json" "$CPROJ" "$key" <<'PY'
import json, sys
path, proj, key = sys.argv[1:4]
json.dump({
    "hasCompletedOnboarding": True, "theme": "dark", "numStartups": 12,
    "hasAcknowledgedCostThreshold": True, "autoUpdates": False,
    "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
    "projects": {proj: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True,
                        "allowedTools": [], "projectOnboardingSeenCount": 3}},
}, open(path, "w"), indent=2)
PY
  # The pane runs this instead of a shell, so no command line shows above the
  # banner in scrollback. CLAUDE_CODE_* is scrubbed in case the recording
  # shell is itself inside a Claude Code session. Claude Code stays in its
  # full-screen mode: it owns the mouse there and scrolls its own transcript
  # by rows with the terminal's scroll margins, which is the motion this
  # clip is about (see tscroll for why the pointer has to be in the pane).
  cat > "$CDEMO/claude-demo.sh" <<WRAP
#!/bin/bash
cd "$CPROJ"
exec env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE \\
  ANTHROPIC_BASE_URL="http://127.0.0.1:$CLAUDE_PORT" \\
  ANTHROPIC_API_KEY="$key" \\
  CLAUDE_CONFIG_DIR="$CDEMO/claude-home" \\
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \\
  DISABLE_BUG_COMMAND=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \\
  claude "Give me a tour of this project"
WRAP
  chmod +x "$CDEMO/claude-demo.sh"
  say "offline Claude Code ready (mock API on :$CLAUDE_PORT, project $CPROJ)"
}

claude_down_mock() {
  if [ -f "$CDEMO/mock.pid" ]; then
    kill "$(cat "$CDEMO/mock.pid")" 2>/dev/null || true
    rm -f "$CDEMO/mock.pid"
  fi
  pkill -f "claude-mock/server.py $CLAUDE_PORT" 2>/dev/null || true
}

claude_down() {
  claude_down_mock
  say "offline Claude Code stopped"
}

# A key held down: one AppleScript repeating the key code at key-repeat pace,
# because a separate osascript per press is too slow to read as a hold. The
# cursor glide and trail show best under exactly this — Helix moving line by
# line or word by word as fast as the keyboard repeats.
khold() {  # khold <keycode> <times> [gap seconds]
  osa "tell application \"System Events\"
        repeat $2 times
          key code $1
          delay ${3:-0.045}
        end repeat
      end tell" >/dev/null
}

# One trackpad-style scroll into the middle of the first pane. Positive pixels
# go toward older content. scroll.js posts the gesture at CGEvent level and
# moves the pointer into the pane for it (mouse-reporting programs attach the
# pointer's cell to every tick). The pointer is left there: the camera never
# records it, and every osascript round trip between two beats is a visible
# pause, so the driver parks it once, after the beat that follows the scrolls.
tscroll() {  # tscroll <pixels> <seconds>
  local px="$1" secs="$2" steps
  steps=$(python3 -c "print(max(8, int($secs * 40)))")
  osascript -l JavaScript "$HERE/scroll.js" \
    $((WIN_X + WIN_W / 4)) $((WIN_Y + WIN_H / 2)) "$px" "$steps" "$secs" >/dev/null
}

drive7() {
  sleep 1.0                                        # the finished session; poster frame
  tscroll 180 0.7;   sleep 0.6                     # up through the reply
  tscroll 180 0.7;   sleep 0.8                     # and to its top
  tscroll -900 1.0                                 # back down, and straight into
  kc $K_D "$CMD"                                   # the split (split-auto) growing in
  park_cursor; sleep 1.3
  wait_prompt --pane 2;       kline "hx notes.md" 0.055
  sleep 1.5
  kc $K_O; sleep 0.5                               # open a line below, insert mode
  ktype "Try a dimmer glyph for the farthest band; the dots read as noise." 0.06
  sleep 0.5; kc $K_ESC; sleep 0.8
  # Escape leaves the cursor at the end of the long line just typed. Held from
  # there, j keeps that column as its target and the cursor swings across the
  # width as the lines below vary in length — the glide at its most visible.
  khold $K_J 16; sleep 0.8                         # hold j: down the file
  khold $K_W 14; sleep 0.8                         # hold w: along a line, word by word
  khold $K_K 9;  sleep 0.8                         # hold k: back up
  kc $K_G; kc $K_E; sleep 1.0                      # ge: end of the file
  kc $K_G; kc $K_G; sleep 1.2                      # and back to the top
}

demo7() {  # animations: scrollback in Claude Code, a split, the cursor in Helix
  say "demo 7 — animations"
  claude_up
  reset_project
  hide_sidebar_for_demo
  # Claude Code in its own tab, launched directly so no shell prompt or command
  # precedes the banner in scrollback; then drop the shell tab reset_project made.
  "$MACTERM" tab new --project macterm --run "$CDEMO/claude-demo.sh" >/dev/null; sleep 1
  "$MACTERM" tab close 1 --project macterm --force >/dev/null 2>&1 || true
  # wait for the whole tour to have arrived, then for the input box to settle
  local i=0
  until "$MACTERM" pane dump --project macterm --tab 1 2>/dev/null | grep -Eq "Want me to walk through|line by line\?"; do
    sleep 0.5; i=$((i + 1)); [ $i -gt 120 ] && { claude_down; die "Claude Code never finished the tour (see $CDEMO/mock.log)"; }
  done
  sleep 2.5
  record animations drive7 "" quiet
  encode animations 07-animations.mp4
  claude_down
  reset_project
  restore_sidebar
}

# ── mouse, windows and regions (demos 8–10) ─────────────────────────────────
# Demos 8 and 9 are about a mouse gesture, so they record the cursor and move
# it with mouse.js. They also record the desktop rather than the window, so
# they check that nothing but wallpaper, widgets and the windows they placed
# is inside the frame — a tiled window left in the region ruins the take.
mouse() { osascript -l JavaScript "$HERE/mouse.js" "$@" >/dev/null; }
warp() {  # jump the pointer, off camera
  osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGWarpMouseCursorPosition(\$.CGPointMake($1, $2)); 'ok'" >/dev/null
}

winlist() {  # owner|layer|x|y|w|h|title, front to back (windows.swift)
  if [ ! -x "$WORK/windows" ] || [ "$HERE/windows.swift" -nt "$WORK/windows" ]; then
    swiftc -O -o "$WORK/windows" "$HERE/windows.swift" 2>/dev/null || die "could not compile windows.swift"
  fi
  "$WORK/windows"
}

region_clear() {  # region_clear <x,y,w,h> <owners allowed in it, as a regex>
  local rx ry rw rh; IFS=, read -r rx ry rw rh <<< "$1"
  local intruders
  intruders="$(winlist | awk -F'|' -v rx="$rx" -v ry="$ry" -v rw="$rw" -v rh="$rh" -v ok="$2" '
    $2 == 0 && $1 !~ ok && $3 < rx + rw && $3 + $5 > rx && $4 < ry + rh && $4 + $6 > ry { print "   " $1 " — " $7 }')"
  [ -z "$intruders" ] && return 0
  printf '\033[31m!!\033[0m these windows are inside the frame:\n%s\n' "$intruders" >&2
  return 1
}

wait_text() {  # wait_text <seconds> <extended regex> [pane dump selectors...]
  local secs="$1" re="$2"; shift 2
  local i=0
  while [ $i -lt $((secs * 4)) ]; do
    { "$MACTERM" pane dump "$@" 2>/dev/null || true; } | grep -Eq "$re" && return 0
    sleep 0.25; i=$((i + 1))
  done
  printf '\033[33m..\033[0m never saw /%s/ in %ss\n' "$re" "$secs"
  return 1
}

# ── open a folder from the Dock ─────────────────────────────────────────────
# A folder dragged onto Macterm's Dock tile becomes a new project. The frame
# is the bottom middle of the screen, where the Dock is: a dummy folder sits
# on the desktop at its left, the window at its right, and the pointer carries
# the folder down until the auto-hidden Dock slides up and drops it on the
# tile, which brings Macterm forward on the new project.
#
# The folder is written fresh on the desktop (refused if one of that name is
# already there and isn't ours; ours is recorded in the work directory, since
# Finder may be showing hidden files). A desktop that uses Stacks or a sort
# order ignores the position the folder is given and files it at the top
# right, so for the take the desktop's view settings are switched to neither
# — Finder restarts to read them — and put back afterwards, the same way.
DOCK_FOLDER=starfield
DOCK_ROOT="$HOME/Desktop/$DOCK_FOLDER"
DOCK_W=1680 DOCK_H=950                 # the frame, same shape as the others
dock_geometry() {  # sets DOCK_REGION, the window's rect and the folder's spot
  local sw sh; read -r sw sh <<< "$(screen_size)"; sw=${sw%.*}; sh=${sh%.*}
  DOCK_X=$(((sw - DOCK_W) / 2)); DOCK_Y=$((sh - DOCK_H))
  # clear of desktop widgets (the system's or Macterm's) reaching into this
  # band: a folder under one can't be picked up, and they'd crowd the frame
  local clear
  clear="$(winlist | awk -F'|' -v top="$DOCK_Y" '
    $2 != 0 && $2 != 20 && $2 < 0 && $6 < 1600 && $4 + $6 > top { r = $3 + $5; if (r > m) m = r }
    END { print m + 0 }')"
  [ "$clear" -gt 0 ] && [ $((clear + 10)) -gt "$DOCK_X" ] && DOCK_X=$((clear + 10))
  DOCK_REGION="$DOCK_X,$DOCK_Y,$DOCK_W,$DOCK_H"
  # the window on the right, clear of the Dock's slot at the bottom; the
  # folder in the strip of desktop left of it (a desktop position is the
  # icon's centre)
  DWIN_X=$((DOCK_X + 340)) DWIN_Y=$((DOCK_Y + 40)) DWIN_W=$((DOCK_W - 380)) DWIN_H=$((DOCK_H - 150))
  DICON_X=$((DOCK_X + 170)) DICON_Y=$((DOCK_Y + 260))
}

dock_root_is_ours() { [ "$(cat "$WORK/dock-root" 2>/dev/null)" = "$DOCK_ROOT" ]; }

dock_seed() {
  if [ -e "$DOCK_ROOT" ] && ! dock_root_is_ours; then
    die "$DOCK_ROOT already exists and isn't the demo's — move it aside"
  fi
  rm -rf "$DOCK_ROOT"
  printf '%s\n' "$DOCK_ROOT" > "$WORK/dock-root"
  "$HERE/claude-mock/seed-project.sh" "$DOCK_ROOT" >/dev/null
  # a short history in place of the seed's single commit, so the first thing
  # run in the new project has a story to show
  rm -rf "$DOCK_ROOT/.git"
  local g=(git -C "$DOCK_ROOT" -c core.hooksPath=/dev/null -c commit.gpgsign=false
           -c user.name="Macterm Demo" -c user.email=demo@macterm.invalid)
  "${g[@]}" init -q -b main
  "${g[@]}" add Package.swift;                      "${g[@]}" commit -qm "Scaffold the starfield package"
  "${g[@]}" add Sources/Starfield/Star.swift;       "${g[@]}" commit -qm "Give each star a depth and a brightness"
  "${g[@]}" add Sources/Starfield/Field.swift;      "${g[@]}" commit -qm "Recycle stars at the far plane"
  "${g[@]}" add -A;                                 "${g[@]}" commit -qm "Draw the field in four greys"
}

# desk_view save|free|restore — the desktop's Stacks and sort order
desk_view() {
  python3 - "$1" "$WORK/desktop-view.plist" <<'PY2'
import os, plistlib, subprocess, sys
verb, saved = sys.argv[1], sys.argv[2]
dom = "com.apple.finder"
def current():
    out = subprocess.run(["defaults", "export", dom, "-"], capture_output=True, check=True).stdout
    return plistlib.loads(out).get("DesktopViewSettings", {})
def write(d):
    xml = plistlib.dumps(d, fmt=plistlib.FMT_XML).decode()
    subprocess.run(["defaults", "write", dom, "DesktopViewSettings", xml], check=True)
if verb == "save" and not os.path.exists(saved):
    open(saved, "wb").write(plistlib.dumps(current()))
elif verb == "free":
    d = current()
    d["GroupBy"] = "None"
    d.setdefault("IconViewSettings", {})["arrangeBy"] = "none"
    write(d)
elif verb == "restore" and os.path.exists(saved):
    write(plistlib.loads(open(saved, "rb").read()))
    os.remove(saved)
PY2
}
restart_finder() { killall Finder 2>/dev/null || true; sleep 3; }

place_folder() {  # put the folder on the desktop where the drag starts
  local i=0
  until osa "tell application \"Finder\" to set desktop position of item \"$DOCK_FOLDER\" of desktop to {$DICON_X, $DICON_Y}" >/dev/null 2>&1; do
    sleep 0.5; i=$((i + 1)); [ $i -gt 20 ] && return 1
  done
  sleep 0.8
}

drive8() {
  sleep 0.9                                        # the folder, the window beside it
  mouse move "$DICON_X" "$DICON_Y" 0.8; sleep 0.35
  mouse dockdrop "$DICON_X" "$DICON_Y" Macterm 1.2 # down to the Dock, onto Macterm
  sleep 0.3
  # straight up off the Dock so it slides away (along it, every tile the
  # pointer crosses magnifies and names itself), then out of the text's way
  local px py; read -r px py <<< "$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); var p = $.CGEventGetLocation($.CGEventCreate(null)); Math.round(p.x) + " " + Math.round(p.y)')"
  mouse move "$px" $((DWIN_Y + DWIN_H - 60)) 0.35
  mouse move $((DWIN_X + DWIN_W - 160)) $((DWIN_Y + DWIN_H - 140)) 0.6
  wait_prompt --project "$DOCK_FOLDER" --pane 1
  sleep 0.5
  kline "ls" 0.06;                                 sleep 1.3
  kline "git --no-pager log --oneline" 0.05;       sleep 2.2
}

demo8() {  # drag a folder onto the Dock tile: it opens as a project
  say "demo 8 — open a folder from the Dock"
  dock_geometry
  local tile; tile="$(osa 'tell application "System Events" to tell process "Dock" to get position of UI element "Macterm" of list 1' 2>/dev/null | cut -d, -f1 | tr -d ' ')"
  if [ -n "$tile" ] && { [ "$tile" -lt $((DOCK_X + 40)) ] || [ "$tile" -gt $((DOCK_X + DOCK_W - 80)) ]; }; then
    die "Macterm's Dock tile (x $tile) is outside the frame ($DOCK_REGION) — widgets push it right; make room"
  fi
  "$MACTERM" project remove "$DOCK_FOLDER" --force >/dev/null 2>&1 || true
  dock_seed
  reset_project
  set_window_rect "$DWIN_X" "$DWIN_Y" "$DWIN_W" "$DWIN_H"; sleep 0.6
  read -r wx wy ww wh <<< "$(window_rect)"
  if ! { near "$wx" "$DWIN_X" && near "$wy" "$DWIN_Y" && near "$ww" "$DWIN_W" && near "$wh" "$DWIN_H"; }; then
    dock_down; die "could not move the window into the Dock frame (is it floating?)"
  fi
  desk_view save; desk_view free; restart_finder
  place_folder || { dock_down; die "Finder would not place $DOCK_FOLDER on the desktop"; }
  focus_app; sleep 0.5
  region_clear "$DOCK_REGION" '^Macterm$' || { dock_down; die "clear the frame and try again"; }
  # the pointer starts on the desktop above the folder
  warp "$DICON_X" $((DICON_Y - 170))
  CAPTURE_CURSOR=1
  record open-folder drive8 "$DOCK_REGION" noactivate
  CAPTURE_CURSOR=0
  encode open-folder 08-open-folder.mp4
  dock_down
}

dock_down() {
  "$MACTERM" project remove "$DOCK_FOLDER" --force >/dev/null 2>&1 || true
  if dock_root_is_ours; then rm -rf "$DOCK_ROOT"; rm -f "$WORK/dock-root"; fi
  if [ -f "$WORK/desktop-view.plist" ]; then desk_view restore; restart_finder; fi
  set_window_rect "$WIN_X" "$WIN_Y" "$WIN_W" "$WIN_H"
  "$MACTERM" project select macterm >/dev/null 2>&1 || true
  park_cursor
}

# ── desktop widgets ─────────────────────────────────────────────────────────
# Your desktop as it is: the system's widgets and your Macterm ones, nothing
# created or moved for the take. The btop widget starts as a plain shell;
# the clip right-clicks it, picks Edit Widget, runs btop, walks its presets
# with `p` back round to the one you use, clicks Done, then drags the widget
# out of its slot and back, where it snaps into line again.
#
# The frame is the full height below the menu bar at the clip's shape, since
# the widgets stand taller than they are wide; the terminal window is parked
# off screen and the desktop's icons are hidden for the take (Finder
# restarts to show or hide them; an EXIT trap puts them back).
WPITCH=180                                   # DesktopWidgetGrid's cell pitch
BTOP_PRESET=2                                # the btop preset you use; the take ends on it
btop_preset() {  # the preset btop's header names right now (0-3, or * at launch)
  "$MACTERM" pane dump --session "$1" 2>/dev/null | grep -oE "preset [0-9*]" | head -1 | cut -d' ' -f2
}
widget_geometry() {
  local sw sh vw vh; read -r sw sh <<< "$(screen_size)"; read -r vw vh <<< "$(visible_size)"
  MENUBAR=$(( ${sh%.*} - ${vh%.*} ))
  WIDGET_H=$(( ${vh%.*} / 2 * 2 ))
  WIDGET_W=$(( WIDGET_H * 1400 / 792 / 2 * 2 ))
  WIDGET_REGION="0,$MENUBAR,$WIDGET_W,$WIDGET_H"
}

btop_widget() {  # "index session columns rows" of the widget whose recipe runs btop
  "$MACTERM" widget list --json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for w in (data.get("widgets") or data.get("data", {}).get("widgets") or []):
    if "btop" in (w.get("command") or ""):
        print(w["index"], w["session"], w["columns"], w["rows"]); break'
}

widget_window() {  # widget_window <w> <h>  →  "x y" of the Macterm panel that size
  winlist | awk -F'|' -v w="$1" -v h="$2" '
    $1 == "Macterm" && $2 != 0 && ($5 - w) ^ 2 <= 16 && ($6 - h) ^ 2 <= 16 { print $3, $4; exit }'
}
span_pt() { echo $(($1 * 164 + ($1 - 1) * 16)); }

done_button() {  # centre of the Done button an editing widget shows
  osa 'tell application "System Events" to tell process "Macterm"
         repeat with w in windows
           try
             set b to button "Done" of w
             set {p, s} to {position of b, size of b}
             return ((item 1 of p) + (item 1 of s) div 2) & " " & ((item 2 of p) + (item 2 of s) div 2) as text
           end try
         end repeat
       end tell' 2>/dev/null || true
}

desk_icons() {  # desk_icons hide|restore — the desktop's icons, for the take
  case "$1" in
    hide)
      [ -f "$WORK/create-desktop.was" ] || defaults read com.apple.finder CreateDesktop > "$WORK/create-desktop.was" 2>/dev/null \
        || echo absent > "$WORK/create-desktop.was"
      defaults write com.apple.finder CreateDesktop -bool false ;;
    restore)
      [ -f "$WORK/create-desktop.was" ] || return 0
      local was; was="$(cat "$WORK/create-desktop.was")"
      if [ "$was" = absent ]; then defaults delete com.apple.finder CreateDesktop 2>/dev/null || true
      else defaults write com.apple.finder CreateDesktop -bool "$([ "$was" = 1 ] && echo true || echo false)"; fi
      rm -f "$WORK/create-desktop.was" ;;
  esac
  killall Finder 2>/dev/null || true; sleep 2.5
}

WB_SESSION="" WB_X=0 WB_Y=0 WB_W=0 WB_H=0
drive9() {
  local cx=$((WB_X + WB_W / 2)) cy=$((WB_Y + WB_H / 2))
  sleep 1.2                                        # the desktop; btop's widget a shell
  mouse move "$cx" "$cy" 0.9; sleep 0.3
  mouse click "$cx" "$cy" right; sleep 0.7         # the widget's menu
  # Edit Widget is the menu's first item, which opens with its top-left at
  # the pointer: about 45pt right and 12pt down lands on the item
  mouse move $((cx + 45)) $((cy + 12)) 0.35; sleep 0.25
  mouse click $((cx + 45)) $((cy + 12)); sleep 0.8
  mouse click "$cx" "$((cy + 60))"; sleep 0.3      # into its terminal
  kline "btop" 0.07; sleep 2.2
  # each preset in turn until btop's header names yours
  local i; for ((i = 0; i < 8; i++)); do
    ktype "p" 0; sleep 1.1
    [ "$(btop_preset "$WB_SESSION")" = "$BTOP_PRESET" ] && break
  done
  sleep 0.6
  local dx dy; read -r dx dy <<< "$(done_button)"
  if [ -n "$dy" ]; then
    mouse move "$dx" "$dy" 0.7; sleep 0.25; mouse click "$dx" "$dy"
  else
    "$MACTERM" widget done >/dev/null
  fi
  sleep 1.0
  # out to the free columns on the right, then back into its own slot: let
  # go a little off each time, so both snaps show
  local ox=$((cx + 5 * WPITCH + 14)) oy=$((cy + 18))
  mouse move "$cx" "$cy" 0.6; sleep 0.2
  mouse drag "$cx" "$cy" "$ox" "$oy" 1.0; sleep 1.0
  local nx ny; read -r nx ny <<< "$(widget_window "$WB_W" "$WB_H")"
  local gx=$(( ${nx:-$((WB_X + 5 * WPITCH))} + WB_W / 2 )) gy=$(( ${ny:-$WB_Y} + WB_H / 2 ))
  mouse move "$gx" "$gy" 0.5; sleep 0.2
  mouse drag "$gx" "$gy" $((cx - 16)) $((cy + 20)) 1.0
  sleep 0.6
  mouse move $((WIDGET_W - 300)) $((MENUBAR + WIDGET_H - 200)) 0.8
  sleep 1.8
}

demo9() {  # desktop widgets: edit one to run btop, then drag it out and back
  say "demo 9 — desktop widgets"
  widget_geometry
  local idx cols rows
  read -r idx WB_SESSION cols rows <<< "$(btop_widget)"
  [ -n "$WB_SESSION" ] || die "no widget runs btop — add one (widget new --run btop) and place it"
  "$MACTERM" widget done >/dev/null 2>&1 || true
  # a plain shell to start from: quit btop if it's up, clear the screen
  if "$MACTERM" pane dump --session "$WB_SESSION" 2>/dev/null | grep -q "preset"; then
    "$MACTERM" pane key q --session "$WB_SESSION" >/dev/null
  fi
  # clear once the prompt is back, until only the prompt shows (two lines
  # at most: a prompt may put its path on a line of its own)
  local tries=0
  until [ "$("$MACTERM" pane dump --session "$WB_SESSION" 2>/dev/null | grep -c '[^[:space:]]')" -le 2 ]; do
    wait_prompt --session "$WB_SESSION"
    "$MACTERM" pane run --session "$WB_SESSION" clear >/dev/null; sleep 1
    tries=$((tries + 1)); [ $tries -gt 4 ] && die "btop's widget never came back to a clean prompt"
  done
  WB_W=$(span_pt "$cols"); WB_H=$(span_pt "$rows")
  read -r WB_X WB_Y <<< "$(widget_window "$WB_W" "$WB_H")"
  [ -n "$WB_Y" ] || die "btop's widget is not on screen"
  focus_app; sleep 0.3
  # parked, as in demo 4, but past this frame's right edge: it is wider
  local sw sh; read -r sw sh <<< "$(screen_size)"
  set_window_rect $((WIDGET_W + 12)) $((${sh%.*} - 92)) "$WIN_W" "$WIN_H"
  desk_icons hide
  if ! region_clear "$WIDGET_REGION" '^$'; then
    desk_icons restore; set_window_rect "$WIN_X" "$WIN_Y" "$WIN_W" "$WIN_H"
    die "clear the desktop and try again"
  fi
  warp $((WIDGET_W - 300)) $((MENUBAR + WIDGET_H - 200))
  CAPTURE_CURSOR=1
  record widgets drive9 "$WIDGET_REGION" noactivate
  CAPTURE_CURSOR=0
  encode widgets 09-desktop-widgets.mp4
  local fx fy; read -r fx fy <<< "$(widget_window "$WB_W" "$WB_H")"
  [ "$fx $fy" = "$WB_X $WB_Y" ] || printf '\033[33m..\033[0m btop settled at %s,%s, not back at %s,%s — check the take\n' "$fx" "$fy" "$WB_X" "$WB_Y"
  desk_icons restore
  set_window_rect "$WIN_X" "$WIN_Y" "$WIN_W" "$WIN_H"
  park_cursor
}

# ── passwords ───────────────────────────────────────────────────────────────
# `ssh demo-box` from a shell, against the podman host logging in by
# password: the prompt comes up, the password is typed (nothing echoes), and
# once the login goes through Macterm offers to save it; a split then runs the
# same ssh and the bubble offers Autofill. Autofill is behind Touch ID once per
# unlock, and nobody touches the sensor during a take, so pw_rehearse spends
# that once before the camera rolls: a local script's prompt, saved and
# autofilled while you authenticate. Both entries leave the keychain after.
#
PW_SERVICE="com.thdxg.macterm.passwords"

bubble_up() {  # is an NSPopover-sized Macterm window up inside the terminal window?
  winlist | awk -F'|' -v x="$WIN_X" -v y="$WIN_Y" -v w="$WIN_W" -v h="$WIN_H" '
    $1 == "Macterm" && $5 >= 280 && $5 <= 480 && $6 >= 60 && $6 <= 420 &&
    $3 >= x - 40 && $3 <= x + w && $4 >= y - 40 && $4 <= y + h { found = 1 }
    END { exit !found }'
}
wait_bubble() {  # wait_bubble <seconds>
  local i=0
  while [ $i -lt $(($1 * 5)) ]; do bubble_up && return 0; sleep 0.2; i=$((i + 1)); done
  printf '\033[33m..\033[0m no password bubble after %ss\n' "$1"
  return 1
}

pw_cleanup() {  # remove the demo's saved passwords (rehearsal and demo-box)
  local acct
  security dump-keychain 2>/dev/null | python3 -c '
import re, sys
svc, blocks = sys.argv[1], sys.stdin.read().split("keychain: ")
for b in blocks:
    if f"\"svce\"<blob>=\"{svc}\"" not in b:
        continue
    m = re.search(r"\"acct\"<blob>=(0x([0-9A-F]+)\s+)?\"(.*)\"", b)
    if not m:
        continue
    acct = bytes.fromhex(m.group(2)).decode() if m.group(2) else m.group(3)
    if "pw-rehearse-" in acct or "demo-box" in acct:
        print(acct)
' "$PW_SERVICE" | while IFS= read -r acct; do
    security delete-generic-password -s "$PW_SERVICE" -a "$acct" >/dev/null 2>&1 \
      || printf '\033[33m..\033[0m could not remove "%s" — do it in Settings → Password Manager\n' "$acct"
  done
}

# Settings → Password Manager re-reads the keychain when it appears: a retake's way
# to make Macterm forget the last take's entry without a relaunch (which
# would lock autofill behind Touch ID again). The window is titled after its
# pane and its sidebar rows carry no labels, so the pane goes by position —
# SettingsPane's order, Password Manager eighth.
SETTINGS_PANES='{"General", "Projects", "Appearance", "Animations", "Quick Terminal", "Widgets", "Keymaps", "Password Manager", "Updates"}'
vault_reload() {
  focus_app; sleep 0.3; kc 43 "$CMD"; sleep 1.5          # ⌘,
  # by index, not by name: the window's title changes with the pane
  osa "tell application \"System Events\" to tell process \"Macterm\"
         set n to 0
         repeat with i from 1 to (count of windows)
           if (name of window i as text) is in $SETTINGS_PANES then set n to i
         end repeat
         if n is 0 then error \"no Settings window\"
         select row 8 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window n
         delay 1.2
         if (name of window n as text) is not \"Password Manager\" then error \"Password Manager pane did not open\"
         select row 1 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window n
       end tell" >/dev/null || return 1
  sleep 0.5; kc $K_W "$CMD"; sleep 0.6                    # close Settings
  rm -f "$WORK/pw-saved-pid"
}

pw_rehearse() {
  # A fresh script name per run, so its entry is new to Macterm: the app
  # keeps its list of saved passwords in memory, and the last run's entry,
  # deleted from the keychain behind its back, would still be "saved".
  local script; script="$WORK/pw-rehearse-$(date +%s).sh"
  rm -f "$WORK"/pw-rehearse-*.sh
  cat > "$script" <<'SH'
#!/bin/sh
printf 'Rehearsal password: '
stty -echo; read -r pw; stty echo; echo
echo "rehearsal-ok"
SH
  reset_project
  focus_app; sleep 0.5
  "$MACTERM" pane run --project macterm "/bin/sh $script" >/dev/null
  wait_text 10 "Rehearsal password: *$" --project macterm || die "rehearsal prompt never showed"
  sleep 0.6
  "$MACTERM" pane run --project macterm "macterm-rehearsal" >/dev/null
  wait_bubble 10 || die "no Save Password? offer in the rehearsal"
  focus_app; sleep 0.3; kc $K_RET; sleep 1.0            # Save
  "$MACTERM" pane run --project macterm "/bin/sh $script" >/dev/null
  wait_text 10 "Rehearsal password: *$" --project macterm || die "rehearsal prompt never showed"
  wait_bubble 10 || die "no Autofill offer in the rehearsal"
  focus_app; sleep 0.3; kc $K_RET                        # Autofill → Touch ID
  printf '\033[1m>>\033[0m authenticate with Touch ID (or your login password) now\n'
  local i=0
  until [ "$("$MACTERM" pane dump --project macterm 2>/dev/null | grep -c '^rehearsal-ok')" -ge 2 ]; do
    sleep 0.5; i=$((i + 1)); [ $i -gt 120 ] && die "the rehearsal autofill never went through"
  done
  say "autofill unlocked until the Mac locks or Macterm quits"
  reset_project
}

# Type a secret key by key through `pane key`, which feeds Macterm's password
# capture as a real key does. Not `pane run`: that pastes, and ssh reads the
# bracketed-paste markers as part of the password.
pane_type() {  # pane_type <text> [pane selectors...] — key by key, then Return
  # (`pane key` takes its selectors anywhere, so they can follow the key)
  local text="$1" i; shift
  for ((i = 0; i < ${#text}; i++)); do
    "$MACTERM" pane key "${text:i:1}" "$@" >/dev/null; sleep 0.06
  done
  sleep 0.4; "$MACTERM" pane key enter "$@" >/dev/null
}

# Ghostty's ssh-terminfo integration (Macterm's `ssh` wrapper) installs the
# xterm-ghostty entry on a host the first time you ssh to it — a second
# connection, so a second password prompt, off screen. The wrapper skips hosts
# listed in its cache, so the entry is installed over the key and the host
# listed, under the key the wrapper uses: a digest of the bundled entry.
TI_CACHE="$HOME/Library/Caches/macterm/ssh-terminfo"
TI_DEST="$RUSER@localhost"                     # `ssh -G demo-box`'s user@hostname
terminfo_prime() {
  local info=(env TERMINFO=/Applications/Macterm.app/Contents/Resources/terminfo /usr/bin/infocmp -x xterm-ghostty)
  "${info[@]}" | rssh 'tic -x - >/dev/null 2>&1' || true
  local key; key="$("${info[@]}" | shasum -a 256 | cut -c1-16)"
  mkdir -p "$(dirname "$TI_CACHE")"; touch "$TI_CACHE"
  grep -q "^$TI_DEST	" "$TI_CACHE" || printf '%s\t%s\n' "$TI_DEST" "$key" >> "$TI_CACHE"
}
terminfo_unprime() {
  [ -f "$TI_CACHE" ] || return 0
  grep -v "^$TI_DEST	" "$TI_CACHE" > "$TI_CACHE.tmp" || true
  mv "$TI_CACHE.tmp" "$TI_CACHE"
}

drive10() {
  sleep 0.6
  wait_prompt --pane 1;       kline "ssh demo-box" 0.06
  wait_text 20 "password: *$" --project macterm --pane 1 || return 0
  sleep 1.0
  pane_type "$RPASSWORD" --project macterm --pane 1   # nothing echoes
  wait_bubble 15 || return 0                       # "Save Password?"
  sleep 1.6
  kc $K_RET; PW_SAVED=1; sleep 1.0                 # Save
  kline "uname -sr" 0.05
  sleep 1.4
  kc $K_D "$CMD"; sleep 0.6                        # a second shell, a second login
  wait_prompt --pane 2;       kline "ssh demo-box" 0.06
  wait_text 20 "password: *$" --project macterm --pane 2 || return 0
  wait_bubble 10 || return 0                       # "Password Prompt Detected"
  sleep 1.6
  kc $K_RET                                        # Autofill
  wait_prompt --pane 2;       kline "ls /workspace" 0.05
  sleep 2.2
}

demo10() {  # save a password typed at an ssh login, autofill the next one
  say "demo 10 — passwords"
  # A take that saved the demo-box password leaves it in this Macterm's
  # in-memory list even after pw_cleanup deletes it from the keychain, and a
  # retake would open on Autofill instead of the save. Only a relaunch
  # re-reads the keychain (so does opening Settings → Password Manager).
  local pid; pid="$("$MACTERM" status | sed -n 's/.*(pid \([0-9]*\)).*/\1/p')"
  pw_cleanup
  if [ -n "$pid" ] && [ "$(cat "$WORK/pw-saved-pid" 2>/dev/null)" = "$pid" ]; then
    vault_reload || die "this Macterm still lists demo 10's password — open Settings → Password Manager (or relaunch it) before a retake"
  fi
  remote_up password
  terminfo_prime
  pw_rehearse
  PW_SAVED=0
  record passwords drive10
  [ "$PW_SAVED" = 1 ] && echo "$pid" > "$WORK/pw-saved-pid"
  encode passwords 10-passwords.mp4
  reset_project                                    # ends both ssh sessions
  remote_down
  terminfo_unprime
  pw_cleanup
}

# ── custom palettes ─────────────────────────────────────────────────────────
# A Git palette over the macterm project's own history: open it from ⌘P, enter
# its menu, then the commits listing; search, open a commit's menu, Delete back
# a screen, search for another, and run the commit's Diff action in a split. The
# file's commands are POSIX sh, as every palette's are whatever the login shell
# (started through it for its PATH), and the listing needs jq.
K_DELETE=51

login_shell() { dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}'; }

pal_write() {
  local list diff stat branches log
  list="git log -40 --format='%h%x09%s%x09%ar' | jq -cR 'split(\"\\t\") | {hash: .[0], subject: .[1], when: .[2]}'"
  diff='git show "$COMMIT"'
  stat='git show --stat "$COMMIT"'
  log='git log --oneline -20 "$BRANCH"'
  branches="git branch --format='%(refname:short)'"
  mkdir -p "$PAL_EXT/palettes"
  printf '%s\nname: Git (demo)\ndescription: The commits and branches of the project\n' "$PAL_MARK" > "$PAL_MANIFEST"
  cat > "$PAL_FILE" <<EOF
name: Git
icon: arrow.triangle.branch
description: The project's commits and branches
requires: [git, jq]
root: menu
nodes:
  menu:
    items:
      - title: Commits
        subtitle: The last 40 on this branch
        icon: clock.arrow.circlepath
        enter: commits
      - title: Branches
        icon: arrow.triangle.branch
        enter: branches
  commits:
    placeholder: Search commits...
    list: |-
      $list
    title: .subject
    subtitle: .when
    icon: smallcircle.filled.circle
    match: [.subject, .hash]
    export: { COMMIT: .hash }
    enter: commit
  commit:
    items:
      - title: Diff
        subtitle: git show, in a split
        icon: plus.forwardslash.minus
        action:
          run: |-
            $diff
          in: split
      - title: Files changed
        icon: doc.on.doc
        action:
          run: |-
            $stat
          in: split
  branches:
    placeholder: Search branches...
    list: |-
      $branches
    icon: arrow.triangle.branch
    export: { BRANCH: . }
    action:
      run: |-
        $log
      in: split
EOF
}

# The palette has no CLI view — nothing reports which screen is up or whether
# a listing has finished — so its steps take beats, like demo 4's panel. The
# listing gets a long one, and pal_check has already run the same command the
# way the palette runs it, off camera, so a slow or failing listing stops the
# take before it starts rather than ruining it.
PAL_LIST_BEAT=1.8

pal_check() {  # the commits listing, run as the palette will run it
  local shell repo out cmd line
  shell="$(login_shell)"; repo="$(shown_repo)"
  [ -n "$repo" ] || die "no macterm project to list commits in"
  cmd="$(awk '/^  commits:/ {f=1} f && /^    list:/ {getline; sub(/^ +/, ""); print; exit}' "$PAL_FILE")"
  # The palette's own route: the login shell (for its PATH) hands the command,
  # from the environment, to sh with errexit. The line is one single-quoted
  # string, so it reads the same in nu, fish, zsh and bash.
  line="/bin/sh -c 'set -e; eval \"\$MACTERM_PALETTE_COMMAND\"'"
  out="$(cd "$repo" && MACTERM_PALETTE_COMMAND="$cmd" "$shell" -l -c "$line" 2>&1)" \
    || die "the demo palette's listing failed: $out"
  case "$out" in
    \[*|\{*) ;;
    *) die "the demo palette's listing printed something other than JSON in $shell (a startup message?): $(printf '%s' "$out" | head -n 2)" ;;
  esac
}

drive11() {
  sleep 0.8
  kc $K_P "$CMD"; sleep 1.0                        # the command palette
  ktype "git" 0.08; sleep 1.0                      # the palette's row, under Palettes
  kc $K_RET; sleep 1.3                             # Git: a menu of its own
  kc $K_RET; sleep "$PAL_LIST_BEAT"                # Commits: the listing runs
  ktype "palette" 0.07; sleep 1.3                  # search the commits
  kc $K_RET; sleep 1.6                             # a commit's menu; the pills read the trail
  kc $K_DELETE; sleep 1.2                          # back one screen, search cleared
  ktype "fzf" 0.08; sleep 1.2                      # a different commit this time
  kc $K_RET; sleep 1.4                             # another commit
  kc $K_RET                                        # Diff: a split runs git show
  # a hunk header: what git's own pager and delta (or any other) both show
  wait_text 15 '@@ ' --project macterm --pane 2 || return 0
  sleep 2.6
}

demo11() {  # a custom palette: nested screens, a search, a run action
  say "demo 11 — custom palettes"
  if [ -e "$PAL_EXT" ] && [ "$(head -n 1 "$PAL_MANIFEST" 2>/dev/null)" != "$PAL_MARK" ]; then
    die "$PAL_EXT exists and isn't this script's — move it aside first"
  fi
  # typing "git" must land on this palette, not one of yours with the same name
  local f
  for f in "$EXT_ROOT"/*/palettes/*.yaml "$EXT_ROOT"/*/palettes/*.yml; do
    [ -f "$f" ] && [ "$f" != "$PAL_FILE" ] || continue
    grep -Eiq '^name: *["'\'']?git["'\'']? *$' "$f" && die "$f is also named Git; uninstall its extension for the take"
  done
  command -v jq >/dev/null || die "demo 11's palette needs jq"
  pal_write
  pal_check
  reset_project
  record palettes drive11
  encode palettes 11-custom-palettes.mp4
  reset_project                                    # quits the pager, drops the split
  rm -rf "$PAL_EXT"
}

anim_prefs() {
  local k; for k in smoothScrolling smoothCursor cursorTrail animatedSplits; do
    anim_pref $k > "$WORK/anim.$k.was"
    defaults write com.thdxg.macterm "macterm.terminal.$k" -bool true
    echo "  macterm.terminal.$k = 1  (was $(cat "$WORK/anim.$k.was"))"
  done
  cat <<EOF
   written. Quit and relaunch Macterm so the cursor shaders load (sessions
   persist), then put the window back and record. anim-restore undoes this.
EOF
}

anim_restore() {
  local k was; for k in smoothScrolling smoothCursor cursorTrail animatedSplits; do
    was="$(cat "$WORK/anim.$k.was" 2>/dev/null || echo default)"
    if [ "$was" = default ]; then
      defaults delete com.thdxg.macterm "macterm.terminal.$k" 2>/dev/null || true
    else
      defaults write com.thdxg.macterm "macterm.terminal.$k" -bool "$([ "$was" = 1 ] && echo true || echo false)"
    fi
    echo "  macterm.terminal.$k -> $was"
  done
  say "restored — relaunch Macterm to pick it up"
}

quick_prefs() {  # panel geometry as fractions of the screen, for the rect above
  read -r sw sh <<< "$(screen_size)"; read -r vw vh <<< "$(visible_size)"
  python3 - "$sw" "$sh" "$vw" "$vh" $QT_X $QT_Y $QT_W $QT_H <<'PY'
import subprocess, sys
sw, sh, vw, vh, x, y, w, h = map(float, sys.argv[1:9])
vals = {
    "width": w / vw, "height": h / vh,
    "fixedX": x / (vw - w),
    "fixedY": (sh - y - h) / (vh - h),   # AppKit origin is bottom-left
}
for k, v in vals.items():
    subprocess.run(["defaults", "write", "com.thdxg.macterm",
                    f"macterm.quickTerminal.{k}", "-float", f"{v:.4f}"], check=True)
    print(f"  macterm.quickTerminal.{k} = {v:.4f}")
PY
  cat <<EOF
   written. Quit and relaunch Macterm for the panel to pick them up
   (sessions persist), then put the window back and record.
EOF
}

# -------------------------------------------------------------------- main --
write_lib
case "${1:-all}" in
  check) preflight; exit 0 ;;
  remote-up) remote_up "${2:-key}"; exit 0 ;;
  remote-down) remote_down; exit 0 ;;
  web) web_assets; exit 0 ;;
  quick-prefs) quick_prefs; exit 0 ;;
  anim-prefs) anim_prefs; exit 0 ;;
  anim-restore) anim_restore; exit 0 ;;
  claude-up) claude_up; exit 0 ;;
  claude-down) claude_down; exit 0 ;;
  scroll-test) focus_app; sleep 0.5; tscroll 600 0.8; say "scrolled 600px toward older content"; exit 0 ;;
  quick-restore)  # half the screen, centred — what it was before recording
    defaults write com.thdxg.macterm macterm.quickTerminal.width -float 0.5
    defaults write com.thdxg.macterm macterm.quickTerminal.height -float 0.5
    defaults write com.thdxg.macterm macterm.quickTerminal.fixedX -float 0.5
    defaults delete com.thdxg.macterm macterm.quickTerminal.fixedY 2>/dev/null || true
    say "restored — relaunch Macterm to pick it up"; exit 0 ;;
  all) preflight; demo1; demo2; demo3; demo4; demo5; demo6; demo7; demo8; demo9; demo10; demo11 ;;
  *) preflight; for n in "$@"; do "demo$n"; done ;;
esac
say "done — $OUT"

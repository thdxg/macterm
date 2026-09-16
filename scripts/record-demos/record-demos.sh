#!/bin/bash
# Record the feature demos the website plays — keyboard-driven, no cursor.
#
#   ./scripts/record-demos/record-demos.sh check          preflight only
#   ./scripts/record-demos/record-demos.sh all            record every demo
#   ./scripts/record-demos/record-demos.sh 1 3            record only those demos
#   ./scripts/record-demos/record-demos.sh web            re-encode them into assets/demo/
#   ./scripts/record-demos/record-demos.sh remote-up      bring the ssh container up alone
#   ./scripts/record-demos/record-demos.sh remote-down    and tear it down
#   ./scripts/record-demos/record-demos.sh quick-prefs    set the quick-terminal geometry (needs an app restart)
#   ./scripts/record-demos/record-demos.sh quick-restore  put that geometry back
#
# It drives the INSTALLED app (/Applications/Macterm.app) through synthetic
# keystrokes, so it needs Accessibility and Screen Recording granted to
# whatever runs it, ffmpeg on PATH, and — for demo 5 — Docker.
#
# You place the Macterm window; the script refuses to record until it sits at
# the canonical rect below, so every clip lines up. Recordings go to
# $MACTERM_DEMOS_OUT (default ~/Desktop/macterm-demos); `web` is the only step
# that writes into the repo.
#
# Demos: 1 splits · 2 sidebar and tabs · 3 command palette and layouts ·
#        4 quick terminal · 5 remote project (Docker) · 6 tab switcher
set -euo pipefail

# ---------------------------------------------------------------- constants --
WIN_X=160 WIN_Y=186 WIN_W=1600 WIN_H=870   # where you put the window (points)
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
CNAME=macterm-demo          # the docker container's own name
RIMAGE=macterm-demo-remote
RDIR=/workspace
RMARKER=macterm-demo-container   # /etc/macterm-demo, baked into the image

MACTERM=/Applications/Macterm.app/Contents/Resources/bin/macterm
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
window_count() { osa 'tell application "System Events" to tell process "Macterm" to count windows'; }

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

  if [ -d "$REPO/.git" ] && ! git -C "$REPO" diff --quiet -- AGENTS.md; then
    die "AGENTS.md has uncommitted edits — demo 1 shows that file. git restore AGENTS.md first."
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
# driver returns plus a tail; -t is only a safety net.
record() {
  local name="$1" driver="$2" region="${3:-$REGION_X,$REGION_Y,$REGION_W,$REGION_H}" mode="${4:-}" dur=180
  local rx ry rw rh; IFS=, read -r rx ry rw rh <<< "$region"
  local out="$RAW/$name.mov" log="$RAW/$name.log"
  local dev; dev="$(screen_device)"; [ -n "$dev" ] || die "no screen-capture device"
  rm -f "$out"
  park_cursor
  if [ "$mode" != noactivate ]; then
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
  ffmpeg -hide_banner -loglevel warning -f avfoundation -capture_cursor 0 -framerate 60 \
    -i "$dev:none" -t "$dur" -vf "crop=$((rw*2)):$((rh*2)):$((rx*2)):$((ry*2))" \
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
guard_repo() {
  [ -d "$REPO/.git" ] || return 0
  local f
  for f in AGENTS.md; do
    if ! git -C "$REPO" diff --quiet -- "$f"; then
      git -C "$REPO" restore "$f"
      printf '\033[33m..\033[0m stray edit to %s reverted\n' "$f"
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
  "$MACTERM" tab new --project macterm --run opencode >/dev/null; sleep 8
  "$MACTERM" tab select 1 --project macterm >/dev/null; sleep 1.5
  record sidebar-tabs drive2
  guard_repo
  encode sidebar-tabs 02-sidebar-and-tabs.mp4
}

drive3() {
  sleep 0.6
  kc $K_P "$CMD"; sleep 0.9
  ktype "~/dev/macterm/website" 0.045; sleep 1.0
  kc $K_RET; sleep 1.8                             # opens it as a new project
  wait_prompt --pane 1
  kc $K_D "$CMD"; sleep 0.6
  wait_prompt --pane 2;       kline "git --no-pager status --short" 0.045
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
  "$MACTERM" project remove website --force >/dev/null 2>&1 || true
  rm -f "$HOME/.config/macterm/projects/website.yaml"
  "$MACTERM" project select macterm >/dev/null; "$MACTERM" tab select 1 --project macterm >/dev/null
  sleep 1.5
  record palette-layouts drive3
  guard_repo
  encode palette-layouts 03-command-palette-and-layouts.mp4
  # leave the tree as we found it
  "$MACTERM" project remove website --force >/dev/null 2>&1 || true
  rm -f "$HOME/.config/macterm/projects/website.yaml"
}

# The panel's panes are not addressable through the CLI (it resolves panes
# inside projects, and the quick terminal is not one), so this demo cannot
# wait on a prompt the way the others do — its panes are long-lived idle
# shells that already show one, and the split's new shell gets a fixed beat.
qt_ready() {  # the panel must be up AND Macterm frontmost, or a keystroke
              # would land in whatever app is — Finder renames files with it
  local fm; fm="$(osa 'tell application "System Events" to get name of first process whose frontmost is true')"
  [ "$(window_count)" -ge 2 ] && [ "$fm" = "Macterm" ] && return 0
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
  if [ "$(window_count)" -gt 1 ]; then             # start from hidden
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
  if [ "$(window_count)" -lt 2 ]; then kc $K_BACKTICK "$CTRL"; sleep 1.5; fi
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
remote_up() {
  local dir="$HERE/remote"
  [ -f "$dir/Dockerfile" ] || die "missing $dir/Dockerfile"
  if ! docker info >/dev/null 2>&1; then
    say "starting Docker Desktop"
    open -a Docker
    local i=0
    until docker info >/dev/null 2>&1; do
      sleep 2; i=$((i + 1)); [ $i -gt 45 ] && die "Docker did not come up"
    done
  fi
  if [ ! -f "$dir/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -C "$RHOST" -f "$dir/id_ed25519" >/dev/null
  fi
  cp "$dir/id_ed25519.pub" "$dir/authorized_keys"
  chmod 600 "$dir/id_ed25519"
  say "building $RIMAGE (first run compiles zmx: ~3 min)"
  docker build -q -t "$RIMAGE" "$dir" >/dev/null
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  # the prompt inside the pane should read like the host the demo names
  docker run -d --name "$CNAME" --hostname "$RHOST" \
    -p "127.0.0.1:$RPORT:22" "$RIMAGE" >/dev/null

  # the pane's ssh and every background probe use the user's own client, so
  # the connection details have to live in ~/.ssh/config — first, since ssh
  # keeps the first value it finds for each keyword
  local cfg="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"; touch "$cfg"; chmod 600 "$cfg"
  if ! grep -q "$RHOST (record-demos.sh)" "$cfg"; then
    {
      echo "# >>> $RHOST (record-demos.sh) >>>"
      echo "Host $RHOST"
      echo "  HostName 127.0.0.1"
      echo "  Port $RPORT"
      echo "  User $RUSER"
      echo "  IdentityFile $dir/id_ed25519"
      echo "  IdentitiesOnly yes"
      echo "  StrictHostKeyChecking no"
      echo "  UserKnownHostsFile /dev/null"
      echo "  LogLevel ERROR"       # or every pane opens with a known-hosts warning
      echo "# <<< $RHOST (record-demos.sh) <<<"
      echo
      cat "$cfg"
    } > "$cfg.record-demos" && mv "$cfg.record-demos" "$cfg"
    chmod 600 "$cfg"
  fi

  local i=0
  until ssh -o BatchMode=yes -o ConnectTimeout=3 "$RUSER@$RHOST" true 2>/dev/null; do
    sleep 1; i=$((i + 1)); [ $i -gt 30 ] && { remote_down; die "$RHOST never answered ssh"; }
  done
  # never record against something that is not the container: the alias
  # shadows a real host of the same name, so this check is load-bearing
  local marker; marker="$(ssh -o BatchMode=yes "$RUSER@$RHOST" 'cat /etc/macterm-demo 2>/dev/null' || true)"
  [ "$marker" = "$RMARKER" ] || { remote_down; die "$RUSER@$RHOST is not the demo container — aborting"; }
  say "remote host up ($RUSER@$RHOST, $(ssh -o BatchMode=yes "$RUSER@$RHOST" 'zmx --version | head -1'))"
}

remote_down() {
  # kill the project first: removing it ends the zmx sessions over ssh, which
  # needs the container still alive
  "$MACTERM" project remove workspace --force >/dev/null 2>&1 || true
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  if grep -q "$RHOST (record-demos.sh)" "$HOME/.ssh/config" 2>/dev/null; then
    python3 - "$HOME/.ssh/config" "$RHOST" <<'PY'
import re, sys
path, host = sys.argv[1], sys.argv[2]
text = open(path).read()
block = re.compile(r"\n?# >>> %s \(record-demos\.sh\) >>>.*?# <<< %s \(record-demos\.sh\) <<<\n?"
                   % (re.escape(host), re.escape(host)), re.S)
open(path, "w").write(block.sub("\n", text).lstrip("\n"))
PY
  fi
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
    "06-tab-switcher:06-tab-switcher"
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
  "$MACTERM" tab new --project macterm --run opencode >/dev/null; sleep 8
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
  remote-up) remote_up; exit 0 ;;
  remote-down) remote_down; exit 0 ;;
  web) web_assets; exit 0 ;;
  quick-prefs) quick_prefs; exit 0 ;;
  quick-restore)  # half the screen, centred — what it was before recording
    defaults write com.thdxg.macterm macterm.quickTerminal.width -float 0.5
    defaults write com.thdxg.macterm macterm.quickTerminal.height -float 0.5
    defaults write com.thdxg.macterm macterm.quickTerminal.fixedX -float 0.5
    defaults delete com.thdxg.macterm macterm.quickTerminal.fixedY 2>/dev/null || true
    say "restored — relaunch Macterm to pick it up"; exit 0 ;;
  all) preflight; demo1; demo2; demo3; demo4; demo5; demo6 ;;
  *) preflight; for n in "$@"; do "demo$n"; done ;;
esac
say "done — $OUT"

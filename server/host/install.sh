# The install of the server on a host (design/005, step 4), after exit 3 of
# attach.sh and the consent of the user. The app sends it as one line, as
# attach.sh (see there): each command ends with a semicolon.
#
# $1: the build key. $2: the SHA-256 of the binary (lowercase hex).
# $3: the host id to keep when the host has none yet.
# stdin: the gzip build for this host.
#
# The binary goes to a unique temp name in the bin folder, and moves to
# bin/macterm-<key> only after the check, so a proxy never runs a part of a
# file. ~/.local/bin/macterm then names the new build, with the same
# temp-name-and-mv step. The temp file goes also when a signal (a lost
# link) ends the install.
#
# Exit 0: installed; stdout has "macterm-host installed <host id>".
# Exit 4: no writable home. Exit 5: the copy or the check failed; stderr
# has the reason.
v=$1;
sum=$2;
newid=$3;
d=$HOME/.local/share/macterm;
bin=$d/bin;
if [ -z "$v" ] || [ -n "$(printf "%s" "$v" | tr -d 0-9a-f)" ]; then
  echo "macterm-host bad build key" >&2;
  exit 5;
fi;
if mkdir -p "$bin" 2>/dev/null; then :; else
  echo "macterm-host no-home" >&2;
  exit 4;
fi;
chmod 700 "$d" "$bin";
t=$bin/.macterm-$v.$$.$(date +%s);
cleanup() { rm -f "$t"; };
stop() { cleanup; exit 5; };
trap cleanup EXIT;
trap stop HUP INT TERM PIPE;
if gunzip -c >"$t"; then :; else
  echo "macterm-host the copy failed" >&2;
  exit 5;
fi;
if command -v sha256sum >/dev/null 2>&1; then
  h=$(sha256sum <"$t");
elif command -v shasum >/dev/null 2>&1; then
  h=$(shasum -a 256 <"$t");
else
  h=;
fi;
h=${h%% *};
chmod 700 "$t";
if [ -n "$h" ]; then
  if [ "$h" != "$sum" ]; then
    echo "macterm-host the checksum does not match" >&2;
    exit 5;
  fi;
else
  case $("$t" version 2>/dev/null | head -n 1) in
    *+thdxg.$v) ;;
    *)
      echo "macterm-host the build does not match" >&2;
      exit 5;
      ;;
  esac;
fi;
if mv -f "$t" "$bin/macterm-$v"; then :; else
  echo "macterm-host the move failed" >&2;
  exit 5;
fi;
if [ -s "$d/host-id" ]; then :; else
  printf "%s\n" "$newid" >"$d/host-id";
fi;
l=$HOME/.local/bin;
if mkdir -p "$l" 2>/dev/null; then
  if [ ! -e "$l/macterm" ] || { [ -L "$l/macterm" ] && [ ! -d "$l/macterm" ]; }; then
    ln -s "$bin/macterm-$v" "$l/.macterm.$$" && mv -f "$l/.macterm.$$" "$l/macterm";
  fi;
fi;
echo "macterm-host installed $(head -n 1 "$d/host-id")";

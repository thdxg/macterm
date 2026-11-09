# The check and the attach on a host (design/005, step 3), in one ssh
# command over the master. The app sends this text as sh -c and the text in
# single quotes, with the build key of its server as $1. So the text has no
# single quote, and it parses the same under every login shell.
#
# - A server of this build is there: exec its proxy. stdout is then the
#   protocol stream, and the proxy sends nothing before the hello.
# - No server of this build: exit 3. stderr has one line,
#   "macterm-host missing <uname -s> <uname -m> <host id>". The host id is
#   empty before the first install.
# - Exit 4: no writable home, or an OS with no build. stderr has
#   "macterm-host no-home" or "macterm-host unsupported <system> <machine>".
#
# It writes nothing on the host: the install comes only after the consent.
v=$1
d=$HOME/.local/share/macterm
b=$d/bin/macterm-$v
if [ -n "$v" ] && [ -x "$b" ]; then
  exec "$b" proxy
fi
s=$(uname -s)
m=$(uname -m)
if [ -z "$HOME" ] || [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
  echo "macterm-host no-home" >&2
  exit 4
fi
case $s in
  Linux | Darwin) ;;
  *)
    echo "macterm-host unsupported $s $m" >&2
    exit 4
    ;;
esac
id=$(head -n 1 "$d/host-id" 2>/dev/null)
echo "macterm-host missing $s $m $id" >&2
exit 3

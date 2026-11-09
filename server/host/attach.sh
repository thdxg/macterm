# The check and the attach on a host (design/005, step 3), in one ssh
# command over the master. $1 is the build key of the app's server.
#
# The app removes the comment lines, joins the other lines with spaces, and
# sends the result in single quotes after sh -c (HostScripts.command). So the
# text has no single quote, each line is valid when joined to the next (each
# command ends with a semicolon), and the one line parses the same under
# every login shell, csh too.
#
# - A server of this build is there: print the line "macterm-host proxy",
#   then exec its proxy. stdout is then the protocol stream. The app drops
#   everything before that line: a shell rc file of the user can write there.
# - No server of this build: exit 3. stderr has one line,
#   "macterm-host missing <uname -s> <uname -m> <host id> <host keys>". The
#   host id is "-" before the first install. The host keys are a checksum
#   of the public host keys of sshd, so that a host key change asks again.
# - Exit 4: no writable home, or an OS with no build. stderr has
#   "macterm-host no-home" or "macterm-host unsupported <system> <machine>".
#
# It writes nothing on the host: the install comes only after the consent.
v=$1;
d=$HOME/.local/share/macterm;
b=$d/bin/macterm-$v;
if [ -n "$v" ] && [ -x "$b" ]; then
  echo "macterm-host proxy";
  exec "$b" proxy;
fi;
s=$(uname -s);
m=$(uname -m);
if [ -z "$HOME" ] || [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
  echo "macterm-host no-home" >&2;
  exit 4;
fi;
case $s in
  Linux | Darwin) ;;
  *)
    echo "macterm-host unsupported $s $m" >&2;
    exit 4;
    ;;
esac;
id=$(head -n 1 "$d/host-id" 2>/dev/null);
if [ -z "$id" ]; then id=-; fi;
keys=$(cat /etc/ssh/ssh_host_*_key.pub 2>/dev/null | cut -d " " -f 1-2 | sort | cksum | cut -d " " -f 1);
echo "macterm-host missing $s $m $id $keys" >&2;
exit 3;

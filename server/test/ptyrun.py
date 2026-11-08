"""Runs a command on a pty, as a terminal does, for the tests of
`zmx connect` (src/attach.zig)."""

import fcntl
import os
import pty
import struct
import sys
import termios
import time


class Pty:
    def __init__(self, argv, cols=80, rows=24):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.execv(argv[0], argv)
            finally:
                os._exit(127)
        self.resize(cols, rows)
        os.set_blocking(self.fd, False)
        self.output = b""
        self.status = None

    def resize(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def _read(self):
        try:
            data = os.read(self.fd, 65536)
        except (BlockingIOError, OSError):
            time.sleep(0.02)
            return
        if data:
            self.output += data
        else:
            time.sleep(0.02)

    def type(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)

    def wait_output(self, text, timeout=10):
        b = text.encode()
        deadline = time.time() + timeout
        while b not in self.output:
            if time.time() > deadline:
                raise AssertionError("timed out waiting for %r; tail=%r" % (text, self.output[-300:]))
            self.poll()
            self._read()

    def poll(self):
        if self.status is None:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                self.status = os.waitstatus_to_exitcode(status)
        return self.status

    def wait_exit(self, timeout=10):
        deadline = time.time() + timeout
        while self.poll() is None:
            if time.time() > deadline:
                raise AssertionError("still running; tail=%r" % self.output[-300:])
            self._read()
        # What the command wrote last, an error message among it.
        while True:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            self.output += data
        return self.status


def connect(name, **kw):
    return Pty([os.environ["ZMX"], "connect", name], **kw)


if __name__ == "__main__":
    sys.exit("a module for the tests")

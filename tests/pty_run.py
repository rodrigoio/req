#!/usr/bin/env python3
"""Runs a command in a pseudo-terminal, typing the given chunks, and prints what it showed.

usage: pty_run.py <chunk> [<chunk> ...] -- <command> [args...]

Each chunk is typed as is (use \\r for Enter); after each one the driver waits until the
program has been quiet for a moment, so keys and prompts stay in step. When the chunks are
over it waits for the program to end (the last chunk should quit it) and exits with its
status. The output has the escape sequences removed. Works with Python 3.6 and later."""
import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

QUIET = 0.5      # seconds without output that count as "the program is waiting"
LIMIT = 10.0     # longest wait for one step


def drain(fd, quiet, limit):
    out = b""
    start = last = time.time()
    while time.time() - start < limit:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return out, True
            if not data:
                return out, True
            out += data
            last = time.time()
        elif time.time() - last >= quiet:
            break
    return out, False


def main():
    args = sys.argv[1:]
    if "--" not in args:
        sys.exit("usage: pty_run.py <chunk>... -- <command>...")
    split = args.index("--")
    chunks, command = args[:split], args[split + 1:]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update({"TERM": "xterm", "NO_COLOR": "1"})
        os.execvp(command[0], command)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    output, closed = drain(fd, QUIET, LIMIT)
    for chunk in chunks:
        if closed:
            break
        os.write(fd, chunk.encode())
        data, closed = drain(fd, QUIET, LIMIT)
        output += data
    while not closed:
        data, closed = drain(fd, QUIET, LIMIT)
        output += data
        if not data:
            break
    _, status = os.waitpid(pid, 0)
    text = output.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    sys.stdout.write(text)
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)


main()

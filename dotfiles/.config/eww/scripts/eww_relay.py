#!/usr/bin/env python3
"""Coalescing non-blocking relay: stdin -> stdout.

Sits between a `bspc subscribe` consumer and eww.

bspwm is single-threaded and writes subscribe events to each client with a
*blocking* write. If a subscriber stops reading its socket, bspwm's send
buffer fills, its event loop blocks in write(), and the entire WM freezes:
no X input is read (mouse clicks die) and no `bspc` query is answered
(keybinds that shell out to bspc hang forever).

That backpressure travels backwards from eww: eww stalls -> the shell loop
blocks in write() on eww's pipe -> it stops draining `bspc subscribe` ->
bspwm blocks. This relay cuts the chain: it always drains stdin
immediately, and writes to stdout without ever blocking. Only the newest
line is kept, so a stalled eww costs stale bar state instead of a dead WM.

Coalescing is safe because every producer here emits full current state
(a complete title, a complete workspace array), never a delta.
"""

import errno
import fcntl
import os
import select

STDIN, STDOUT = 0, 1


def set_nonblocking(fd):
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


def main():
    # The read end of our stdin pipe is a distinct file description from the
    # producer's write end, so this cannot affect the producer.
    set_nonblocking(STDIN)
    # Our stdout is eww's pipe. Only this process writes to it.
    set_nonblocking(STDOUT)

    inbuf = b""       # trailing partial line from stdin
    pending = None    # newest complete line awaiting write
    outbuf = b""      # line currently being written (may be partial)
    stdin_open = True

    while True:
        rlist = [STDIN] if stdin_open else []
        wlist = [STDOUT] if (outbuf or pending is not None) else []
        if not rlist and not wlist:
            return

        readable, writable, _ = select.select(rlist, wlist, [])

        if STDIN in readable:
            try:
                chunk = os.read(STDIN, 65536)
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    raise
                chunk = None  # spurious wakeup, not EOF
            if chunk == b"":
                stdin_open = False
            elif chunk:
                inbuf += chunk
                if b"\n" in inbuf:
                    complete, _, inbuf = inbuf.rpartition(b"\n")
                    # Keep only the newest complete line; drop the rest.
                    pending = complete.rpartition(b"\n")[2] + b"\n"

        if STDOUT in writable:
            if not outbuf and pending is not None:
                outbuf, pending = pending, None
            if outbuf:
                try:
                    written = os.write(STDOUT, outbuf)
                except OSError as exc:
                    if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        written = 0
                    elif exc.errno == errno.EPIPE:
                        return  # eww went away
                    else:
                        raise
                outbuf = outbuf[written:]

        if not stdin_open and not outbuf and pending is None:
            return


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass

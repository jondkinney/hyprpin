#!/usr/bin/env python3
"""Bounded, descriptor-disciplined state file IO for hyprpin.

The shell process must never materialize a replaceable state file wholesale,
and a pathname check followed by a separate open is a race. This helper opens
exactly once with O_NOFOLLOW|O_NONBLOCK, validates the opened descriptor with
fstat (regular file, owned by the invoking user, within the byte limit), and
reads or publishes only through descriptors. Writes stage into an exclusively
created 0600 file in the pinned directory descriptor and publish with an
atomic rename, so a reader never sees a torn file and a planted symlink at
the destination is replaced, not followed.

    statefile.py read  <absolute-path> <max-bytes>            -> content on stdout
    statefile.py write <absolute-path> <max-bytes>            <- content on stdin

Exit codes: 0 ok, 2 usage, 3 missing (read only), 4 refused (wrong type,
owner, mode, or link), 5 over the byte limit, 6 deadline expired, 7 io error.
"""

import os
import secrets
import signal
import stat
import sys

EXIT_USAGE = 2
EXIT_MISSING = 3
EXIT_REFUSED = 4
EXIT_TOOBIG = 5
EXIT_TIMEOUT = 6
EXIT_IO = 7

DEADLINE_SECONDS = 5
MAX_LIMIT = 1048576


def die(code, message):
    print("hyprpin-statefile: " + message, file=sys.stderr)
    sys.exit(code)


def cmd_read(path, limit):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        die(EXIT_MISSING, "no such file: " + path)
    except OSError as e:
        # ELOOP is the symlink rejection from O_NOFOLLOW.
        die(EXIT_REFUSED, "open refused for %s: %s" % (path, e.strerror))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            die(EXIT_REFUSED, "not a regular file: " + path)
        if st.st_uid != os.getuid():
            die(EXIT_REFUSED, "unexpected owner on " + path)
        if st.st_size > limit:
            die(EXIT_TOOBIG, "%s is %d bytes, limit %d" % (path, st.st_size, limit))
        # The size check above is only a precheck; still read at most
        # limit + 1 bytes through the same descriptor to cover growth races.
        chunks = []
        total = 0
        while total <= limit:
            block = os.read(fd, min(65536, limit + 1 - total))
            if not block:
                break
            chunks.append(block)
            total += len(block)
        if total > limit:
            die(EXIT_TOOBIG, "%s grew past the %d byte limit mid-read" % (path, limit))
    finally:
        os.close(fd)
    sys.stdout.buffer.write(b"".join(chunks))
    sys.stdout.buffer.flush()


def open_state_dir(directory):
    try:
        os.makedirs(directory, mode=0o755, exist_ok=True)
    except OSError as e:
        die(EXIT_IO, "cannot create %s: %s" % (directory, e.strerror))
    try:
        dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as e:
        die(EXIT_REFUSED, "open refused for directory %s: %s" % (directory, e.strerror))
    st = os.fstat(dfd)
    if st.st_uid != os.getuid():
        die(EXIT_REFUSED, "state directory has an unexpected owner")
    if st.st_mode & 0o022:
        die(EXIT_REFUSED, "state directory is group or world writable")
    return dfd


def cmd_write(path, limit):
    chunks = []
    total = 0
    while total <= limit:
        block = sys.stdin.buffer.read(min(65536, limit + 1 - total))
        if not block:
            break
        chunks.append(block)
        total += len(block)
    if total > limit:
        die(EXIT_TOOBIG, "stdin exceeded the %d byte limit" % limit)
    data = b"".join(chunks)

    directory, base = os.path.split(path)
    dfd = open_state_dir(directory)
    staging = ".%s.%d.%s.tmp" % (base, os.getpid(), secrets.token_hex(8))
    try:
        fd = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=dfd)
    except OSError as e:
        os.close(dfd)
        die(EXIT_IO, "cannot stage %s: %s" % (base, e.strerror))
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        os.rename(staging, base, src_dir_fd=dfd, dst_dir_fd=dfd)
        os.fsync(dfd)
    except OSError as e:
        try:
            os.unlink(staging, dir_fd=dfd)
        except OSError:
            pass
        die(EXIT_IO, "cannot publish %s: %s" % (base, e.strerror))
    finally:
        os.close(dfd)


def main():
    signal.signal(signal.SIGALRM, lambda *_: die(EXIT_TIMEOUT, "deadline expired"))
    signal.alarm(DEADLINE_SECONDS)

    if len(sys.argv) != 4 or sys.argv[1] not in ("read", "write"):
        die(EXIT_USAGE, "usage: statefile.py read|write <absolute-path> <max-bytes>")
    path = sys.argv[2]
    if not os.path.isabs(path) or "\0" in path:
        die(EXIT_USAGE, "path must be absolute")
    try:
        limit = int(sys.argv[3])
    except ValueError:
        die(EXIT_USAGE, "max-bytes must be an integer")
    if limit < 1 or limit > MAX_LIMIT:
        die(EXIT_USAGE, "max-bytes must be within 1..%d" % MAX_LIMIT)

    if sys.argv[1] == "read":
        cmd_read(path, limit)
    else:
        cmd_write(path, limit)


if __name__ == "__main__":
    main()

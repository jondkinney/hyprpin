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
    statefile.py placement <absolute-path> <max-bytes>        <- bounded rule delta

Exit codes: 0 ok, 2 usage, 3 missing (read only), 4 refused (wrong type,
owner, mode, or link), 5 over the byte limit, 6 deadline expired, 7 io error,
8 stale/missing rule or disabled plugin.
"""

import os
import fcntl
import json
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
EXIT_CONFLICT = 8

DEADLINE_SECONDS = 5
MAX_LIMIT = 1048576


def die(code, message):
    print("hyprpin-statefile: " + message, file=sys.stderr)
    sys.exit(code)


def read_data(path, limit, dir_fd=None):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dir_fd)
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
    return b"".join(chunks)


def cmd_read(path, limit):
    sys.stdout.buffer.write(read_data(path, limit))
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


def read_stdin(limit):
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
    return b"".join(chunks)


def lock_state(dfd, base):
    fd = os.open("." + base + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                 0o600, dir_fd=dfd)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
        os.close(fd)
        die(EXIT_REFUSED, "unsafe state lock")
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def publish(dfd, base, data):
    staging = ".%s.%d.%s.tmp" % (base, os.getpid(), secrets.token_hex(8))
    try:
        fd = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=dfd)
    except OSError as e:
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


def cmd_write(path, limit):
    data = read_stdin(limit)
    directory, base = os.path.split(path)
    dfd = open_state_dir(directory)
    lock = lock_state(dfd, base)
    try:
        publish(dfd, base, data)
    finally:
        os.close(lock)
        os.close(dfd)


PLACEMENTS = {"tile-right", "tile-bottom", "tile-left", "tile-top",
              "top-right", "bottom-right", "bottom-left", "top-left", "special", "fill"}


def reject_constant(_value):
    raise ValueError("non-finite JSON constant")


def cmd_placement(path, limit):
    request = json.loads(read_stdin(4096), parse_constant=reject_constant)
    if not isinstance(request, dict):
        die(EXIT_REFUSED, "placement request must be an object")
    for key in ("class", "title"):
        value = request.get(key)
        if not isinstance(value, str) or len(value) > 256 or (key == "class" and not value):
            die(EXIT_REFUSED, "invalid rule identity")
    if request.get("previous") not in PLACEMENTS or request.get("next") not in PLACEMENTS - {"fill", "special"}:
        die(EXIT_REFUSED, "invalid placement")
    directory, base = os.path.split(path)
    dfd = open_state_dir(directory)
    lock = lock_state(dfd, base)
    try:
        state = json.loads(read_data(base, limit, dir_fd=dfd), parse_constant=reject_constant)
        if not isinstance(state, dict) or not isinstance(state.get("rules"), list) or len(state["rules"]) > 64:
            die(EXIT_REFUSED, "invalid rules document")
        if state.get("enabled") is False:
            die(EXIT_CONFLICT, "plugin was disabled")
        for rule in state["rules"]:
            if not isinstance(rule, dict):
                continue
            if rule.get("class") != request["class"] or rule.get("title", "") != request["title"]:
                continue
            placement = rule.get("placement", "fill")
            if rule.get("tile") is True and placement not in {"tile-right", "tile-bottom", "tile-left", "tile-top"}:
                placement = "tile-right"
            if placement != request["previous"]:
                die(EXIT_CONFLICT, "placement changed before save")
            rule["placement"] = request["next"]
            rule.pop("tile", None)
            data = (json.dumps(state, ensure_ascii=True, allow_nan=False, separators=(",", ":")) + "\n").encode()
            if len(data) > limit:
                die(EXIT_TOOBIG, "updated rules exceed byte limit")
            publish(dfd, base, data)
            return
        die(EXIT_CONFLICT, "rule no longer exists")
    finally:
        os.close(lock)
        os.close(dfd)


def main():
    signal.signal(signal.SIGALRM, lambda *_: die(EXIT_TIMEOUT, "deadline expired"))
    signal.alarm(DEADLINE_SECONDS)

    if len(sys.argv) != 4 or sys.argv[1] not in ("read", "write", "placement"):
        die(EXIT_USAGE, "usage: statefile.py read|write|placement <absolute-path> <max-bytes>")
    path = sys.argv[2]
    if not os.path.isabs(path) or "\0" in path:
        die(EXIT_USAGE, "path must be absolute")
    try:
        limit = int(sys.argv[3])
    except ValueError:
        die(EXIT_USAGE, "max-bytes must be an integer")
    if limit < 1 or limit > MAX_LIMIT:
        die(EXIT_USAGE, "max-bytes must be within 1..%d" % MAX_LIMIT)

    try:
        {"read": cmd_read, "write": cmd_write, "placement": cmd_placement}[sys.argv[1]](path, limit)
    except (ValueError, TypeError, UnicodeError, RecursionError):
        die(EXIT_REFUSED, "invalid JSON request or state")
    except OSError as e:
        die(EXIT_IO, str(e))


if __name__ == "__main__":
    main()

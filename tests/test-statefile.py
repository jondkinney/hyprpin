#!/usr/bin/env python3
"""Behavioral boundary tests for statefile.py.

Exercises the failure modes the marketplace review checks: exact limit and one
byte over, symlink and FIFO inputs (rejection, not a hang), a symlink planted
at the write destination (replaced, not followed), oversized stdin, and torn
or missing files. Run from anywhere: python3 tests/test-statefile.py
"""

import json
import os
import subprocess
import sys
import tempfile

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "statefile.py")
PY = sys.executable or "/usr/bin/python3"

failures = []


def run(args, stdin=None):
    return subprocess.run([PY, "-I", HELPER] + args, input=stdin,
                          capture_output=True, timeout=15)


def check(name, ok, detail=""):
    print("%-52s %s" % (name, "ok" if ok else "FAIL " + detail))
    if not ok:
        failures.append(name)


with tempfile.TemporaryDirectory() as tmp:
    os.chmod(tmp, 0o700)
    state = os.path.join(tmp, "state")

    # -------------------------------------------------------------- read side
    target = os.path.join(state, "rules.json")
    os.makedirs(state, mode=0o755)

    with open(target, "wb") as f:
        f.write(b"x" * 100)
    r = run(["read", target, "100"])
    check("read: file exactly at limit", r.returncode == 0 and r.stdout == b"x" * 100)

    r = run(["read", target, "99"])
    check("read: one byte over limit refused", r.returncode == 5)

    r = run(["read", os.path.join(state, "absent.json"), "100"])
    check("read: missing file distinct exit", r.returncode == 3)

    link = os.path.join(state, "link.json")
    os.symlink(target, link)
    r = run(["read", link, "100"])
    check("read: symlink refused", r.returncode == 4)

    fifo = os.path.join(state, "pipe.json")
    os.mkfifo(fifo)
    r = run(["read", fifo, "100"])  # would hang forever without O_NONBLOCK
    check("read: FIFO refused without hanging", r.returncode == 4)

    r = run(["read", "relative/path.json", "100"])
    check("read: relative path refused", r.returncode == 2)

    # ------------------------------------------------------------- write side
    out = os.path.join(state, "out.json")
    r = run(["write", out, "50"], stdin=b'{"v":1}')
    with open(out, "rb") as f:
        published = f.read()
    mode = os.stat(out).st_mode & 0o777
    check("write: publishes stdin content", r.returncode == 0 and published == b'{"v":1}')
    check("write: published mode is 0600", mode == 0o600, oct(mode))

    r = run(["write", out, "5"], stdin=b"123456")
    with open(out, "rb") as f:
        after = f.read()
    check("write: oversized stdin refused, file untouched",
          r.returncode == 5 and after == b'{"v":1}')

    victim = os.path.join(state, "victim.txt")
    with open(victim, "wb") as f:
        f.write(b"precious")
    trap = os.path.join(state, "trap.json")
    os.symlink(victim, trap)
    r = run(["write", trap, "50"], stdin=b"overwrite")
    with open(victim, "rb") as f:
        victim_after = f.read()
    check("write: symlink destination replaced, target untouched",
          r.returncode == 0 and victim_after == b"precious"
          and not os.path.islink(trap) and open(trap, "rb").read() == b"overwrite")

    r = run(["write", os.path.join(state, "missing-dir", "x.json"), "50"], stdin=b"{}")
    check("write: creates missing state dir", r.returncode == 0)

    leftovers = [n for n in os.listdir(state) if n.endswith(".tmp")]
    check("write: no staging files left behind", leftovers == [], repr(leftovers))

    wide = os.path.join(tmp, "wide")
    os.makedirs(wide, mode=0o777)
    os.chmod(wide, 0o777)
    r = run(["write", os.path.join(wide, "x.json"), "50"], stdin=b"{}")
    check("write: world-writable directory refused", r.returncode == 4)

    r = run(["frobnicate", out, "50"])
    check("usage: unknown subcommand refused", r.returncode == 2)
    r = run(["read", out, "0"])
    check("usage: zero limit refused", r.returncode == 2)
    r = run(["read", out, "9999999999"])
    check("usage: absurd limit refused", r.returncode == 2)

print()
if failures:
    print("FAILED: %d test(s)" % len(failures))
    sys.exit(1)
print("all statefile tests passed")

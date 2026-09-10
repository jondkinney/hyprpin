#!/usr/bin/env python3
"""Durable placement updates preserve unrelated settings and reject stale writes."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile

helper = str(Path(__file__).resolve().parents[1] / 'statefile.py')
checks = 0

def check(label, condition):
    global checks
    assert condition, label
    checks += 1
    print('ok:', label)

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'hyprpin.json'
    rule = {'class': '^Test$', 'title': '', 'placement': 'tile-right', 'monitor': 'DP-1', 'stay': True, 'label': 'My call'}
    base = {'version': 1, 'enabled': True, 'rules': [rule, {**rule, 'class': '^Other$'}], 'extra': 'preserve'}
    request = {'class': '^Test$', 'title': '', 'previous': 'tile-right', 'next': 'tile-bottom'}
    def restore(state=base):
        path.write_text(json.dumps(state))
    def run(data=request, limit=262144, target=path):
        payload = data if isinstance(data, bytes) else json.dumps(data).encode()
        return subprocess.run(['/usr/bin/python3', '-I', helper, 'placement', str(target), str(limit)],
                              input=payload, capture_output=True, timeout=10)
    restore()
    check('placement save succeeds', run().returncode == 0)
    saved = json.loads(path.read_text())
    check('only selected placement changes', saved == {**base, 'rules': [{**rule, 'placement': 'tile-bottom'}, base['rules'][1]]})
    check('published file is private', path.stat().st_mode & 0o777 == 0o600)
    before = path.read_bytes()
    check('stale placement is refused without changing file', run().returncode == 8 and path.read_bytes() == before)
    check('removed rule is refused', run({**request, 'class': '^Missing$'}).returncode == 8)
    restore({**base, 'enabled': False})
    check('disabled plugin is preserved', run().returncode == 8 and not json.loads(path.read_text())['enabled'])
    for constant in ['NaN', 'Infinity', '1e999']:
        path.write_text(json.dumps(base)[:-1] + ',"extra":' + constant + '}')
        before = path.read_bytes()
        check('non-finite JSON is refused', run().returncode == 4 and path.read_bytes() == before)
    for raw in [None, [], 1, True, '', {}, {'rules': {}}, {'rules': [rule] * 65}]:
        restore(raw)
        before = path.read_bytes()
        check('wrong document shape refused: ' + str(type(raw).__name__), run().returncode != 0 and path.read_bytes() == before)
    for value in [None, [], 1, 'bad', {}, {**request, 'class': 'x' * 257}, {**request, 'next': []},
                  {**request, 'next': 'fill'}, {**request, 'previous': 'bad'}, {**request, 'title': False}, b'{', b'x' * 4097]:
        restore()
        before = path.read_bytes()
        check('malformed request leaves state intact', run(value).returncode != 0 and path.read_bytes() == before)
    restore()
    data = path.read_bytes()
    path.write_bytes(data + b' ' * (262144 - len(data)))
    check('input exactly at byte limit is accepted', run().returncode == 0)
    path.write_bytes(data + b' ' * (262145 - len(data)))
    check('oversized state is refused', run().returncode == 5)
    path.write_text(json.dumps({**base, 'rules': [{**rule, 'label': 'é' * 500}]}, ensure_ascii=False))
    limit = len(path.read_bytes())
    check('expanded output respects writer limit', run(limit=limit).returncode == 5)
    link = Path(tmp) / 'link.json'
    link.symlink_to(path)
    check('symlink state is refused', run(target=link).returncode == 4)
    fifo = Path(tmp) / 'fifo.json'
    os.mkfifo(fifo)
    check('FIFO state is refused without blocking', run(target=fifo).returncode == 4)
    restore({**base, 'rules': [{**rule, 'placement': 'bottom-right', 'tile': True}]})
    check('legacy tiled placement migrates', run().returncode == 0 and 'tile' not in json.loads(path.read_text())['rules'][0])
    restore()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(run, [request, {**request, 'class': '^Other$', 'next': 'tile-left'}]))
    check('concurrent changes preserve both rules', all(r.returncode == 0 for r in results)
          and [r['placement'] for r in json.loads(path.read_text())['rules']] == ['tile-bottom', 'tile-left'])
    restore()
    lock = Path(tmp) / '.hyprpin.json.lock'
    lock.unlink()
    lock.symlink_to(path)
    before = path.read_bytes()
    check('planted lock symlink is refused', run().returncode != 0 and path.read_bytes() == before)
    lock.unlink()
    os.chmod(tmp, 0o777)
    check('unsafe parent is refused', run().returncode == 4)
    os.chmod(tmp, 0o700)
print(f'all {checks} placement state checks passed')

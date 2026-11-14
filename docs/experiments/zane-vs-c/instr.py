#!/usr/bin/env python3
"""Callgrind instruction counts of each named test for one or more binaries.

usage: instr.py FILTER BIN [BIN ...] [--scale K]
Each test of run.js whose name contains FILTER runs alone under Callgrind
with its iterations divided by K (default 10) and no warmup, so checksums
read ERR; the counts are for comparing builds. Brainfuck, which runs its
program once, runs its short warmup program 10000 times instead. The binaries
run in parallel. Prints a row per test.
"""
import json, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
args = [a for a in sys.argv[1:] if not a.startswith('--scale')]
scale = int(next((a.split('=')[1] for a in sys.argv[1:] if a.startswith('--scale=')), 10))
flt, bins = args[0], args[1:]
tests = [t for t in json.load(open(ROOT / 'run.js')) if flt.lower() in t['name'].lower()]
print('| Test | ' + ' | '.join(Path(b).name for b in bins) + ' |')
print('| --- |' + ' ---: |' * len(bins))
for t in tests:
    t = dict(t, iterations=max(1, t['iterations'] // scale), warmup_iterations=0)
    if 'warmup_program' in t:
        t = dict(t, program=t['warmup_program'], iterations=10000)
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump([t], f)
    def count(b):
        err = subprocess.run(['valgrind', '--tool=callgrind', '--callgrind-out-file=/dev/null', b, f.name],
                             text=True, capture_output=True).stderr
        m = re.search(r'refs:\s+([\d,]+)', err)
        return f"{int(m.group(1).replace(',', ''))/1e9:.3f}G" if m else 'fail'
    with ThreadPoolExecutor(4) as pool:
        row = list(pool.map(count, bins))
    print(f"| {t['name']} | " + ' | '.join(row) + ' |', flush=True)

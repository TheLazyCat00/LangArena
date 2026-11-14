# Experiment: bring Zane as far below C as possible

An open-ended experiment: take the `zane-perf` port (76bc235) and push its
time against the C reference down as far as it goes, by port changes that
make it do what C does and, where the compiler is the reason, by prototype
compiler changes behind environment switches. Spec rules do not bind the
prototypes; where one departs from the spec, the step says so.

Earlier work and the issue list (R1–R8, B1–B3) are on the
`zane-perf-issues` branch, `zane/perf-issues/README.md`.

## How to build and measure

- Zane CLI v0.15, compiler **v0.36** (22397fc), core v0.10. The port's
  `zane.coda` is moved to `zane-version v0.36`.
- C: `make -j4 prod` in `c/` (gcc 13, `-O2`), needs `uthash-dev`.
- The compiler is built from `zane-lang/compiler` branch `perf/zane-vs-c`
  (`pixi run just build`). `build.sh` builds the port with it, run inside a
  copy of the v0.36 release toolchain: a bare dev `zanec` compiles the
  runtime with the system `clang` instead of the release's `zig cc`, which
  changes the program's code (HuffEncode 5.96G → 5.69G instructions and
  slower). Inside the release toolchain, the unchanged branch builds a
  binary byte-identical to the v0.36 release's.
- `ab.py A B` interleaves two Zane binaries and reports B / A per test.
- `measure.py` runs both binaries on `run.js`, interleaved, `--rounds N`
  times, and reports each test's minimum time and the geomean of Zane / C:

  ```
  python3 docs/experiments/zane-vs-c/measure.py --rounds 3 --out results.json
  ```

- Timings come from a 4-core cloud container, so they are noisy (a few %);
  each number is the minimum of its rounds.

## Step 0: baseline

`baseline.md` (table) and `baseline.json` (every round's times), 3 rounds:
**geomean 0.934** (the earlier run on another machine: 0.93). Tests at 1.2× C
or slower here: BWTDecode 1.87, Brainfuck::Recursion 1.70, BWTEncode 1.54,
Matmul::T4 1.54 (threads; noisy), Brainfuck::Array 1.45, Json::ParseDom
1.33, Graph::DFS 1.31, Json::ParseMapping 1.30, NeuralNet 1.28, HuffDecode
1.27, LZWEncode 1.24, CacheSimulation 1.20.

Run to run, a test's time moves by up to 10% on this machine, so a change
is judged by `ab.py` (interleaved) and, where it can be, by Callgrind
instruction counts.

## Step 1: port changes toward C (dropped)

Three changes that make the port do what C does, measured with `ab.py`, 4
rounds, against the unchanged port:

| change | test | B / A |
| --- | --- | ---: |
| filter + jump table made once in `prepare`, as C | Brainfuck::Array | 1.09 |
| ranks as C's interleaved `(first, second)` pairs | BWTEncode | 1.03 |
| a leaf flag (C's `is_leaf`) + output reserved up front | HuffDecode | 1.17 |

None helped (the leaf flag grows a node from 32 to 40 bytes), so all three
were reverted. Two other port rewrites, Brainfuck ops as a variant case per
operation and LZWEncode building its string in place, only dodge compiler
issues (R8, R7) and were dropped in favour of fixing the compiler.

## What remains

- (filled in as steps land)

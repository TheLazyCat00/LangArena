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

## Step 2: one call site for a loop's callee (R8), `ZANE_VERSION_CALLS=0`

**Design.** `Emit.versioned` emits a loop that indexes a list twice, a
long and a short copy, so IRCE can drop the long one's checks. A call in
its body then has two call sites, and LLVM's inliner, which gives a
function with one caller a large bonus, leaves a mid-sized callee out of
line (Brainfuck's `command`: cost 315, threshold 225). With the switch, a
loop that calls any function is emitted once (`lib/codegen/emit.ml`,
`calls_stay_single`).

**Results.** `instr.py`, all 50 tests (iterations / 10; Brainfuck runs its
warmup program 10000 times): Brainfuck::Recursion 0.596G → 0.560G (−6%),
`command` now inlined into `runOps`; every other test within 0.5%
(CSV, CacheSimulation, LogParser, Template, BWTEncode slightly lower).

## Step 3: move a held local at its last read (R7), `ZANE_ASSIGN_MOVES=1`

**Design.** The perf-issues R7 prototype (`Regions.assigned_moves`,
`lib/cgt/regions.ml`), moved onto v0.36 and made opt-in, plus one case it
lacked: when the last read of the held local is the `else` of a flag,
`let f = { …; if(c) { T }; f := c }` … `{ if(~f) { E } }`, the copy that is
last in T is also made a move, since the two branches are exclusive. Reads
before the `if` (LZWEncode's `dict:has(combined)`) come before the move.

**Results.** `perf-issues/repros/string-assign` plus a form 4 shaped as
LZWEncode (an `else` that reads `combined`), Callgrind, 1000000 rounds:

| form | off | on |
| --- | ---: | ---: |
| 1 `combined=…; current=combined` | 675.3M | 301.3M |
| 2 the same in an `if` | 675.3M | 300.3M |
| 4 `if/else`, else reads it | 592.0M | 284.3M |

Memcheck clean on form 4 and on `test.js` LZW. Compress::LZWEncode:
1.994G → 1.353G instructions (−32%); `ab.py` 4 rounds 2.238 s → 1.688 s
(C: 1.889 s). All 50 checksums OK.

## Step 4: the Json gap (open)

Json::ParseDom / ParseMapping are 1.30–1.33× C. Callgrind (10 iterations):
Zane runs 237M instructions against C's 208M, though fewer inside
`yyjson_read_opts` (126M vs 140M); the rest is `arena_json_get`'s
lookups and about 9M more `memcpy`. Simulated branch and cache misses are
about equal (1.00M vs 0.91M mispredicts), minor faults are equal (2654 vs
2438), and C built with clang is as fast as with gcc. Dropping the LLVM
options Zane starts with (`ZANE_LLVM_OPTIONS=`, keeps none) changed
nothing. Without hardware counters (no `perf` here), the remaining 15% of
wall time is not explained.

## Step 5: BWTDecode, and why every byte-oriented port is slow

Callgrind of the decode loop `index=next[index]; out!push(byte(input,
index))`: 20 instructions per byte, against C's 5. Core has no byte type,
so the port keeps bytes in `arena$Buffer`, a C struct behind a handle.
Each `push` stores a `uint8_t`, which may alias anything, so every
iteration reloads both handles from the frame and each Buffer's size,
capacity and data pointer. The same holds in every port that works on
bytes (BWT, Huffman, LZW, Base64, Arith, CRC32, the Brainfuck tape).

Side finding: `filled(Int(256), Int(0))` (arena's push loop) is unrolled
into 256 checked pushes, about 50 KB of code in `bwt$decode` alone.

## Step 6: a native byte type, `U8`

**Design.** Compiler (`perf/zane-vs-c`): a primitive `@primitives$U8`
lowered to LLVM `i8` (`Ty.I8`), with `==`, `<`, conversions to and from
`I64`/`I32` (`wrap` towards U8), literals 0–255, and three intrinsics:
`String:byteCount()`, `String:byteAt(i)` (a checked load of the text's
byte, lowered to `Array_at` like a list read) and `List<T>:text()`, a
String copied from a byte list (runtime `zane_text_bytes`). Core
(`zane-lang/core` branch `perf/zane-vs-c`): `U8`, `Int(U8)`, `U8.wrap`,
`String.byteCount/byteAt`, `String(List<U8>)`. The port's `zane.coda`
points at a local core checkout (`core v0.10 /home/user/core`) while this
runs.

Port: `codec.frequencies` and `bwt.encode/decode` read the String's bytes
and build a `List<U8>` instead of an `arena$Buffer`.

**Results.** `decode` 450M → 290M instructions (C: 264M), `frequencies`
143M → 77M. Compress::BWTDecode 4.392G → 3.932G (−10.5%); BWTEncode
unchanged (its time is the suffix sort). All 50 checksums OK; compiler
tests and core's tests pass.

What is left in the decode loop is the output list: its count and block
are loaded from and stored to the frame on every push. LICM does not
promote them to registers because the loop's bounds check makes the push
conditionally executed (reproduced in a small IR file: without the check,
no count access stays in the loop).

## What remains

- Keep a pushed-to list's count and block in registers across a loop
  (step 6).
- Move the other byte ports (Huffman, LZW, Base64, Arith, CRC32, SHA256,
  the Brainfuck tape) to `U8`.
- The Json gap (step 4).

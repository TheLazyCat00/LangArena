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
143M → 77M. Compress::BWTDecode 4.392G → 3.932G (−10.5%; 3.890G with the
runtime bundled, step 7); BWTEncode
unchanged (its time is the suffix sort). All 50 checksums OK; compiler
tests and core's tests pass.

What is left in the decode loop is the output list: its count and block
are loaded from and stored to the frame on every push. LICM does not
promote them to registers because the loop's bounds check makes the push
conditionally executed (reproduced in a small IR file: without the check,
no count access stays in the loop).

## Step 7: the runtime bundle, and a correction

The dev toolchain is a copy of v0.36's, whose `share/runtime` bundles
the runtime compiled from v0.36's sources. Once the experiment branch
changed the runtime (step 6's `zane_text_bytes`), zanec no longer found it
in the bundle and compiled it with `zig cc`, whose bitcode its LLVM 21
cannot read, so no runtime body was inlined (Runtime_bodies): CacheSimulation
+10% instructions, Words +4.5%, CSV +2%, with the port unchanged.
`build.sh` now bundles the changed runtime as a release does
(`zanec --bundle-runtime`, bitcode by the pixi environment's clang 21
through `dev/release/bitcode-cc`), once per runtime. Step 6's totals are
restated with it: BWTDecode 4.392G → 3.890G, HuffEncode 1.433G → 1.273G and
ArithEncode 0.876G → 0.836G (both use `codec.frequencies`).

## Step 8: three switches revisited

`instr.py` over all 50 tests, each switch alone against the build without
switches, found two regressions, both fixed:

- `ZANE_ASSIGN_MOVES=1` made Brainfuck::Recursion +22% (0.596G → 0.725G).
  Its "taken once, so a `let`" rewrite also caught holds whose move a
  return had already made (`returned_moves`), which the later fold turns
  into a plain value with no arena at all; the rewrite left an empty arena
  around `ops!push(Op.loop(this!parse()))`, and each push moved the value
  through the runtime. The rewrite now applies only to a hold this pass
  gave its move. Recursion 0.596G again; LZWEncode keeps −32%.
- `ZANE_VERSION_CALLS=0` (any call keeps a loop single) cost SHA256 +3.5%
  and Maze a little: their loops call small functions with many callers,
  which LLVM inlines anyway, and lost IRCE's unchecked copy.
  `ZANE_VERSION_CALLS=1` keeps a loop single only when it calls a function
  with one call site in the program, the case where two copies cost LLVM's
  single-caller inline bonus: Recursion −6% as before, SHA256 and Maze
  unchanged.

`ZANE_LOOP_REGS=1` (new, `lib/codegen/emit.ml`): a loop whose pushes were
reserved up front (`Loop_shapes.looped_pushes`) reads the list's block once
before it and keeps its count in a local, storing the count back after each
push, so the push reloads nothing. LICM could not do it: the loop's bounds
checks make the push conditionally executed, which blocks its scalar
promotion. BWT's decode loop is now 13 instructions per byte; with U8,
Compress::BWTDecode went from 2.04× C to 0.99× (3 rounds, `measure.py`).

## Step 9: a timed run, and more byte ports

`measure.py`, 3 rounds, with `ZANE_LOOP_REGS=1 ZANE_ASSIGN_MOVES=1
ZANE_VERSION_CALLS=1` and the U8 ports of step 6: **geomean 0.917**
(baseline 0.934). BWTDecode 1.87 → 1.02, LZWEncode 1.24 → 0.86, LZWDecode
→ 0.72. Still 1.2× C or slower: Brainfuck::Array 1.51, Recursion 1.47,
Matmul::T8/T16 ~1.4 (threads; a direct run of T4 gives 1.5–1.9 s for both
languages run to run), Json 1.31/1.34, NeuralNet 1.32, BWTEncode 1.31, DFS
1.27, HuffDecode 1.25, Binarytrees::Arena 1.22, CacheSimulation 1.20.

More ports to `U8`, each against the build before it (`ab.py`, 4 rounds):

| change | test | instructions | time B / A |
| --- | --- | ---: | ---: |
| Brainfuck tape `List<U8>` (was `Buffer`) | Array (real program) | 27.6G → 28.1G | — |
| Huffman encode: String bytes in, `List<U8>` out | HuffEncode | 1.273G → 0.927G | 0.86 |
| Huffman decode, the same | HuffDecode | 2.389G → 2.472G | 1.31 |
| Huffman decode, input only | HuffDecode | | 1.11 |

The decode's inner loop is the same instructions in both builds and
Cachegrind's branch and cache simulation shows no difference (13.3% vs
12.1% mispredicted), so the 31% is something the simulator does not model;
without hardware counters it stays unexplained. Huffman's decode keeps its
`Buffer`; its encode uses U8. The Brainfuck tape stays `List<U8>`, which
is what C does (a `uint8_t` array).

## Step 10: frame slots and alias analysis (two switches, little effect)

Brainfuck::Array's interpreter loop reloads the command list, the jump
list and the tape (block, count, position) from the frame on every step:
the cold `zane_list_push` that grows the tape may, as far as LLVM knows,
write any slot of the frame, since the runtime can reach it. C's tape is a
local whose address escapes only to inlined code.

- `ZANE_FRAME_SCOPES=1` (`lib/codegen/frame_scopes.ml`): after the `-O2`
  pipeline, accesses at constant offsets from one base are grouped by the
  bytes they touch and each group gets an alias scope
  (`llvm.experimental.noalias.scope.decl` where the base is made); the
  runtime's list growth calls get their header's group. Then LICM and GVN
  run again. Tagging before the pipeline missed the calls, which reach the
  loop only by inlining `core`'s `push`. The command and jump lists' loads
  then leave the loop, but the tape's fields are written in the loop, and
  LLVM promotes a conditionally written location only when its object
  does not escape, which a frame does. Brainfuck::Array unchanged; Json
  −1.5% to −3.6% instructions, Spectralnorm +1.7%.
- `ZANE_SIZED_TBAA=1` (`lib/codegen/emit.ml`): one-byte scalars (Bool, U8)
  get a TBAA tag apart from wider ones, both children of the scalar tag,
  since a place is only read back as a type of the size it was written as.
  It did not keep Huffman decode's `tree.root` in a register (the reload
  there is register pressure, not aliasing).

## Step 11: what the remaining slow tests do differently

`hotasm.py TEST BIN` profiles one test in both languages with Callgrind
and prints each side's hottest functions and their hot instructions beside
the disassembly. Both get the same explicit warmup count: the C harness
reads a warmup of 0 as its default, a fifth of the iterations and at least
one, so a Zane run with warmup 0 against C compares unequal work (every
C-vs-Zane instruction ratio before this step that used warmup 0 overcounts
C by that much).

Same work, Zane / C:

| test | instructions | time | what differs |
| --- | ---: | ---: | --- |
| Json::ParseDom | 1.32 | 1.31 | text copied per parse; yyjson +8% under zanec's LLVM |
| NeuralNet | 1.31 | 1.32 | indices where C has pointers |
| CacheSimulation | 1.34 | 1.20 | strings allocated and freed per access |
| BWTEncode | 1.72 | 1.31 | data-dependent bounds checks; lists zeroed |
| HuffDecode | 1.72 | 1.25 | index chase and a branch where C has a pointer and `cmov` |
| Binarytrees::Arena | 0.82 | 1.17 | same code; unexplained |
| Graph::DFS | 0.87 | 1.27 | stack count kept in the frame |
| Brainfuck::Array (real program) | ~2.1 | 1.51 | interpreter state in the frame, checks |

- **Json.** `jsonParse(this.text)` deep-copies the String field
  (`copy … layout: %primitives$String` in the CGT, 11M instructions of
  memcpy) and hands the copy to C, whose parameter is a read-only view.
  The yyjson parser itself, the same C source, runs 151.5M instructions
  compiled by zanec's pipeline against 139.9M by gcc `-O2`, and the port
  reads each coordinate by three FFI calls (`arena_json_get`, 30M against
  C's 16M loop).
- **NeuralNet.** C's synapse holds `NeuralNetNeuron *source_neuron`; the
  port holds a 1-based `Int` into `neurons`. Each hop is then `dec`, a
  bounds check (`cmp`, `jae`) and a shift where C has one load: 13
  instructions per synapse in `feed` against C's 7, 20 against 13 in
  `update`. C also stores weight and previous weight as one `movups`.
- **CacheSimulation.** `String("item_")+String(n)` allocates twice per
  access, and the node's value string is replaced each hit: the runtime's
  `zane_alloc_held`, `zane_free`, `zane_region_at` (finding a block's
  region from its address) and memcpy take about 400M instructions
  against C's 120M of malloc and free, where C formats the key into a
  stack buffer.
- **BWTEncode.** The rank loop does six bounds checks per element, two
  indices against three lists that all have `n` elements, which C does not
  check at all; the indices come from data, so IRCE cannot drop them. Each
  round allocates five lists through `filled(n, 0)`: memset is 221M
  instructions against C's 53M (C mallocs its scratch arrays unzeroed;
  Callgrind counts a `rep stosb` byte as an instruction, so time pays
  less than that).
- **HuffDecode.** C walks pointers and picks the child with `cmovae`; the
  port walks 1-based indices (`dec`, `shl $5`, bounds check, load) and
  branches on the bit, then checks the same bound on both sides. A switch
  that sends every failed check of a function to one block
  (`ZANE_ONE_STOP=1`, `Emit.element`) lets LLVM make the choice a select,
  branch-free as in C, and HuffDecode gets 24% slower: without the
  prediction the CPU waits on the longer index-to-address chain at every
  bit. Off by default.
- **Graph::DFS.** Fewer instructions than C (1363M against 1575M) and
  fewer simulated misses and mispredicts, yet slower. The stack's count
  lives in the frame (`0xf8(%rdi)`): every pop loads, decrements and
  stores it, and the next push or pop loads it again, a chain through
  memory each step; C's `stack_top` is a register.
- **Binarytrees::Arena.** `build` and `sum` are instruction for
  instruction what C's are (Zane's count field is 32-bit, its `sum` turns
  the right call into a loop), 562M against 687M, with fewer simulated
  misses; 0.64 s against 0.55 s is not explained by the code.
- **Brainfuck::Array / Recursion** (steps 9–10): the tape's block, count
  and position, and in Recursion `ops`'s count, are reloaded from memory
  each step; each `ops[i]` and tape access is checked; Recursion
  dispatches twice (the variant's tag, then the command byte) where C
  switches once over its op type.

Page faults are not it: over full runs system time is near 0 on both
sides, and Zane faults less than C (Binarytrees::Arena 6445 vs 12383).

The two switches of step 10 over all 50 tests (instructions, against the
three kept switches): `ZANE_SIZED_TBAA=1` Maze::Generator −9.5%, Maze::BFS
−7.8%, Maze::AStar −6.7%; `ZANE_FRAME_SCOPES=1` on top, Distance::Jaro
−16%, Json −1.3% to −3.6%, Spectralnorm +1.7%.

## Step 12: a three-way wall-clock re-bench

`rebench3.py` runs three binaries on `run.js`, interleaved, and appends each
round to `rebench3.json`. This step used 5 rounds and takes each test's median
time. Wall time only; no Callgrind.

- **C:** `make -j4 prod`.
- **base:** `zane-perf` 76bc235 built with the v0.36 release, the port's
  `zane-version` moved to v0.36, no switches.
- **new:** this branch at fad9277 (the U8 ports), built by `build.sh` with
  compiler `perf/zane-vs-c` 082f244 and `ZANE_LOOP_REGS=1
  ZANE_ASSIGN_MOVES=1 ZANE_VERSION_CALLS=1`.

**Geomean: base 0.921× C, new 0.905× C** (new / base 0.982). At 1.2× C or
slower: 10 tests in base, 8 in new. LZWEncode, Maze::BFS and BWTEncode left
that list; Matmul::T4 joined it, at 1.23. The Claude Doc's chart shows the
new column.

These changed by more than 5%, and the new build's five times and the base
build's five times do not overlap:

| test | base × C | new × C | new / base |
| --- | ---: | ---: | ---: |
| Calculator::Interpreter | 0.38 | 0.24 | 0.65 |
| Maze::Generator | 0.82 | 0.57 | 0.70 |
| Maze::AStar | 0.98 | 0.71 | 0.72 |
| Maze::BFS | 1.20 | 0.88 | 0.73 |
| Compress::LZWEncode | 1.26 | 0.94 | 0.75 |
| Brainfuck::Recursion | 1.56 | 1.36 | 0.87 |
| Compress::BWTDecode | 1.15 | 1.06 | 0.91 |
| Compress::HuffEncode | 0.75 | 0.69 | 0.92 |
| Brainfuck::Array | 1.43 | 1.33 | 0.93 |
| Json::ParseMapping | 1.26 | 1.45 | 1.15 |

- **Gains the earlier steps explain:**
  - LZWEncode: step 3.
  - Brainfuck::Recursion: step 8.
  - BWTDecode and HuffEncode: steps 6–9.
- **Gains no step explains:** Maze and Calculator::Interpreter. Graph::AStar
  (0.92) and Graph::DFS (0.94) are faster too, but their times overlap.
  Step 11 counts Maze −7% to −10% instructions with `ZANE_SIZED_TBAA`, but
  that switch was off here. An A/B of one switch at a time would show which
  switch does it.
- **Json::ParseMapping, +15%:** a regression with no overlap between the
  two builds (base 0.269–0.288 s, new 0.306–0.332 s). Json::ParseDom moved
  +11%, with overlap. Its cause is not known yet. It needs explaining
  before any of the switches goes to `main`.
- **Times that jump:** Etc::Words, Template::Regex, Template::Parse and
  Etc::GameOfLife each come out at one of two levels, about 30% apart, in
  both builds (Template::Regex: 1.07 s or 1.72 s). Their medians differ by
  23–30% between the builds, but the ranges overlap almost fully, so this
  run says nothing about them. Etc::Sieve and Graph::BFS also jump, C
  included (C's Graph::BFS ran 0.81–1.38 s).
## Step 13: the three compiler fixes of step 11, timed

Each is a switch on `perf/zane-vs-c`, off by default, judged by wall time
(`ab.py`, interleaved rounds) against the step-9 set (`ZANE_LOOP_REGS=1
ZANE_ASSIGN_MOVES=1 ZANE_VERSION_CALLS=1`). All 50 checksums pass with
each on.

- **`ZANE_LENT_OWNERS=1`** (`Lower_calls.owner_path`, 40b806c). Json's
  copy came from the conversion `@primitives$String(this.text)`: a lent
  conversion (L11) reads a member where it is only when its place is
  rooted in plain values, and `State` is a reference type (it holds a
  `Json`), so the conversion was expanded and its `return` copied the
  String. The switch lets the place be a member of an owner a local
  holds, unless a spawned call may write it back (`snapshots`). Only
  `jsonbench$step` and `csvbench$step` change: Json::ParseDom −6%,
  ParseMapping −5%, CSV::Parse −4% (7 rounds). This does not account for step 12's +15% ParseMapping regression, which predates it.
- **`ZANE_FRAME_SHADOW=1`** (`lib/codegen/frame_shadow.ml`, ec31bb6). DFS's
  push goes through core's `push`, which LLVM inlines, so emit cannot keep
  the header in registers itself; this is an IR pass after O2. Each slot
  of a frame (a base an `llvm.assume dereferenceable` names) past the
  record that is only loaded and stored whole, always as one scalar type,
  gets a write-through copy in an alloca: filled where the frame is
  placed, stored with every store, filled again after any call given an
  address in the frame. Where a slot's address is stored (a deferred
  `.move` job keeps it, and may rewrite the list's block), the copy is
  filled again after every call the frame dominates. Loads read the copy,
  which SROA makes a register. 34 functions get copies; Graph::DFS −10%
  in each of three runs; Brainfuck::Recursion and Jaro −11% in one run
  and within noise in others.
- **`ZANE_MERGE_CHECKS=1`** (`lib/codegen/merged_checks.ml`, 897de93).
  The lists BWTEncode indexes together have the same length, but `indices`
  comes back from `byKey` (not inlined) and `ranks` is reassigned each
  round, so LLVM cannot prove it. Proving it is not needed: a failed check
  flushes output and exits, so a later check of the same index on the
  same straight path, with no call between, can be folded into the
  earlier one, which then compares with the smaller bound
  (`llvm.umin`). In BWTEncode's ranking loop `prior` is now checked once
  where it was checked three times; `index` keeps three checks, and two
  of the merged bounds are spilled and reloaded each time round.
  BWTEncode's instructions 395M → 374M, wall time −2%. (Its other costs
  are `byKey`, 37%, and the zeroing in `filled`, 19%.) A known loosening:
  output written by inlined code, without a call, between two merged
  checks is lost if the later check fails. LOOP_REGS now also reads a
  list's count before `zane_list_room`, which keeps it, so a filled list's
  count is known after the room is made.

Layout dominates many of these tests. HuffDecode's hot loop with
FRAME_SHADOW is two loads shorter and otherwise the same code, and runs
23% slower (1.45 s → 1.83 s); built with every loop aligned to 64 bytes
(`ZANE_LLVM_OPTIONS=-align-loops=64`), both builds run it in about 1.8 s
and the shadow is 2% faster, so 1.45 s was a lucky placement. Maze::BFS
(+7% twice) runs the same instruction count either way (1105M vs 1108M).
Aligning every loop is no fix: over all 50 tests it is 3.7% slower
(Jaro ×1.95). The CPU is an Emerald Rapids Xeon (model 207), so this is
not the JCC erratum.

With all three switches on, `ab.py` against the step-9 build over all 50
tests gives a geomean of 1.008, gains and placement swings cancelling
(HuffDecode +25%, LogParser +19%, Template::Parse +15% against
CacheSimulation −15%, GameOfLife −13%, CSV −9%); a `measure.py` run right
after gives Zane / C **0.879** (step 9: 0.917), but C's own times moved by
up to 5% between those runs, so the two are not comparable to that
precision.

## Step 14: the Json gap, by wall time

Json::ParseMapping, taken apart by running variants and timing them; no
Callgrind. `bench1.py ROUNDS TEST BIN...` interleaves binaries on one test,
pinned to one CPU, and gives each one's median; every number here is a
median of 10–20 rounds. C is `make prod` (gcc 13 `-O2`). Both sides
parse the same yyjson source (0.13.0, the C build's clone and the port's
`vendor/yyjson.c` are byte-identical) and link glibc's `malloc`. Minor
faults (6138 vs 6741) and system time (0.012 s each) are equal, so the
gap is user code.

**Where the time goes (v0.36, port at `zane-perf`).** A parse-only build
of each side (C: the coordinate loop skipped; Zane: `i!to(Int(0))`, the
checksum then fails but the time is kept):

| part, 100 iterations | C | Zane | gap |
| --- | ---: | ---: | ---: |
| parse (Zane's text copy included) | 0.191 s | 0.203 s | +0.012 s |
| reading the coordinates | 0.040 s | 0.082 s | +0.042 s |
| whole test | 0.231 s | 0.285 s | +0.054 s |

Reading the coordinates is three quarters of the gap. In the assembly,
C's coordinate loop (`JsonParseMapping_run`) makes no calls at all: gcc
inlines `yyjson_obj_get(coord, "x")` with the key a literal, so its
`strlen` is the constant 1 and its compare is one byte. The port's
`arena_json_get` (`lib/arena/ecosystem.c`) picks the key as
`keys[axis]`, so the inlined `yyjson_obj_get` calls `strlen@plt` once and
`bcmp@plt` for each key it passes: 3 `strlen` and 6 `bcmp` calls per point,
behind 3 calls to `arena_json_get` that LLVM does not inline into
`jsonbench$step` (the C is linked into the module before the pipeline,
`-O2 -Xclang -disable-llvm-passes`, so the inliner saw it and declined).
`arena_json_parse` also walks the array once to fill an array of element
pointers, which the reads then walk again; C walks the parsed document
(about 6 MB, more than L2) once, inside its `yyjson_arr_foreach`.

`json/harness.c` repeats C's loop body outside the arena, with variants
for each of those shapes. The copy of the 2.3 MB text into a fresh buffer
costs 0.25–0.4 ms of a 2.1 ms iteration there, and yyjson built by clang
18 `-O2` parses as fast as by gcc. The harness overstates the port's
second walk and its list (glibc's `realloc` of a growing list faults pages
each iteration; Zane reuses the list's span), so the split above is from
the real binaries.

**Port change: the binding reads as C does.** `arena_json_get` now keeps a
cursor: the next index is one step on (`unsafe_yyjson_get_next`), any
other is found from the start, and the pointer array is gone. Each key is
a literal (`axis == 0 ? yyjson_obj_get(v, "x") : …`), as in C. The cursor
alone on v0.36: ParseMapping −5%, ParseDom −6%.

**Results** with compiler `perf/zane-vs-c` 897de93 (`build.sh`), port at
this step; Zane / C, medians of 15 rounds:

| build | ParseMapping | ParseDom |
| --- | ---: | ---: |
| switches off | 1.24 | 1.18 |
| switches off, binding | 1.05 | 1.02 |
| step-9 set | 1.23 | 1.21 |
| step-9 set, binding | 1.05 | 1.03 |
| step-9 set + `ZANE_LENT_OWNERS=1` | 1.15 | 1.15 |
| step-9 set + `ZANE_LENT_OWNERS=1`, binding | **1.00** | **0.96** |

So the binding is worth about 15%, `LENT_OWNERS` (no text copy) about 5%,
and with both the Json tests run as fast as C. All three Json checksums
pass.

**Step 12's +15% ParseMapping regression does not reproduce.** Pinned and
interleaved, the same port built by v0.36 (0.286 s), by the branch with
its switches off (0.280 s) and with the step-9 set (0.284 s) are within
noise of each other; the step-9 set with `LENT_OWNERS` is faster (0.271
s). Step 12's runs were unpinned, on all four CPUs.

**Whole-suite check of the branch (wall time).** `ab.py`, 4 rounds,
unpinned:

- `zane-perf` port, v0.36 against the branch with every switch off
  (`step14-ab-v036-vs-branch-off.md`): geomean 1.027. Two branch changes
  apply with the switches off: f577873's `moved_here` condition in the
  default assign-moves pass, and the U8 runtime function, which makes
  `build.sh` bundle the runtime itself.
- This step's port, switches off against the step-9 set with
  `LENT_OWNERS` (`step14-ab-off-vs-switches.md`): geomean 1.007.

The tests that came out slowest (Graph::AStar +28%/+32%, Maze::AStar
+24%, Calculator::Interpreter +26%/+19%), run again with `bench1.py`, 8
rounds pinned, over all five builds: every median is within 7% of
v0.36's, and every build's range overlaps the others'. Graph::AStar's
switches-off build was 0.988 s in one A/B and 0.733 s in the other. No
regression stood out from the noise, so nothing on the branch was
reverted. Template::Regex, GameOfLife and Words keep step 12's two levels.

**All 50 tests against C** (`measure.py --rounds 5`, best of 5,
`step14.md`, `step14.json`), the step-9 set with `LENT_OWNERS` and this
step's port: **geomean 0.880**. At 1.10× C or slower: Brainfuck::Array
1.46, Brainfuck::Recursion 1.44, BWTEncode 1.29, Graph::DFS 1.27,
NeuralNet 1.25, HuffDecode 1.25, Matmul::T16/T4/T8 1.19/1.17/1.17,
CacheSimulation 1.18, Sort::Merge 1.16, Etc::TextRaytracer 1.12,
Sort::Quick 1.12, Matmul::Single 1.10.

## What remains

- Base64 is a C library call in both languages; CRC32 and SHA256 (0.97,
  0.86) and Arith (1.00, 1.08) were left on `Buffer`.
- Brainfuck needs the tape's fields in registers across the interpreter
  loop; `ZANE_FRAME_SHADOW` (step 13) covers frame slots, not the tape
  reached through `this`.
- Placement: a 25% swing on HuffDecode from code layout alone makes small
  gains unmeasurable one test at a time.
- Brainfuck::Recursion re-reads `ops`'s count and checks `ops[i]` on every
  step; `ListRef` is a reference type, so hoisting needs proof that nothing
  in the loop can reach it mutably.
- Json is at C's speed with `ZANE_LENT_OWNERS` and step 14's binding.
  `arena_json_get` is still a call per coordinate that LLVM declines to
  inline, and `step` reloads the handle from the frame before each call
  and stores the list's count after each push; none of it shows in the
  times now.

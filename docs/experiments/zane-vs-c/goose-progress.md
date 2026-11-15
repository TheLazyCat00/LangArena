# Closing the Goose gap: progress

Working state for the overnight run (user's request 2026-11-14: bring every
Zane / Goose gap down, worst first, all in one session). Kept current and
committed as each step lands, so it survives a context compaction.

## Setup

- Compiler: `/home/user/compiler`, branch `perf/zane-vs-goose` (pushed).
  zane-lang/compiler#377 (perf/zane-vs-c) is in the merge queue; its fixes are
  cherry-picked here.
- Port build: `env $SW sh docs/experiments/zane-vs-c/build.sh OUT` with
  `SW="ZANE_LOOP_REGS=1 ZANE_ASSIGN_MOVES=1 ZANE_VERSION_CALLS=1 ZANE_LENT_OWNERS=1 ZANE_FRAME_SHADOW=1 ZANE_MERGE_CHECKS=1 ZANE_ENDLESS=1 ZANE_SIZED_TBAA=1 ZANE_FRAME_SCOPES=1"`.
- Checks: `ZANE_CHECK=1 BIN ../test.js` from `zane/` (all 50), then
  `just test-compiler` in the compiler.
- Timing: `tri.py ROUNDS NAME=BIN…` (pinned to CPU 2, interleaved). Goose
  binaries: scratchpad `gb/goose_gcc`, `gb/goose_clang` (rebuild: `goose/`
  Makefile `prod`, Goose v2026.4).
- Profile: `prof/sampler.so` (LD_PRELOAD), `prof/symbolize.py`.
- Rule (memory `zane-perf-fix-in-compiler`): fix the compiler or library, not
  the port; the port may take Goose's structure where that is the design,
  not a dodge.

## Baseline (step 19, `step19-goose.json`)

Zane / Goose-clang 1.31 geomean. Worst: LZWDecode 6.2, Sort::Self 5.8,
CSV::Parse 4.0, Calculator::Ast 3.9, LZWEncode 3.2, LogParser 2.4, SHA256 2.4,
HuffDecode 2.3, BWTEncode 2.0, NGram 1.9, Binarytrees::Arena 1.8,
Maze::Generator 1.8, Words 1.7, Interpreter 1.6, Sort::Merge 1.5.

## Log

- Compiler branch also has `core` changes: `/home/user/core` branch
  `perf/zane-vs-goose` (pushed; add_repo zane-lang/core with push access).

### LZWDecode: 0.87 → 0.37 s (Goose/clang 0.14; 6.2× → 2.6×)

- Goose: every entry's bytes in one byte array, an entry a slice into it;
  no allocation per entry, appends are memcpy; the result is a byte list.
- Port now has that layout (`List<U8>` strings + starts/lengths) and gives
  back a `List<U8>` (a String only for the final checksum compare).
- A byte loop was 1.5 s (bounds + room check + count store per byte), so:
  compiler 4d88987 + core cc30133: `List.appendRange(from, start, count)`
  and `appendOwn(start, count)`, one `zane_list_append` copy, elements
  that own no blocks only (fixtures `listAppend`, `reject/appendOwners`).
- Left: ~3.2 MB/iteration of list growth copies under 1 MiB (doublings).
  Tried making a list past 256 KiB an oversized growable block at once:
  0.58 s, worse (a mapping per iteration); reverted.


### Sort::Self: 1.98 → 0.33 s (Goose/clang 0.34; 5.8× → 1.0×)

- Port sorted with C's `qsort` (comparator through a pointer) via the arena
  FFI; Goose's std `sort` is a pdqsort with a branchless Lomuto partition.
- Compiler + core: `List.sort()` for I32/I64/U8, runtime `zane_list_sort`,
  the same algorithm written out per width (fixtures `listSort`,
  `reject/sortFloats`). Port: copy the data, `sort()`, as Goose's port.

### CSV::Parse: 1.89 → 0.72 s (Goose/clang 0.47; 4.0× → 1.5×)

- Port parsed through the arena FFI's C reader with glibc `strtod` (52%
  of the time). Goose reads with its std `csv::each_record` and its own
  `parse_flt` over slices. Port now has that structure: one Zane pass over
  the bytes, each float field parsed where it lies.
- Compiler 1a23e7c + core 912d211: `zane_parse_f64` checks and folds
  the digits in one pass, with Clinger's fast path (≤19 digits, ≤2^53,
  ≤22 after the point: one exact division) before `strtod`;
  `String.parseFloat(start, count)` reads a range with no copy (fixture
  `parseRange`).
- Left: the scan is ~2 cycles/byte against Goose's ~1. Goose's reader
  runs a tight inner loop per field kind (`while` with 3 compares); Zane
  has only counted loops (`to`/`repeat`), no `while`/`break`, so the
  port toggles a quote flag per byte. A conditional loop is a language
  decision → question for the user.

### Calculator::Ast: 0.41 → 0.19 s (Goose/clang 0.11); Interpreter 0.48 → 0.425 (Goose 0.445)

- Goose's AST names are slices of the input (`p.input[start..pos]`), and
  its interpreter's dictionary is keyed by `const u8[:]`. Port had a
  String per name (`slice` → an allocation, a held block, a free, a
  Node move) and read bytes through the FFI `Buffer`.
- Port now: `Name { start; length }` in the nodes, the parser reads its
  String with `byteAt`, and the interpreter uses `SliceMap`
  (`arena/maps.zn`), StringMap's slots keyed by ranges of the one text.
- Left (Ast): `whitespace` is 35%, nearly all of it IRCE's safe-range
  setup for a loop that runs 0–1 times (`i!to(bound)` stands for a
  `while`). Without IRCE: 0.133 s.
- IRCE measured (`ZANE_NO_IRCE_BUILD=1`, and `ZANE_TRY_LLVM` for options;
  both experiment switches, out before any PR). Off: geomean 0.987, Ast
  0.70, BFS 0.84, but Matmul::T8 1.15, GameOfLife 1.17, BWTEncode 1.11.
  `-irce-min-eliminated-checks=40` (default 10): Ast 0.71 but Maze::AStar
  1.32, Template::Regex 1.28, Maze::BFS 1.24, geomean 1.021. No global
  setting wins; the default stays. A fix needs IRCE to skip a short
  search loop (an exit on loaded data) and keep counted ones.

### LZWEncode: 1.46 → 0.72 s (Goose/clang 0.51; 3.2× → 1.4×)

- Goose: every string a slice of one growing byte array (`new_string`,
  `concat` append there), its dictionary keyed by slices, hashed by
  lanes and compared by `memeq`. Port had String concatenation and a
  StringMap; now has that layout with `BytesMap` (`arena/maps.zn`) keyed
  by ranges of a `List<U8>`, sized for every code (≤65536).
- Byte-at-a-time hash and compare in Zane were 90%, so compiler 9b72f6d
  + core 0ca5428: `List.sameRange` (one memcmp) and `List.hashRange` (four
  lanes over 32-byte blocks, the tail read with fixed loads, no memcpy
  call); integers only (fixtures `listRanges`, `reject/rangeFloats`).
- Left: the hash (one per lookup, three per miss, as Goose) and cache
  misses on the slot and the stored key, which Goose has too.

### LogParser (2.4×): not attempted

- Port uses PCRE2 JIT through the arena FFI, as C's entry does (72% in
  JIT code). Goose has its own regex engine: literal-pair prefilters
  (`gs_find_pair`, `gs_scan_pair_tables`) and a DFA (`regex_find_end`).
  Closing it means a regex library for Zane: a library project, left.

### SHA256: 0.78 → 0.75 s (Goose/clang 0.33, gcc 0.57); open

- Port now as Goose's: `List<U8>` data, `Array<I32, 8>` hashes with
  wrapping 32-bit arithmetic (CRC32 shares the list).
- Goose/clang: unrolled by 8, `i % 8` folds to constants, the 8 hashes
  live in two xmm registers (SLP). Ours: unrolled by 4, hashes stay in a
  stack array, the index computed (`&0x1c`) and each lane a store→load.
  `-unroll-count=8` and `-unroll-runtime-epilog=true` (ZANE_TRY_LLVM) do
  not change it: the unrolled loop's start alignment is not known, so
  the index does not fold. Needs the IR read; left open.

### HuffDecode: 1.33 → 1.20–1.25 s (Goose/clang 0.58); open

- Port read the encoded bytes and pushed each decoded byte through the
  FFI `Buffer` (a foreign call per byte). Now as Goose's: `byteAt` on
  the String, a `List<U8>` out, given back as bytes (a String only for
  the final compare).
- Reading the node once before the left/right choice (so it can be a
  select) was slower, 1.34: the predicted branch beats the select on the
  load chain. Goose: branchless child offset from the bit, the 8-bit loop
  fully unrolled, a leaf flag byte, node pointers (no index scaling).
  Ours: `b!to(min(8, remaining))` is not unrolled, the leaf test reads two
  fields. Whole bytes in a constant `b!to(8)` loop (the last byte after)
  was slower too, 1.30. Left open.

### BWTEncode (2.0×): open

- Same rounds as Goose (prefix doubling to n). Goose sorts each round
  with its std `stable_sort`, an adaptive natural merge sort with a
  comparator over rank pairs: the suffix array is already in rank order
  from the round before, so its runs are long. Ours: two full counting
  sorts per round, as C. 32-bit counts: no change. Matching Goose needs a
  comparator (or key-pair) stable sort in core; left.

## Re-measure (step 20, `step20-goose.json`, before NGram)

Zane / Goose-clang 1.15 geomean (was 1.31), faster on 15; Zane /
Goose-gcc 0.94 (was 1.08), faster on 26. Worst vs clang now: LZWDecode
2.8, LogParser 2.5, SHA256 2.2, HuffDecode 2.1, BWTEncode 1.9, NGram 1.8,
Binarytrees::Arena 1.8, Ast 1.7, Words 1.7, CSV 1.6, Sort::Merge 1.6,
Maze::Generator 1.5, Template::Parse 1.5, LZWEncode 1.4.

### NGram: 0.57 → 0.244 s (Goose/clang 0.31; 1.8× → 0.8×)

- Port probed its IntMap 2 times per gram of the first string and 4 per
  gram of the second (get, put, has, get), each probe starting with a
  `rem` division, and read bytes through the arena FFI. Goose: one
  probe per gram (`update`), two for the second (`get_or_insert`, `get`).
- `IntMap` now has power-of-two slots from a Fibonacci hash and a
  one-probe `add` (as StringMap's); NGram as Goose's, with `byteAt`.

### Words: 0.88 → 0.54 s (Goose/clang 0.55; 1.7× → 1.0×)

- Goose's dictionary is keyed by word slices of the text; the port made a
  String per word (`slice` of an FFI Buffer). Now the text is a String
  and the words count in a `SliceMap` (new one-probe `add`).

### LZWEncode: 0.72 → 0.67 s; Template::Parse tried, reverted

- `BytesMap` keeps each entry in its slot (`ByteSlot`, three I32s): a
  lookup reads one slot rather than a slot, then the entry's start and
  length elsewhere. LZWEncode 0.72 → 0.67 (Goose 0.51).
- Template::Parse as Goose's (byte lists, the name a trimmed range looked
  up with `findIn`, values appended with `appendRange`): 1.10 s, no better
  than the String version (1.0–1.1; Goose 0.67). The time is the slot
  load missing cache in a 6 MB table (3×50000 keys); reverted. Copying
  `this.textBytes` into a local cost a whole-list copy per step (lists
  are values): read fields in place.

### Binarytrees::Arena (1.5–1.8×): open

- Same structure and node layout (three 32-bit values). Same page
  faults and system time; user time 0.73 vs 0.49 s, all in `build`
  (`sum` is even). Goose/clang's `build` handles depth 1 in place, both
  leaf children written with no call (half of all nodes), and pushes
  through a cursor; ours calls itself for every leaf. A codegen matter
  (recursion peeling); left.

### Sort::Merge (1.56×), Maze::Generator (1.35×): looked at, open

- Sort::Merge: Goose copies the range into temp with one `copy_into`
  and merges until a side runs out, then copies the left rest only.
  Goose/gcc is 1.63 s, near ours (1.77); clang's 1.13 likely comes from a
  branchless pick. Ours: nested branches whose arms read different
  checked indices. Would want a range-copy intrinsic and if-conversion
  across checked reads; left.
- Maze::Generator: same structure (neighbours as 32-bit indices, Goose's
  as compressed 32-bit references); `adjacentOpen` compiles to a tight
  unrolled count. Bound by the scattered cell loads; left.

## Re-measure (step 21, `step21-goose.json`)

Zane / Goose-clang 1.14 geomean (step 19: 1.31), faster on 17; Zane /
Goose-gcc 0.91 (1.08), faster on 28. Worst vs clang: LZWDecode 2.8,
LogParser 2.5, SHA256 2.3, HuffDecode 2.1, BWTEncode 1.9,
Binarytrees::Arena 1.8, Template::Parse 1.8, CSV 1.7, Ast 1.6,
GameOfLife 1.55, Sort::Merge 1.5. Single-test runs are noisy at ±10%.

## Decisions from the user (2026-11-15)

- No unbounded `while`: bounded loops are what lets Zane evaluate
  aggressively at compile time, and `guard` already breaks out of a
  loop. The port's `i!to(bound)` loops with an early exit are the
  intended shape; a loop's exit belongs in `guard`, not a new construct.
- No regex library or comparator sort in core yet (LogParser, BWTEncode
  stay as they are).
- The compiler work goes to a PR.

## Compiler PR

Opened zane-lang/compiler#378 (branch `perf/list-ranges-float-reads`) on 2026-11-15 with the compiler side of this work.

# Second run (2026-11-15, branch `experiment/zane-vs-goose`)

The user lifted two limits for this run: a regex library (LogParser) and a
comparator/key sort in core (BWTEncode) are allowed. Goal: Zane about as
fast as Goose, or faster, on every test.

## Setup

- Compiler: `/home/user/compiler`, branch `experiment/zane-vs-goose` off
  v0.37 (f67247f, which has compiler#378). Core: `/home/user/core`, the same
  branch name, off v0.11 (bfdcb3c). LangArena: branch
  `experiment/zane-vs-goose` off `zane`.
- Toolchain: release v0.37 (`build.sh` now copies v0.37 to `dev`), compiler
  built with `pixi run just build`; the same `SW` switches as before.
- Goose: `aardappel/goose` at 369c7a2 (the arena's pin), built with cmake as
  `docker/goose_clang`; benchmark `goose -O2 --standalone`, then clang 18.1.3
  / gcc 13.3 `-O2` (Ubuntu 24.04 compilers, a different machine from the
  first run).
- Report: `rep.py STEP.json` prints the table, worst ratio first.

## Baseline (step 22, `step22-goose.json`, `step22-goose.md`)

Zane (v0.37 + switches) / Goose-clang 1.106 geomean, faster on 16; Zane /
Goose-gcc 0.950, faster on 23. Worst vs clang: LZWDecode 3.1, LogParser 3.0,
HuffDecode 2.2, SHA256 1.8, BWTEncode 1.8, CSV 1.7, Template::Parse 1.6,
Binarytrees::Arena 1.5, Sort::Merge 1.4, Template::Regex 1.4, GameOfLife
1.35, NeuralNet 1.3, LZWEncode 1.3, ArithEncode 1.3, Binarytrees::Obj 1.3,
Ast 1.3.

Note on building: `zanec` embeds the runtime's C when it is built, so a
runtime change needs `pixi run just build` before `build.sh`; and `zane
build` keeps its own cache in `zane/out`, which does not see a new compiler
or runtime, so `build.sh` now empties `out/` whenever either changed. The
port's `zane.coda` points at the local core (`core v0.11 /home/user/core`).
New switch this run: `ZANE_ARM_CHECKS=1` (below); `SW` plus it is the build.

### BWTEncode: 0.84 → 0.39–0.48 s (Goose/clang 0.47)

- Goose sorts the suffix array each round with std `stable_sort`, a
  natural merge sort with a comparator over (rank, next rank) pairs. Ours
  ran two counting sorts per round, as C.
- Compiler + core: `List<I32>.sortBy(keys List<Int>)`: the indices sorted
  stably by the 64-bit key each names (runtime `zane_list_sort_by`), a
  natural merge sort as Goose's: runs found first (descending ones
  reversed, short ones made 16 by insertion), merges that copy a pair of
  runs already in order, a branchless pick while the merges alternate
  sides often and a branch otherwise. Port: one key per suffix,
  `rank*2^32 + next rank`, one `sortBy` per round, new ranks from equal
  keys.
- Of 17 rounds only 3 merge anything (runs 2842, 2276, 1139 of 100000);
  the other 14 find one run. A first version sorted (key, value) pairs,
  16 bytes moved per element per pass: 0.73–0.78 s. Indices with the key
  looked up (Goose's layout): the same, as the branchless merge waits on
  two dependent loads per pick; with Goose's switch to a branch when the
  merge alternates rarely: 0.39–0.48.

### Sort::Merge: 1.96 → 1.50 s (Goose/clang 1.35)

- Port as Goose's: the range copied to temp in one copy (new
  `List.copyRange(at, from, start, count)`, runtime `zane_list_copy`, a
  memmove), merged while both halves have elements, the left half's rest
  copied back. A `guard` in a `to` body ends that iteration only, so the
  loop runs on, doing nothing, to its count; the merge is a function of
  its own whose loop `return`s.
- That alone: 2.0–2.2 s. The pick stayed a branch: each arm checks `k`
  against `work`'s count before its store, so LLVM cannot sink the two
  stores into one store of a select.
- Compiler `Arm_checks` (`ZANE_ARM_CHECKS=1`, post-pipeline, as
  `Merged_checks`): where both arms of a branch only check the same index
  against the same bound, the check goes above the branch; then, in a
  diamond whose arms each store to the same address with only arithmetic
  after, the stores move to the arms' ends, so SimplifyCFG sinks them into
  one store and the arms become selects. Also fires in huffman decode,
  distance and yyjson. 1.50 s.

### SHA256: 0.90 → 0.45 s (Goose/clang 0.40)

- Goose's compiler strip-mines `for byte, i in data` indexed `i % 8` into
  runs of 8 whose index is the run's own counter ("loop shape:
  strip-mined by 8" in its C), so clang keeps the eight hashes in vector
  registers (SLP). Ours: LLVM unrolls by 4 from wherever IRCE's split left
  the loop, the index is never constant, the hashes stay in memory.
- Compiler `Strip` (CGT, `lib/optimize/strip.ml`, `ZANE_STRIP=1`): a
  counted loop whose body ends `x = x + 1`, indexes an array of 2–16
  (power of two) elements, uses `bitAnd`, and has no call, loop or scope,
  becomes `repeat c/N { x = start + b*N; N copies of the body }` and a
  remainder loop; each copy's locals and labels are renamed. With `start`
  known, each copy's `bitAnd(x-1+k, N-1)` folds and SROA puts the eight
  hashes in registers: 0.90 s, unchanged, as the copies' bounds checks of
  `data[x+k]` cut the block in eight and nothing vectorizes.
- The loop passes turn those checks into exit tests `b == (n+k) >> 3`
  against a loop that leaves at `b+1 == n >> 3`, which can never hold;
  LLVM does not see it. Compiler `Range_checks` (`ZANE_RANGE_CHECKS=1`,
  post-pipeline): such a test of a counter that starts at 0, steps by one
  and leaves at `(n+j) >> s`, against `(n+k) >> s` with k >= j, made false;
  also, a straight run of checks of `x+k` against one bound made one check
  of the lowest and highest offsets. Then `slp-vectorizer` again: 0.45 s.

### LZWDecode: 0.50 → 0.21–0.24 s (Goose/clang 0.18–0.21)

- The timed part is all user time, about 76% of it in libc's memcpy. A
  memcpy/memmove interposer (per call site, bytes and calls) shows that
  each decode copies about 5.2 MB, against Goose's 1.3 MB:
  - the appends (`appendOwn`, `appendRange`): 2 × 1 MB, the same as
    Goose's;
  - `zane_list_grow`: about 2.2 MB in 52 calls, as `strings`, `starts`,
    `lengths` and `out`, interleaved in one region, double through heap
    blocks to 1 MiB. Goose grows through `realloc`, which for blocks past
    128 KiB moves pages (mremap), not bytes;
  - one 1 MB copy per step, in the list type's move walk (ICF-folded into
    `brainfuck$Tape.move`): `this.decoded = decode(...)` moves the result
    from the call's region into `State`'s, by allocating there, copying
    and freeing the old block.
- Compiler `ZANE_REHOME=1` (`walks.ml`, runtime `zane_relocate`): a moved
  list's or string's block that is a growable span in the same context is
  handed over: its mapping leaves the old region's list for the new one's
  and its chunks are re-entered in the chunk map, with no byte copied.
  Alone, that was 0.51 → 1.3 s: the old `decoded`, freed on the next
  overwrite, went to `State`'s region stack, so every decode mapped fresh
  pages (478k minor faults). A handed-over span is flagged, and
  `zane_free` gives a flagged span to its context's kept spans instead,
  where the next list past 1 MiB takes it resident: 0.35 s.
- Compiler `ZANE_LIST_SPANS=N` (runtime `zane_list_span_from`, a weak
  global that zanec defines): a list whose block grows past N bytes has its
  room doubled past 1 MiB at once and takes a growable span, from where it
  grows in place. The runtime's rule that a list block past
  `ZANE_CHUNK - ZANE_LINE` is the one block of its span still holds, so
  nothing else changes; a list from 128 KiB to 1 MiB uses more address
  space, but only its touched pages use RAM. With N = 131072: 0.21–0.24 s.

## Re-measure (step 23, `step23-goose.json`, `step23-goose.md`)

All switches so far, `ZANE_REHOME=1` and `ZANE_LIST_SPANS=131072` included,
against the step-22 binary (`old` in the JSON) and Goose, three interleaved
rounds, minimum of each:

- Zane / Goose-clang geomean 1.087 (faster on 12), Zane / Goose-gcc 0.940
  (faster on 23); the step-22 binary in the same run: 1.107 and 0.958.
- Zane against the step-22 binary: geomean 0.98; LZWDecode 0.46. The
  largest slowdowns in the table (Words 1.15, TextRaytracer 1.13,
  Maze::BFS 1.12) do not reproduce in interleaved reruns, except
  TextRaytracer by about 3%.
- Worst left: LogParser 2.26, HuffDecode 2.12, CSV::Parse 1.74,
  Calculator::Ast 1.52, Template::Parse 1.48, NeuralNet 1.43,
  Spectralnorm 1.40, TextRaytracer 1.39, Binarytrees::Arena 1.38,
  Maze::Generator 1.34, Template::Regex 1.33, LZWDecode 1.30.

### LogParser: 0.57 → 0.46 s, a regex library in Zane (Goose/clang 0.25–0.27)

- The port used PCRE2's JIT through C. As the user allowed, it now has a
  regex library of its own written in Zane (`zane/lib/arena/rx.zn`, tests
  in `zane/test/rx`), on the model of Goose's `stdlib/regex.goose`:
  parsed to a syntax tree, compiled back to front to a Thompson NFA, and
  from it, by subset construction, a forward DFA with an unanchored
  `.*?` ahead of the pattern (leftmost-first: a thread's list stops at
  the first match) and a reverse DFA for where a match starts; byte
  classes; states renumbered dead, match states, then the start state, so
  one compare finds every state the loop must look at. Where the forward
  DFA is back in its start state, a skip: the prefix test (the two
  offsets whose byte sets are rarest by a rough frequency, as Goose's
  `choose_filter`) or the inner byte (a rare byte every match holds after
  a part that never consumes it, walked back from by the part's reverse
  DFA), chosen as Goose chooses.
- The scans are runtime intrinsics, Goose's `gs_scan_pair` and
  `gs_scan_any`: `String:findPair` and `String:findAny` (compiler
  `Text_find_pair`, `Text_find_any`, runtime/block.c), 16 positions at a
  time by SSSE3 shuffles over two 16-byte tables per set, exact for every
  set, a set's tables prepared once on the Zane side.
- Scalar skip loop: 1.21 s; with `findPair`: 0.67 s; with the inner byte
  as well: 0.46 s (PCRE2: 0.62 s).
- The patterns are the ones PCRE2 had; checksums are unchanged.
  (Note: `guard(c)` leaves when `c` holds.)

### Template::Regex, Template::Parse: Goose's data layout

- Template::Regex on the new library is slower than with PCRE2 (2.3–2.5
  against 2.0–2.2 s): PCRE2 finds `{{` by memchr, and our reverse DFA
  walks back from each `}}` to where a match can start. The pattern is
  now Goose's, `[{][{](.*?)[}][}]`, whose `.` stops the walk at a newline.
- Both spent about 40–50% in `StringMap.slot` and much of the rest in
  per-byte FFI calls to the C `Buffer`. As in Goose's port, the text is now
  a `List<U8>`, the keys ranges of one byte list in a `BytesMap`, the
  values ranges of another, and a key is looked up by the text's own bytes
  (no `slice`/`trim` string per placeholder); runs of plain text are
  copied with `appendRange`. Template::Parse 1.47 → 1.44 s (Goose 0.95–
  1.13): the time is now in `BytesMap.slotIn`, about 90 ns a lookup, a
  cache miss into a 6 MB table, as Goose's 10 MB one also has.
- `BytesMap.slotIn` tested `length == count and sameRange(...)`: Zane's
  `and` evaluates both sides, so every probed slot compared bytes. Now
  nested.
- `StringMap` hashes with the runtime's word-at-a-time hash (`hashBytes`,
  the one `hashRange` uses) instead of djb2 per byte.

### HuffDecode: looked at, left at about 2× (Goose/clang 0.69–0.81 s)

- The node is now Goose's (narrow fields and an `is_leaf` flag, 14 bytes
  packed); no change in time. Per bit our chain is `dec`, `shl`, `add` and
  the child's load (an index becomes an address); Goose's and C's are
  pointer chases, a load each. Padding the node to 16 bytes (a shift for
  the stride) did not change it either. A flat child table (`kids[2c+bit]`,
  leaf as a negative entry) would match a pointer chase, but it is neither
  Goose's nor C's design, so it is left out.

### CSV::Parse: 0.99–1.08 → 0.73–0.79 s (Goose/clang 0.53–0.56)

- The field loop is Goose's `csv::each_record` shape (a quoted field ends
  at its closing quote, any other at the first separator, line break or
  quote), each end found by `findAny` rather than a test of every byte.
- `zane_parse_f64` (0.68 s of samples to Goose's `parse_flt` 0.45) is the
  same algorithm as Goose's (digits folded, one division by an exact power
  of ten); its code is as tight; left.

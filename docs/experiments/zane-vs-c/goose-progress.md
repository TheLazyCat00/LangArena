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

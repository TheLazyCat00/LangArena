# Zane vs C: performance issues

As of 2026-11-12, measured against `zane-perf` at 354c5f2 with compiler v0.32
and core v0.10. The same list is kept as a Claude Doc, which also has a chart
of all 50 ratios: https://claude.ai/artifact/RJcMtraHukcaWwMF9kPPPx

## Summary

Zane runs at a geomean of 1.17× C across the 50 tests, down from 1.42× at the
start of `zane-perf`. 22 tests are still at 1.2× or slower. The extra work a
fair port could remove has been removed. What is left comes from six
compiler/runtime mechanisms (R1–R6) and three core gaps (B1–B3), listed below
with repros in [`repros/`](repros).

Eight of the worst ten tests come down to string copies (R1) or list fills
(R2/B1). The other two are the Brainfuck tests (R5).

## Port fixes on zane-perf (class a)

Thirteen commits, newest first, make the port do the same work as C; each kept
all 50 checksums OK. Times are `run.js` wall-clock on the measuring machine.

| Commit | Test | Port did extra work | Before → after | C |
| --- | --- | --- | --- | --- |
| 354c5f2 | Hash::SHA256 | eight running hashes in a heap List; C uses `uint32_t[8]` on the stack. Now `Array<Int, 8>`: unrolled, no bounds checks | 2.190 → 1.1 s | 1.585 s |
| d92d929 | Compress::HuffEncode | a non-inlined `BitWriter.bit` call per bit, state in fields; C keeps it in locals | 1.616 → 1.03 s | 1.295 s |
| ea1c1dd, c9aa3f7 | Maze::Generator / BFS / AStar | each cell's neighbours in a List of its own, one extra dependent load per visit; C has `neighbors[4]` inline. Now `Array<I32, 4>` in the cell | 1.277 → 0.66 s / 1.373 → 0.81 s / 3.526 → 2.6 s | 0.865 / 0.566 / 1.250 s |
| 59a9a86 | Etc::Words | three map probes per word (`has`, `get`, `put`) and a second order list; C finds once. `StringMap.add` probes once (slot instructions 685M → 202M) | 3.768 → 2.6 s | 2.714 s |
| 916a910 | Binarytrees::Arena | replaced a state-held node list each iteration (see R4): 890 MB RSS | 0.947 → 0.6 s | 0.490 s |
| 870e387 | Compress::HuffDecode | reloaded and re-indexed the byte for every bit | 2.820 → 1.8 s | 1.229 s |
| 48970e4 | Compress::LZWDecode | copied the previous entry's string twice per code | 2.968 → 2.2 s | 1.325 s |
| b43ae0e | Template::Regex / Parse | StringMap took its slot from raw djb2: 18.6 probes per lookup → 1.4 | 3.835 → 3.650 s / 2.854 → 2.637 s | 1.832 / 1.503 s |
| 0dff959 | Template::Regex / Parse | whole-text copies per step; trim scanned every byte; lookup returned a copy | 4.784 → 3.835 s / 3.542 → 2.854 s | 1.832 / 1.503 s |
| bae526e | Brainfuck::Array | re-ran the bracket after a jump; brackets went through the command dispatch | 4.404 → 2.594 s | 1.513 s |
| da36659 | Maze::BFS / AStar | filled an n-entry `previous` list per search; reconstruction walked all n cells | 1.968 → 1.151 s / 3.071 → 3.000 s | 0.566 / 1.250 s |
| bcc20fe | Base64::Encode / Decode | own scalar codec + a validation pass; C links aklomp/base64 (AVX2) | 2.416 → 0.444 s / 5.619 → 0.366 s | 0.146 / 0.159 s |

Tried and reverted: a Brainfuck `command` rewritten as an elif chain (5% slower
on Recursion despite fewer instructions), a `frequencies(Buffer)` overload for
BWTDecode (no change), quicksort scans with the index as the loop variable (1%
fewer instructions, see R6), and a local copy of the Huffman node list in
decode (no change, see R5).

## Compiler and runtime issues (class c)

None of these is LLVM generating poor code; each is work the compiler or
runtime asks for. Repros build with `zane build` in their directory.

### R1. Fresh strings are copied twice: constructor copy + return promote

- **Mechanism.** Core's `String(@primitives$String)` copies its argument even
  when it is a fresh foreign string nobody else holds. Returning that `String`
  from a function then promotes it into the caller's region with a second full
  copy.
- **Measured.** 100 rounds of a 1 MB foreign string: 300.6M instructions, about
  3 per byte (C's `memset` alone is the expected cost). Calling the raw foreign
  function directly removes both copies; constructing without returning removes
  only the promote.
- **Hits.** Base64 (both), CacheSimulation (14.6 allocations, 5 copies and 4
  promotes per access vs C's 2 `snprintf` + 2 `strdup`), LZWEncode (one
  `character()` + concat per input byte), LZWDecode (one concat per entry),
  Template (about 12 allocations, 5 copies, 3 promotes per placeholder).
- **Fix direction.** Move, don't copy, a value whose source is a fresh
  temporary: a constructor argument that is a call result, and a returned local.
- **Repro.** [`repros/string-copy`](repros/string-copy): `out/host/repro 1000000 100`.
- **Fixed** in [zane-lang/compiler#364](https://github.com/zane-lang/compiler/pull/364)
  (`2ccc514`), in the compiler only. A fresh argument now moves into a value
  parameter that the callee copies once, through a local `<symbol>.taken` copy
  when the callee is another package's. A returned local is moved out of its
  slot. With nothing held, the result is made in its final region, so the
  promote goes too. Callgrind instructions and minor page faults, compiler
  v0.32 → #364, with all 50 checksums OK:

  | Program | Instructions before | after | Faults before | after |
  | --- | ---: | ---: | ---: | ---: |
  | `repros/string-copy 1000000 100` | 300.6M | 100.5M (the `memset` alone) | 1,033 | 546 |
  | Base64::Encode | 9.65G | 1.65G | 1,584 | 1,308 |
  | Base64::Decode | 6.74G | 1.93G | 1,511 | 1,392 |
  | Etc::CacheSimulation | 31.6G | 17.3G | 602 | 588 |
  | Compress::LZWEncode | 49.8G | 26.8G | 161,614 | 1,532 |
  | Compress::LZWDecode | 34.7G | 16.4G | 14,911 | 6,493 |
  | Template::Regex | 33.5G | 18.6G | 113,579 | 21,247 |
  | Template::Parse | 27.7G | 18.2G | 19,961 | 14,239 |

### R2. A push loop costs 13.4 instructions per element

- **Mechanism.** The list's count and data pointer live in memory and are
  reloaded, checked against capacity, and stored back on every push. The
  compiler's `Loop_pushes` pass (reserve room before a loop of pushes) never
  fired in any loop shape tried, including a raw `@controlflow$repeat`.
- **Measured.** 10 × 1M I32 pushes: 134.6M instructions with either loop form.
  C's equivalent store loop is about 2 per element.
- **Hits.** Every `arena$filled` call: Graph::AStar (72% of a step),
  Maze::AStar (62%), Maze::BFS, BWTEncode (about 50%), BWTDecode.
- **Fix direction.** Make `Loop_pushes` fire for a counted loop, and keep count
  and data in registers inside the loop (see R5).
- **Repro.** [`repros/list-fill`](repros/list-fill): `out/host/repro 1000000 1`
  (or `2` for the raw `repeat` form), under `valgrind --tool=callgrind`.
- **Fixed** in [zane-lang/compiler#366](https://github.com/zane-lang/compiler/pull/366)
  (`b7d1da3`). `Loop_shapes.leaving` counted every `leave` in a loop body as
  a way out, and the `leave` that ends each written-out push (and the `to`
  counter step) kept it from ever making room. All three such checks now
  share `Cgt.Traverse.leaves`, which counts only a `leave` of an expansion
  outside the loop. With room made, LLVM turns the fill into an SSE store
  loop, about 0.6 instructions per element, so no alias metadata (R5) is
  needed for it. The PR also stops the program, out of memory, on a count
  whose bytes would wrap. Before, it took a block too small for room the
  pushes no longer check. Callgrind instructions and minor page faults,
  compiler `main` after #364 (21bb3a9) → #366, port unchanged, all 50
  checksums OK:

  | Program | Instructions before | after | Faults before | after |
  | --- | ---: | ---: | ---: | ---: |
  | `repros/list-fill 1000000 1` / `2` | 115.7M (134.6M on v0.32) | 6.66M | | |
  | Graph::AStar | 22.79G | 8.61G | 21,192 | 21,011 |
  | Maze::AStar | 10.53G | 5.75G | 176,844 | 184,612 |
  | Maze::BFS | 5.09G | 3.47G | 53,043 | 53,149 |
  | Compress::BWTEncode | 14.19G | 10.79G | 1,415 | 1,096 |
  | Compress::BWTDecode | 21.39G | 18.95G | 84,753 | 84,189 |
  | Graph::BFS | 13.11G | 12.88G | 21,279 | 21,282 |
  | Graph::DFS | 7.87G | 7.78G | 20,166 | 20,165 |
  | Compress::HuffDecode | 29.38G | 29.38G | 2,184 | 2,186 |

  Graph::BFS / DFS and HuffDecode push only inside an `if`, which
  `Loop_pushes` does not cover. What is left there is R5. Their faults are
  R3.

### R3. A returned big list is copied, remapped, and unmapped every call

- **Mechanism.** Returning a list costs a `List.copy` plus a `List.move` into
  the caller. Past a chunk, the copy lands in a fresh mapping, and the callee's
  block is unmapped when its scope drains, so the next call faults every page
  in again.
- **Measured.** 40 rounds of a returned 4 MB list: 41,267 minor faults (about
  1,000 per round), 0.06 s system time. The C equivalent with
  `malloc`/`realloc`/`free`: 3,976 faults in total, 0.00 s system.
- **Hits.** BWTEncode / BWTDecode (system time 0.36 / 0.79 s vs C 0.04 s),
  Maze::BFS / AStar, Graph::AStar.
- **Fix direction.** Hand the callee's list over on return (same rule as R1),
  and keep big blocks mapped for reuse when a region drains.
- **Repro.** [`repros/list-return`](repros/list-return): `out/host/repro 1000000 40`;
  `c-equivalent.c` with the same arguments for comparison.
- **Fixed** in two steps. [zane-lang/compiler#364](https://github.com/zane-lang/compiler/pull/364)
  (`2ccc514`) moves a returned local out of its slot, which removed the copy
  and fixed the repro: 41,267 → 1,072 faults, below C's 3,976.
  [zane-lang/compiler#368](https://github.com/zane-lang/compiler/pull/368)
  (`97be120`, spec rule in [zane-lang/spec#277](https://github.com/zane-lang/spec/pull/277))
  covers the rest: a function whose scope drains three or more big lists per
  call. A context now keeps up to 16 drained list reservations mapped, holding
  at most 64 MiB, instead of 2, and the next list past 1 MiB grows into one.
  When the system refuses a new reservation, the kept ones are given back
  first. Minor page faults and system time, compiler `main` after #366
  (b7d1da3) → #368, port unchanged, all 50 checksums OK:

  | Program | Faults before | after | C | System time before | after |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `repros/list-return 1000000 40` | 1,072 | 1,075 | 3,975 | | |
  | Compress::BWTDecode | 84,188 | 9,930 | 18,835 | 0.19 s | 0.03 s |
  | Maze::BFS | 53,148 | 13,391 | 29,477 | | |
  | Maze::AStar | 184,612 | 18,003 | 512,098 | | |
  | Graph::AStar | 21,014 | 21,009 | | | |
  | Compress::BWTEncode | 1,095 | 1,093 | | | |
  | Binarytrees::Arena | 6,464 | 6,460 | | | |

  Graph::AStar, BWTEncode and Binarytrees::Arena already faulted only on
  first touch: what they fault is the memory they use. Callgrind
  instructions did not move.

### R4. A list replaced in a field is never reclaimed

- **Mechanism.** Assigning a fresh list to a `#struct` field of a value that
  outlives the loop never frees the list it replaced; it stays mapped until the
  owner dies.
- **Measured.** A field replaced by a 24 MB list each round: peak RSS 237 MB
  after 10 rounds, 941 MB after 40, with 234,770 faults. It should stay near
  24 MB.
- **Hits.** Binarytrees::Arena before 916a910 (worked around by making the
  arena local, which is also what C does). Any port that keeps a growing list
  in state.
- **Fix direction.** Free the old value on field assignment when the field held
  the only reference.
- **Repro.** [`repros/field-replace`](repros/field-replace): `out/host/repro 3000000 40`.
- **Fixed** in [zane-lang/compiler#368](https://github.com/zane-lang/compiler/pull/368)
  (`97be120`). The overwrite already freed the old list, but onto its
  region's stack of blocks of that size, and a list growing past 1 MiB
  always reserved fresh addresses instead of reading those stacks. Growth
  past 1 MiB now takes a returned span whose reservation holds as many
  addresses as a fresh one would: one of its own size first, otherwise the
  smallest that fits. `tests/memory-probes/reclaim.py` holds the field case
  to one peak RSS at 4 and at 40 rounds. Compiler `main` after #366
  (b7d1da3) → #368:

  | Program | Peak RSS before | after | Faults before | after |
  | --- | ---: | ---: | ---: | ---: |
  | `repros/field-replace 3000000 40` | 919 MB | 26 MB | 234,762 | 6,214 |

  Binarytrees::Arena keeps its local-arena port (916a910), which is also
  what C does.

### R5. Loops reload list counts and check bounds twice

- **Mechanism.** Each store through a list might alias the list header, so LLVM
  reloads the count and data pointer after every store. An index is checked
  once by the indexing intrinsic and once more by the caller's code.
  Brainfuck's `command` is not inlined (635M calls), because the Buffer push
  slow path inlined into it makes it too big.
- **Measured.** Brainfuck::Array 35.4G instructions vs C 13.3G;
  Brainfuck::Recursion 38.9G vs 18.6G.
- **Hits.** Brainfuck (both). HuffDecode: about 20 instructions per bit, with
  `tree.nodes`' pointer and count reloaded after every output push; a local
  copy of the list did not change the count. ArithEncode/Decode:
  `BitWriter.bit` is not inlined either. NeuralNet, Graph::BFS / DFS: index
  reloads plus a bounds check per access. SHA256 had the same problem until its
  hashes moved into an `Array` (354c5f2).
- **Fix direction.** Emit TBAA or `noalias` metadata so a list's header and its
  elements are known not to alias; mark push slow paths `cold`/`noinline` so
  callers stay small.

### R6. A short counted loop with an early exit pays a range-check prologue on every entry

- **Mechanism.** A scan written as `i!to(high) { if(work[i]>=pivot) { return i; } }`
  is a counted loop with a bounds-checked index. LLVM computes a sub-range where
  the checks can be dropped, using about 25 instructions of `cmov` saturation
  arithmetic, every time the loop is entered. C's
  `while (arr[i] < pivot) i++;` has no trip count and no checks.
- **Measured.** Sort::Quick step: 964M instructions vs C's 495M. Per partition
  round (9.95M rounds), about 50 instructions are setup for the two scans,
  which average about 1.5 elements each.
- **Hits.** Sort::Quick; any scan loop that usually stops after a few elements.
- **Fix direction.** A condition-tested loop (B3), or skip loop versioning when
  the trip count is unknown and likely small.

### Open question: Json is slower at equal instruction counts

Json::ParseDom / ParseMapping run 183M vs 186M step instructions, Zane vs C,
yet take 1.3–1.5× as long (0.157 s vs 0.106 s), with no extra page faults.
Both spend most of the time in yyjson. One difference is the compiler: C
builds yyjson with gcc -O2, while Zane compiles it with clang into the same
LLVM module. Not investigated further, since the absolute gap is 50 ms.

## Core issues (class b)

### B1. No bulk fill or uninitialised list constructor

- **Mechanism.** Core has no `List(n, value)` and no way to make a list of n
  elements without pushing them one at a time, so ports write `arena$filled` as
  a push loop and pay R2 on every element. C uses `calloc`, `memset`, or
  `malloc` and then writes over it.
- **Hits.** Graph::AStar, Maze::AStar / BFS, BWTEncode (6 n-sized inits per
  round vs C's 2 plus a `memcpy`; the extra ones exist only because there is no
  cheap way to get the storage), BWTDecode.
- **Fix direction.** A core constructor backed by one allocation and a `memset`
  or a store loop the compiler can vectorise. This removes most of R2's cost on
  these tests even before `Loop_pushes` is fixed.
- **Fixed** in [zane-lang/core#15](https://github.com/zane-lang/core/pull/15)
  (`576949e`): `List<T>(n Int, value T)` makes `n` copies of `value`. Its loop
  pushes through the raw primitive, so it gets room on today's compiler too,
  and it needs no new compiler version. On compiler `main` without #366, a
  port whose `filled` calls it runs the R2 table's "after" counts within 0.4%.
  With #366, the counts match exactly. The port change is on LangArena branch
  `zane-perf-list-fill` (872472e, off `zane-perf`). It builds once core tags a
  release with #15 and the port's core pin moves to it.

### B2. `String(@primitives$String)` always copies

The copy half of R1 lives in core: the constructor could take ownership when
its argument is a fresh foreign result. Whether that belongs in core or in the
compiler's move rule is the maintainer's call; it is listed under R1 as one
mechanism.

**Fixed** with R1 in the compiler (zane-lang/compiler#364). Core is unchanged:
the constructor's copy is moved away where its argument is fresh.

### B3. No condition-tested loop

Core's only loop is `to` (a counted `@controlflow$repeat`), so a C `while`
becomes a counted loop with an early `return`, or a loop to
`Int(9223372036854775807)`. That costs a counter and the R6 prologue. A
`while(condition, body)` in `controlflow.zn` would let the compiler emit C's
loop shape.

## Remaining slow tests

Every test at 1.2× C or worse, from a back-to-back run of both
implementations. None has extra work left that a fair port could remove.

| Test | C (s) | Zane (s) | Zane / C | Issues | What the profile shows |
| --- | --- | --- | --- | --- | --- |
| Base64::Encode | 0.142 | 0.539 | 3.80 | R1 | same aklomp codec; two extra copies of each result string per call |
| Graph::AStar | 1.237 | 3.667 | 2.96 | R2, B1, R3 | `filled()` is 72% of a step: 2 × 500k pushes per search |
| Etc::CacheSimulation | 0.989 | 2.758 | 2.79 | R1 | 14.6 allocations, 5 copies, 4 promotes per access |
| Base64::Decode | 0.162 | 0.425 | 2.62 | R1 | as Encode |
| Compress::BWTEncode | 0.892 | 2.109 | 2.36 | R2, B1, R3 | fills are about 50% of instructions; system time 0.36 s vs 0.04 s |
| Compress::LZWEncode | 1.894 | 4.286 | 2.26 | R1 | a `character()` + concat per input byte, each copied and promoted |
| Template::Regex | 1.933 | 3.710 | 1.92 | R1 | 2.70G vs 1.06G instructions; allocator and promote functions top the profile |
| Brainfuck::Recursion | 1.546 | 2.843 | 1.84 | R5 | 38.9G vs 18.6G instructions; `command` dispatch not inlined |
| Brainfuck::Array | 1.455 | 2.513 | 1.73 | R5 | 35.4G vs 13.3G; count reloads, double bounds check, `command` called 635M times |
| Compress::LZWDecode | 1.301 | 2.118 | 1.63 | R1 | one concat per dictionary entry |
| Compress::BWTDecode | 1.409 | 2.252 | 1.60 | R2, R3 | `filled(n)` + list growth copies; system time 0.79 s |
| Maze::AStar | 1.613 | 2.555 | 1.58 | R2, B1, R3 | three n-entry fills per search |
| Template::Parse | 1.644 | 2.490 | 1.51 | R1 | about 12 allocations per placeholder |
| Json::ParseMapping | 0.278 | 0.417 | 1.50 | open | equal instructions (see the open question) |
| Json::ParseDom | 0.106 | 0.157 | 1.48 | open | as ParseMapping |
| Compress::HuffDecode | 1.202 | 1.769 | 1.47 | R5, R2 | 1.34G vs 0.90G; node list reloaded per bit, output pushed per byte |
| Maze::BFS | 0.645 | 0.848 | 1.31 | R2, B1 | the `visited` fill |
| Etc::NeuralNet | 1.268 | 1.627 | 1.28 | R5 | 2.12G vs 1.82G; same layout as C, bounds checks on index lists |
| Graph::BFS | 1.391 | 1.758 | 1.26 | R2, B1, R5 | 1.03G vs 0.58G; the `visited` fill, plus pushes into a growing queue (C allocates it once) |
| Binarytrees::Arena | 0.504 | 0.627 | 1.24 | R3 | fewer instructions than C; the remaining time is page faults |
| Sort::Quick | 1.791 | 2.185 | 1.22 | R6, B3 | 0.96G vs 0.49G instructions; scan prologues |
| Graph::DFS | 1.362 | 1.660 | 1.22 | R2, B1, R5 | not profiled; the same fill-and-push structure as Graph::BFS |

Faster than C now: Maze::Generator (0.73), Hash::SHA256 (0.78), HuffEncode
(0.86) and Words (1.00), plus the tests that were already ahead
(Binarytrees::Obj, Calculator::Interpreter, NGram, GameOfLife, Jaro, Sieve).

## Recommended fix order

Ordered by how much of the remaining gap each fix covers. Each stands alone,
and the repro under its issue is the test to make pass first.

1. **Move fresh temporaries instead of copying them (R1, B2).** 7 tests at
   1.5–3.8×: both Base64 tests, CacheSimulation, both LZW tests and both
   Template tests.
2. **Make filling a list cheap (B1, then R2).** 8 tests at 1.2–3.0×:
   Graph::AStar / BFS / DFS, Maze::AStar / BFS, both BWT tests and HuffDecode.
   A core `List(n, value)` backed by one allocation gets most of the gain
   alone; making `Loop_pushes` fire then covers the pushes that remain.
3. **Stop remapping memory (R3, R4).** Hand a returned list over, keep big
   blocks mapped when a region drains, and free a list that a field assignment
   replaces. Covers the BWT tests' 0.4–0.8 s of system time, the Maze/Graph
   fills and Binarytrees::Arena.
4. **Tell LLVM what can't alias, and keep slow paths out of line (R5).** Covers
   both Brainfuck tests at 1.7–1.8×, HuffDecode, NeuralNet and Arith.
5. **Add `while` to core (B3, R6).** Covers Sort::Quick and any future scan loop.
6. **Look into the Json gap.** Same instruction count, 50 ms slower: check
   whether the clang build of yyjson inside the module is the difference.

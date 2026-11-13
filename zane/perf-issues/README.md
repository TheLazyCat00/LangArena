# Zane vs C: performance issues

As of 2026-11-13, measured against `zane-perf` at 354c5f2 with zane-lang/compiler
at 633ca32 and core v0.10. The same list is kept as a Claude Doc, with a chart
of all 50 ratios from the 2026-11-13 re-bench:
https://claude.ai/artifact/RJcMtraHukcaWwMF9kPPPx

## Summary

Zane runs at a geomean of 0.94× C across the 50 tests. It was 1.17× at the
start of the compiler fixes for these issues and 1.42× at the start of
`zane-perf` (re-bench below). 11 tests are still at 1.2× or slower. The extra
work a fair port could remove has been removed. What is left comes from six
compiler/runtime mechanisms (R1–R6) and three core gaps (B1–B3), listed below
with repros in [`repros/`](repros).

Of the 11 slow tests:

- **Loop reloads (R5):** the two Brainfuck tests, NeuralNet and HuffDecode.
- **String copies (R1):** CacheSimulation, LZWEncode and Base64::Encode.
- **List fills (R2/B1):** Graph::BFS and BWTEncode.
- **The Json gap (open):** Json::ParseDom.
- **Not yet profiled:** LogParser.

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

- **Mechanism.** A list's handle (items and count) lives in its scope's
  frame, which LLVM sees escape. So any call in a loop, a push's slow path
  included, might have written it, and LLVM reloads the items and count
  every round and redoes each index check. The compiler read them once
  before a loop only when the body pushed nowhere and called nothing, and
  every loop here does one or the other. Some checks come twice. In
  Brainfuck, the index check on `commands[pc-1]` follows the port's own
  `pc > size` test, and LLVM can't merge the two because `pc` comes from
  `jumps[pc]` and isn't known to be at least 1. In NeuralNet, the checks
  index through data (`synapses[index]`, `neurons[synapse.source]`).
  Brainfuck's `command` (635M calls) and ArithEncode's `BitWriter.bit` are
  not inlined because the port's C `Buffer` reserve (`binding.c`) is inlined
  into them. Zane's own push slow path is already an out-of-line call.
- **Measured.** Brainfuck::Array 35.4G instructions vs C 13.3G;
  Brainfuck::Recursion 38.9G vs 18.6G.
- **Hits.** Brainfuck (both). HuffDecode: about 20 instructions per bit, with
  `tree.nodes`' pointer and count reloaded after every output push; a local
  copy of the list did not change the count. ArithEncode/Decode:
  `BitWriter.bit` is not inlined either. NeuralNet, Graph::BFS / DFS: index
  reloads plus a bounds check per access. SHA256 had the same problem until its
  hashes moved into an `Array` (354c5f2).
- **Fix direction.** Read the handles once before loops that push or call,
  when nothing in the loop can change them. Alias tags are not the blocker:
  re-rooting package C's TBAA tags under Zane's left the executable
  byte-identical.
- **Fixed in part** in two PRs. [zane-lang/compiler#371](https://github.com/zane-lang/compiler/pull/371)
  (`ba53d1e`) stops `Loop_pushes` from taking an imported function, whose
  body it can't see, as unable to change a list.
  [zane-lang/compiler#372](https://github.com/zane-lang/compiler/pull/372)
  (`1062c7d`) reads a loop's lists once before it when the body pushes only
  onto a list no other address reaches, calls only functions that change no
  list handle, or calls into C that cannot call back. An element list at an
  index the loop does not change (`this.adj[vertex]`) is read before the
  loop too, with an empty stand-in when the index is out of range, so the
  program still stops at the same read. In BFS's inner loop the common path
  is now about 9 instructions instead of about 20. Callgrind instructions,
  compiler `main` at 9cd0166 → #372, port unchanged, all 50 checksums OK,
  minor faults unchanged:

  | Test | Instructions before | after | |
  | --- | ---: | ---: | ---: |
  | Graph::BFS | 12.87G | 7.83G | −39.2% |
  | Graph::DFS | 7.77G | 5.90G | −24.2% |
  | Brainfuck::Recursion | 38.92G | 35.59G | −8.5% |
  | Brainfuck::Array | 35.47G | 33.30G | −6.1% |
  | Compress::HuffDecode | 29.38G | 27.74G | −5.6% |
  | Etc::NeuralNet | 25.41G | 23.77G | −6.4% |
  | Compress::ArithEncode | 10.49G | 10.49G | |
  | Compress::ArithDecode | 14.04G | 14.04G | |

  Still open: inlining `command` and `bit` is left alone, since their size
  comes from the port's C `Buffer`. Whether Brainfuck's and NeuralNet's
  second checks can be removed has not been investigated.

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
- **Fixed** in [zane-lang/compiler#375](https://github.com/zane-lang/compiler/pull/375):
  a loop that can leave early, holds no loop, and indexes an element by a local
  it steps by a constant apart from its counter is a search. Codegen weights its
  loop test as going round a few times, so IRCE leaves it whole. Sort::Quick:
  11.58G → 8.37G instructions for the whole run (C: 4.96G); the repro 164.8M →
  122.4M. Every other LangArena test and `tests/perf` program is within 0.1%.
  The port is unchanged.

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

**Closed without a core change.** Zane's repetition is bounded by
construction (spec control-flow §3.5, §4.3), and the language will not get an
unbounded `while`. The cost B3 stood for is R6's prologue, which the compiler
now removes (zane-lang/compiler#375); the counter left over is one register.

## Remaining slow tests

Every test at 1.2× C or worse in the re-bench below. None has extra work left
that a fair port could remove. Instruction counts are Callgrind totals for the
whole process at full size, input setup included.

| Test | C (s) | Zane (s) | Zane / C | Issues | What the profile shows |
| --- | --- | --- | --- | --- | --- |
| Brainfuck::Array | 1.324 | 2.154 | 1.63 | R5 | 33.3G vs 13.4G instructions; count reloads, double bounds check, `command` not inlined |
| Brainfuck::Recursion | 1.541 | 2.388 | 1.55 | R5 | 35.6G vs 18.6G instructions; `command` dispatch not inlined |
| Etc::CacheSimulation | 0.752 | 1.114 | 1.48 | R1 | 17.4G vs 11.8G instructions; allocations, copies and promotes per access |
| Compress::LZWEncode | 1.326 | 1.799 | 1.36 | R1 | 28.4G vs 18.1G instructions; a `character()` + concat per input byte |
| Etc::NeuralNet | 0.921 | 1.228 | 1.33 | R5 | 23.8G vs 18.2G instructions; same layout as C, bounds checks on index lists |
| Compress::HuffDecode | 0.831 | 1.089 | 1.31 | R5, R2 | 27.7G vs 15.8G instructions; node list reloaded per bit, output pushed per byte |
| Etc::LogParser | 0.487 | 0.621 | 1.28 | not yet known | new at 1.2× or worse (below 1.2× in the earlier run); not profiled |
| Graph::BFS | 0.891 | 1.093 | 1.23 | R2, B1, R5 | 7.84G vs 6.77G instructions; the `visited` fill, plus pushes into a growing queue |
| Base64::Encode | 0.105 | 0.128 | 1.22 | R1 | 1.65G vs 1.64G instructions, equal; the gap is 23 ms |
| Json::ParseDom | 0.086 | 0.104 | 1.21 | open | 2.25G vs 1.72G instructions for the whole process (see the open question) |
| Compress::BWTEncode | 0.653 | 0.789 | 1.21 | R2, B1, R3 | 10.8G vs 6.0G instructions; fills, list growth |

Etc::LogParser is new to this list: the earlier run had it below 1.2×.

Faster than C now: Binarytrees::Obj (0.17), Distance::NGram (0.33), Calculator::Interpreter (0.48), Etc::Words (0.49), Distance::Jaro (0.58), Etc::GameOfLife (0.61), Template::Regex (0.67), Maze::AStar (0.67), Compress::HuffEncode (0.75), Maze::Generator (0.78), Compress::LZWDecode (0.79), Calculator::Ast (0.81), Maze::BFS (0.82), CSV::Parse (0.87), Json::Generate (0.89), Template::Parse (0.92), Etc::Sieve (0.93), Hash::CRC32 (0.94), CLBG::Spectralnorm (0.94), Hash::SHA256 (0.96), CLBG::Mandelbrot (0.97), Sort::Self (0.99).

### Re-bench of all 50 tests

- **Compiler:** zane-lang/compiler at 633ca32 (#375's head, which contains
  `main` at 1062c7d). Built with `ZANE_PREFETCH=0`. The binary is
  byte-identical to the default build, and to one built with
  `ZANE_INTERLEAVE=0` too: neither pass finds a loop it applies to in this
  port.
- **Port:** `zane-perf` at 354c5f2 with core v0.10.
- **C:** the `c/` prod build.
- **Method:** three runs of all 50 tests on each side, alternating Zane and C,
  back to back in one container (4 vCPU). Each figure is the median of a
  test's three `run.js` times. All 50 checksums were OK in every run on both
  sides.

| Test | C (s) | Zane (s) | Zane / C | Earlier Zane / C |
| --- | --- | --- | --- | --- |
| Binarytrees::Obj | 1.912 | 0.323 | 0.17 | below 1.2 |
| Binarytrees::Arena | 0.412 | 0.447 | 1.08 | 1.24 |
| Brainfuck::Array | 1.324 | 2.154 | 1.63 | 1.73 |
| Brainfuck::Recursion | 1.541 | 2.388 | 1.55 | 1.84 |
| Matmul::Single | 4.463 | 4.817 | 1.08 | below 1.2 |
| Matmul::T4 | 1.274 | 1.493 | 1.17 | below 1.2 |
| Matmul::T8 | 1.224 | 1.334 | 1.09 | below 1.2 |
| Matmul::T16 | 1.110 | 1.267 | 1.14 | below 1.2 |
| Base64::Encode | 0.105 | 0.128 | 1.22 | 3.80 |
| Base64::Decode | 0.120 | 0.126 | 1.05 | 2.62 |
| Json::Generate | 0.274 | 0.244 | 0.89 | below 1.2 |
| Json::ParseDom | 0.086 | 0.104 | 1.21 | 1.48 |
| Json::ParseMapping | 0.235 | 0.273 | 1.16 | 1.50 |
| CSV::Parse | 2.202 | 1.924 | 0.87 | below 1.2 |
| Etc::Sieve | 2.439 | 2.270 | 0.93 | below 1.2 |
| Etc::TextRaytracer | 0.933 | 1.045 | 1.12 | below 1.2 |
| Etc::NeuralNet | 0.921 | 1.228 | 1.33 | 1.28 |
| Etc::CacheSimulation | 0.752 | 1.114 | 1.48 | 2.79 |
| Etc::GameOfLife | 1.353 | 0.819 | 0.61 | below 1.2 |
| Etc::Words | 1.998 | 0.988 | 0.49 | below 1.2 |
| Etc::LogParser | 0.487 | 0.621 | 1.28 | below 1.2 |
| Template::Regex | 2.250 | 1.504 | 0.67 | 1.92 |
| Template::Parse | 1.482 | 1.366 | 0.92 | 1.51 |
| Sort::Quick | 1.302 | 1.439 | 1.11 | 1.22 |
| Sort::Merge | 1.496 | 1.704 | 1.14 | below 1.2 |
| Sort::Self | 1.991 | 1.975 | 0.99 | below 1.2 |
| Graph::BFS | 0.891 | 1.093 | 1.23 | 1.26 |
| Graph::DFS | 0.985 | 1.081 | 1.10 | 1.22 |
| Graph::AStar | 1.207 | 1.218 | 1.01 | 2.96 |
| Hash::SHA256 | 0.806 | 0.776 | 0.96 | below 1.2 |
| Hash::CRC32 | 1.038 | 0.972 | 0.94 | below 1.2 |
| Calculator::Ast | 1.061 | 0.861 | 0.81 | below 1.2 |
| Calculator::Interpreter | 1.493 | 0.724 | 0.48 | below 1.2 |
| Maze::Generator | 0.526 | 0.411 | 0.78 | below 1.2 |
| Maze::BFS | 0.507 | 0.417 | 0.82 | 1.31 |
| Maze::AStar | 0.929 | 0.625 | 0.67 | 1.58 |
| CLBG::Fannkuchredux | 1.277 | 1.350 | 1.06 | below 1.2 |
| CLBG::Mandelbrot | 0.870 | 0.845 | 0.97 | below 1.2 |
| CLBG::Nbody | 0.903 | 0.920 | 1.02 | below 1.2 |
| CLBG::Spectralnorm | 0.930 | 0.875 | 0.94 | below 1.2 |
| Compress::BWTEncode | 0.653 | 0.789 | 1.21 | 2.36 |
| Compress::BWTDecode | 1.056 | 1.242 | 1.18 | 1.60 |
| Compress::HuffEncode | 0.879 | 0.663 | 0.75 | below 1.2 |
| Compress::HuffDecode | 0.831 | 1.089 | 1.31 | 1.47 |
| Compress::ArithEncode | 1.233 | 1.322 | 1.07 | below 1.2 |
| Compress::ArithDecode | 0.975 | 1.044 | 1.07 | below 1.2 |
| Compress::LZWEncode | 1.326 | 1.799 | 1.36 | 2.26 |
| Compress::LZWDecode | 0.866 | 0.687 | 0.79 | 1.63 |
| Distance::Jaro | 1.101 | 0.635 | 0.58 | below 1.2 |
| Distance::NGram | 1.717 | 0.572 | 0.33 | below 1.2 |

### Valgrind ran three tests wrong (fixed)

Under Valgrind, three tests that are OK natively went wrong:

- **Maze::Generator, Maze::BFS, Maze::AStar:** under `--tool=none`, they
  crashed with SIGSEGV in `maze$generate`. Under Callgrind, they stopped with
  `index out of range`.
- **Graph::BFS:** under `--tool=none`, it gave checksum 48960 instead of
  50400. Under Callgrind it was right, with the same count as after the fix.
  Its 7.83G in R5 stands.

**Cause.** The runtime makes a context's frames usable a step at a time,
from its fault handler, and then runs the faulting access again. Valgrind
hands a handler stale registers, so that access could run again at an older
address. Natively, the processor reports exact registers, so this never
happens outside Valgrind.

**Fixed** in [zane-lang/compiler#376](https://github.com/zane-lang/compiler/pull/376)
(`22397fc`). Under Valgrind, the runtime now makes the whole range usable
when it reserves it. All 50 tests print `OK` under `valgrind --tool=none`.

The compiler's `dev/bench/langarena/run` measures tests under Callgrind and
keeps a count only from a run that printed `NAME: OK`. Callgrind
instructions, whole process, full size, `run.js`:

| Test | #375, before | #376 | C |
| --- | ---: | ---: | ---: |
| Maze::Generator | `index out of range` | 4.56G | 3.08G |
| Maze::BFS | `index out of range` | 3.46G | 1.95G |
| Maze::AStar | `index out of range` | 5.73G | 4.74G |
| Graph::BFS | 7.84G | 7.84G | 6.77G |

The earlier Graph::BFS figure, "1.03G vs 0.58G", does not match a full-size
run of either build. R2's Maze counts (3.47G and 5.75G after #366) are
within 0.4% of #376's, so those runs most likely did not crash. #366 has
not been rebuilt to check.

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
4. **Read list handles once before loops that push or call (R5).** Covers
   both Brainfuck tests at 1.7–1.8×, HuffDecode, NeuralNet and Arith.
5. ~~**Add `while` to core (B3, R6).**~~ Done in the compiler instead
   (zane-lang/compiler#375): searches are no longer split by IRCE.
6. **Look into the Json gap.** Same instruction count, 50 ms slower: check
   whether the clang build of yyjson inside the module is the difference.

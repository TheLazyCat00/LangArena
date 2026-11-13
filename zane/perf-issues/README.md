# Zane vs C: performance issues

As of 2026-11-13 (second re-bench), measured against `zane-perf` at e004415
with zane-lang/compiler v0.35 (6ce1542) and core v0.10. The Claude Doc below
still shows the first 2026-11-13 re-bench (354c5f2, 633ca32):
https://claude.ai/artifact/RJcMtraHukcaWwMF9kPPPx

## Summary

Zane runs at a geomean of 0.93× C across the 50 tests (re-bench below). It
was 0.94× at the first re-bench of 2026-11-13, 1.17× at the start of the
compiler fixes for these issues and 1.42× at the start of `zane-perf`. 10
tests are at 1.2× or slower. Three more port fixes (LogParser,
CacheSimulation, LZWEncode) removed extra work the port did. What is left
comes from compiler/runtime mechanisms (R1–R8) and the Json gap, listed below
with repros in [`repros/`](repros).

Of the 10 slow tests:

- **`command` not inlined (R8) and per-op dispatch:** the two Brainfuck tests.
- **Data-dependent bounds checks (R5 notes):** NeuralNet, HuffDecode.
- **Assignment copies (R7):** LZWEncode. A prototype brings it to C's speed.
- **List fills and growth (R2/R3):** BWTEncode.
- **The Json gap (open):** Json::ParseDom, Json::ParseMapping.
- **Moved without a code change:** Graph::DFS (1.10× in the previous run)
  and Matmul::T4 (1.17× before).

## Port fixes on zane-perf (class a)

Sixteen commits, newest first, make the port do the same work as C; each kept
all 50 checksums OK. Times are `run.js` wall-clock on the measuring machine.

| Commit | Test | Port did extra work | Before → after | C |
| --- | --- | --- | --- | --- |
| e004415 | Compress::LZWEncode | a foreign `character()` call allocated a one-byte string for every input byte (20.4M per run); C builds it in a two-byte stack buffer. The 256 strings are now made once per encode | 28.5G → 25.4G instructions; 1.80 → 1.68 s | 1.373 s |
| cff5968 | Etc::CacheSimulation (every `StringMap`) | the slot was the mixed hash modulo the table size, which reads only its low bits: the `item_N` keys clustered, 3.7 probes per lookup at load 0.5 where 1.1 is expected, and a divide per probe. uthash uses a power-of-two table. Now a power-of-two table, the top bits of a 64-bit Fibonacci multiply, and no divide | 1.114 → 0.766 s | 0.692 s |
| 835f952 | Etc::LogParser (and Template::Regex's matches) | the regex verbs took the subject as `const char *`, so every call copied the 7.15 MB log into a fresh NUL-terminated block and ran `strlen` over it, 156 times per run; C passes the pointer and length. Now `zane_bytes`, and `pcre2_jit_match` as in C | 0.621 → 0.522 s | 0.506 s |
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
fewer instructions, see R6), a local copy of the Huffman node list in
decode (no change, see R5), and Graph::BFS with a queue of `vertices` slots
filled up front and written by index, as C does (1.23×, no change).

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

  Still open: `command` and `bit` are not inlined. For `command`, R8 shows
  the C `Buffer` is not the reason. NeuralNet has no second checks; see
  "Findings for the other slow tests" below.

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

### R7. Assigning a held local at its last read copies it

- **Mechanism.** In `combined String=current+nextChar; ... current=combined;`
  the fresh string is held in its scope's slot, and the assignment copies it
  (`zane_copy`) into `current`, which relocates it into `current`'s region,
  before the scope frees the original. Nothing reads `combined` after the
  assignment. Only a `return` moves a held local
  ([zane-lang/compiler#364](https://github.com/zane-lang/compiler/pull/364)'s
  `returned_moves`). Writing `current=current+nextChar` instead makes the
  result where `current` lives.
- **Measured.** [`repros/string-assign`](repros/string-assign),
  `out/host/repro 1000000 N`, Callgrind on v0.35: form 1 (`combined=…;
  current=combined`) 672.3M instructions, form 2 (the same inside an `if`, as
  LZWEncode writes it) 674.3M, form 3 (`current=current+next`) 301.3M.
  In Compress::LZWEncode it is one assignment per input byte (20.4M per run):
  `zane_overwrite` 8.47G, `zane_copy` 2.36G and `zane_alloc_held` 1.7G of the
  run's 25.4G instructions.
- **Hits.** Compress::LZWEncode. Any loop that builds a value in a local and
  then stores it into an older one.
- **Fix direction.** When a held local's last read in its scope copies it
  into another place, move it there (`Take`, as a return does), and when that
  move is the only way it leaves, hold it as a plain `let` so it is made
  where it ends up. LZWEncode's `found`/`found:else()` reads `combined` in the
  `else` branch, which comes after the `then` branch in the lowered code, so
  the analysis has to treat the two branches as exclusive.
- **Prototype** (not a PR): [`repros/string-assign/compiler-prototype.patch`](repros/string-assign/compiler-prototype.patch),
  `Regions.assigned_moves` on compiler 6ce1542, which handles straight-line
  code, `if` bodies and expansions, not loops or exclusive branches. The
  repro's forms 1 and 2 drop to 296.2M and 299.2M instructions, all 50
  `test.js` and `run.js` checksums stay OK, and LZWEncode with its hit branch
  written after the miss branch runs at C's speed: 1.26–1.33 s against C's
  1.28–1.36 s, three runs each. Without that reorder the prototype does not
  apply to LZWEncode, and the reorder alone changes nothing on v0.35.

### R8. Brainfuck's `command` is not inlined: three call sites, not the C Buffer

This corrects R5's note that `command` stays out of line because the port's C
`Buffer` growth is inlined into it.

- **Mechanism.** LLVM's inliner reports `command` "too costly to inline
  (cost=315, threshold=225)" at each of its three call sites: one in
  `runArray` and two in `runOps`. A function with one call site gets LLVM's
  large one-caller bonus; this one has three. Array and Recursion share one
  `command`, where C's two files each have their own tape functions with one
  caller each. `runOps` has two call sites because codegen emits its loop
  twice, for a count of at least 16 and for a smaller one
  (`Emit.versioned`), which duplicates every call in the body.
- **The Buffer is not the cause.** With the tape as a native `List<Int>`,
  the remark and the cost are the same, and the times are no better
  (Array 1.87×, Recursion 1.60×).
- **Measured** (experiments, not committed, since inlining `command` was
  decided to be left alone; this is the evidence to revisit that):
  - Giving `runArray` its own copy of `command` gets it inlined.
    Brainfuck::Array 2.24 s → 1.85 s (1.73× → 1.40× C). Recursion is
    unchanged.
  - Also skipping the two loop copies when the loop body calls a function
    (an env-gated compiler change) inlines `command` into `runOps` too.
    Recursion 2.40 s → 2.25 s, but Array went 1.85 s → 2.0 s in the same
    build, so this is not a clear win as it stands.
- **Fix direction.** Port: one `command` per runner, as C has. Compiler: don't
  emit a loop twice when its body calls a function that is not inlined yet,
  or emit it twice only after inlining.

### Findings for the other slow tests (2026-11-13, v0.35)

- **Etc::NeuralNet (R5's "second checks").** There are none. Each
  data-dependent index has one check: `synapses[incoming[j]]` and
  `neurons[synapse.source]`, where C follows pointers. `update`'s loop is 22
  instructions per synapse, of which the two checks and the 1-based index
  arithmetic are about 8. A compiler cannot drop them without knowing the
  stored indices are in range. The loop is also emitted twice (`Emit.versioned`),
  with identical bodies.
- **Compress::HuffDecode.** #372 keeps the node list in registers now. A bit
  costs about 22 instructions: two index checks, one of which re-checks
  the `current` the previous bit already checked (LLVM does not carry the
  range across the back edge), a leaf test that reads `left` and `right`
  where C reads one `is_leaf` byte, and the output `Buffer`'s capacity test
  per byte, where C writes into a block allocated at full size.
- **Graph::BFS.** A queue of `vertices` slots filled up front and written by
  index, as C does, gave no gain (1.23×), so it is not committed. Not
  profiled further, since Callgrind is unreliable here.
- **List fills (B1).** `zane-perf-list-fill` (872472e) with core `main`
  (576949e) built directly with `zanec`: BWTEncode, BWTDecode, Graph::BFS,
  Graph::AStar and Maze::BFS all within noise of `zane-perf`. #366 already
  delivers B1's gain, so a core release with #15 is not a performance lever.
- **Base64::Encode.** 1.07× in this session's runs (23 ms absolute in the
  earlier run): noise at this size.

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

Every test at 1.2× C or worse in the re-bench below. Instruction counts are
Callgrind totals for the whole process at full size, input setup included.

| Test | C (s) | Zane (s) | Zane / C | Issues | What the profile shows |
| --- | --- | --- | --- | --- | --- |
| Brainfuck::Array | 1.302 | 2.175 | 1.67 | R8 | 33.3G vs 13.3G instructions; `command` called once per command (three call sites, cost 315 > 225); one `command` per runner gives 1.40× |
| Brainfuck::Recursion | 1.479 | 2.408 | 1.63 | R8, R5 | 35.6G vs 18.6G instructions; `command` not inlined (its loop is emitted twice); a variant match, then the op switch, per op |
| Json::ParseDom | 0.079 | 0.112 | 1.42 | open | 2.25G vs 1.72G instructions for the whole process (see the open question) |
| Json::ParseMapping | 0.212 | 0.299 | 1.41 | open | see the open question |
| Graph::DFS | 1.067 | 1.480 | 1.39 | R5 | 1.10× in the previous run; not re-profiled |
| Etc::NeuralNet | 0.962 | 1.213 | 1.26 | R5 notes | 23.8G vs 18.2G instructions; one check per data-dependent index where C follows pointers |
| Compress::BWTEncode | 0.627 | 0.787 | 1.26 | R2, R3 | 10.8G vs 6.0G instructions; fills, list growth; the list-fill branch does not change it |
| Matmul::T4 | 1.098 | 1.359 | 1.24 | none known | 1.17× in the previous run; threaded, noisy |
| Compress::HuffDecode | 0.880 | 1.075 | 1.22 | R5 notes | 27.7G vs 15.8G instructions; two checks per bit (one repeated), a two-field leaf test, the push capacity test |
| Compress::LZWEncode | 1.373 | 1.677 | 1.22 | R7 | 25.4G vs 18.1G instructions; one assignment copy per input byte; the R7 prototype reaches C's speed |

Faster than C now: Binarytrees::Obj (0.17), Calculator::Interpreter (0.35), Distance::NGram (0.36), Etc::Words (0.52), Distance::Jaro (0.58), Etc::GameOfLife (0.58), Maze::AStar (0.68), Template::Parse (0.71), Json::Generate (0.74), Compress::HuffEncode (0.77), Maze::Generator (0.77), Template::Regex (0.81), Calculator::Ast (0.84), Compress::LZWDecode (0.84), Maze::BFS (0.85), Etc::Sieve (0.91), Graph::AStar (0.91), Hash::CRC32 (0.92), Hash::SHA256 (0.92), Sort::Self (0.98), CLBG::Mandelbrot (0.99), CLBG::Nbody (0.99).

### Re-bench of all 50 tests

- **Compiler:** zane-lang/compiler v0.35 (6ce1542, `main` with #375), the
  release toolchain, default build.
- **Port:** `zane-perf` at e004415 with core v0.10, its pin moved to v0.35
  locally for the build.
- **C:** the `c/` prod build.
- **Method:** three runs of all 50 tests on each side, alternating C and
  Zane, back to back in one container (4 vCPU), with nothing else running.
  Each figure is the median of a test's three `run.js` times. All 50
  checksums were OK in every run on both sides. Run-to-run spread in this
  container is several percent: Graph::DFS and the Matmul thread tests moved
  most between the two re-benches, with no change to their code.

| Test | C (s) | Zane (s) | Zane / C | Previous Zane / C |
| --- | --- | --- | --- | --- |
| Binarytrees::Obj | 2.570 | 0.428 | 0.17 | 0.17 |
| Binarytrees::Arena | 0.518 | 0.531 | 1.03 | 1.08 |
| Brainfuck::Array | 1.302 | 2.175 | 1.67 | 1.63 |
| Brainfuck::Recursion | 1.479 | 2.408 | 1.63 | 1.55 |
| Matmul::Single | 4.159 | 4.525 | 1.09 | 1.08 |
| Matmul::T4 | 1.098 | 1.359 | 1.24 | 1.17 |
| Matmul::T8 | 1.159 | 1.329 | 1.15 | 1.09 |
| Matmul::T16 | 1.113 | 1.334 | 1.20 | 1.14 |
| Base64::Encode | 0.106 | 0.122 | 1.15 | 1.22 |
| Base64::Decode | 0.117 | 0.127 | 1.09 | 1.05 |
| Json::Generate | 0.294 | 0.217 | 0.74 | 0.89 |
| Json::ParseDom | 0.079 | 0.112 | 1.42 | 1.21 |
| Json::ParseMapping | 0.212 | 0.299 | 1.41 | 1.16 |
| CSV::Parse | 2.221 | 2.210 | 1.00 | 0.87 |
| Etc::Sieve | 2.793 | 2.552 | 0.91 | 0.93 |
| Etc::TextRaytracer | 0.888 | 0.995 | 1.12 | 1.12 |
| Etc::NeuralNet | 0.962 | 1.213 | 1.26 | 1.33 |
| Etc::CacheSimulation | 0.692 | 0.766 | 1.11 | 1.48 |
| Etc::GameOfLife | 1.484 | 0.857 | 0.58 | 0.61 |
| Etc::Words | 1.974 | 1.029 | 0.52 | 0.49 |
| Etc::LogParser | 0.506 | 0.522 | 1.03 | 1.28 |
| Template::Regex | 2.208 | 1.799 | 0.81 | 0.67 |
| Template::Parse | 1.733 | 1.222 | 0.71 | 0.92 |
| Sort::Quick | 1.310 | 1.444 | 1.10 | 1.11 |
| Sort::Merge | 1.485 | 1.731 | 1.17 | 1.14 |
| Sort::Self | 2.027 | 1.987 | 0.98 | 0.99 |
| Graph::BFS | 1.351 | 1.472 | 1.09 | 1.23 |
| Graph::DFS | 1.067 | 1.480 | 1.39 | 1.10 |
| Graph::AStar | 1.111 | 1.007 | 0.91 | 1.01 |
| Hash::SHA256 | 0.808 | 0.746 | 0.92 | 0.96 |
| Hash::CRC32 | 1.042 | 0.960 | 0.92 | 0.94 |
| Calculator::Ast | 1.025 | 0.863 | 0.84 | 0.81 |
| Calculator::Interpreter | 1.831 | 0.650 | 0.35 | 0.48 |
| Maze::Generator | 0.761 | 0.585 | 0.77 | 0.78 |
| Maze::BFS | 0.533 | 0.452 | 0.85 | 0.82 |
| Maze::AStar | 1.578 | 1.067 | 0.68 | 0.67 |
| CLBG::Fannkuchredux | 1.272 | 1.320 | 1.04 | 1.06 |
| CLBG::Mandelbrot | 0.850 | 0.842 | 0.99 | 0.97 |
| CLBG::Nbody | 0.913 | 0.908 | 0.99 | 1.02 |
| CLBG::Spectralnorm | 0.938 | 0.940 | 1.00 | 0.94 |
| Compress::BWTEncode | 0.627 | 0.787 | 1.26 | 1.21 |
| Compress::BWTDecode | 1.064 | 1.209 | 1.14 | 1.18 |
| Compress::HuffEncode | 0.854 | 0.659 | 0.77 | 0.75 |
| Compress::HuffDecode | 0.880 | 1.075 | 1.22 | 1.31 |
| Compress::ArithEncode | 1.243 | 1.306 | 1.05 | 1.07 |
| Compress::ArithDecode | 0.977 | 1.033 | 1.06 | 1.07 |
| Compress::LZWEncode | 1.373 | 1.677 | 1.22 | 1.36 |
| Compress::LZWDecode | 0.892 | 0.753 | 0.84 | 0.79 |
| Distance::Jaro | 1.096 | 0.631 | 0.58 | 0.58 |
| Distance::NGram | 1.691 | 0.615 | 0.36 | 0.33 |

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
7. **Move a held local at its last read (R7).** LZWEncode at 1.22×; the
   prototype brings it to C's speed once the if/else branches are treated
   as exclusive.
8. **Get Brainfuck's `command` inlined (R8).** One `command` per runner in
   the port (Array 1.67× → about 1.40×), and a loop that calls emitted once
   rather than twice for Recursion.

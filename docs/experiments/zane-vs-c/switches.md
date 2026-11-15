# Compiler switches in the Zane-vs-Goose builds

Which experimental `ZANE_*` switches of the compiler (branch
`experiment/zane-vs-goose`) the LangArena builds use, as of step 27
(`step27-goose.md`, geomean Zane / Goose-clang 0.982). The measurements
behind each are in `goose-progress.md`, or in the compiler's
`docs/experiments/` where noted.

## On (set for every build)

```
ZANE_LOOP_REGS=1 ZANE_ASSIGN_MOVES=1 ZANE_VERSION_CALLS=1 ZANE_LENT_OWNERS=1
ZANE_FRAME_SHADOW=1 ZANE_MERGE_CHECKS=1 ZANE_ENDLESS=1 ZANE_SIZED_TBAA=1
ZANE_FRAME_SCOPES=1 ZANE_ARM_CHECKS=1 ZANE_STRIP=1 ZANE_RANGE_CHECKS=1
ZANE_REHOME=1 ZANE_LIST_SPANS=16384 ZANE_IDLE_SEARCH=1 ZANE_DIV_CACHE=1
ZANE_CONST_ARRAYS=1 ZANE_LITERAL_LOCALS=1 ZANE_BIASED_BASE=1 ZANE_UNROLL_SMALL=8
```

The last three are from step 27's round:

- `ZANE_LITERAL_LOCALS`: a local string literal places no frame
  (TextRaytracer's `String` LUT as fast as an `Array`).
- `ZANE_BIASED_BASE`: an element's address from a base biased one element
  down, so the 1-based index's `- 1` is off the address chain.
- `ZANE_UNROLL_SMALL=8`: a loop of a constant count from 2 to 8 unrolled
  whole (HuffDecode's bit loop, as Goose's `for j in 8`).

## On by default (turned off only with `=0`)

`ZANE_HOIST_HANDLES`, `ZANE_INTERLEAVE`, `ZANE_LIGHT_SCOPES`,
`ZANE_LOOP_PUSHES`, `ZANE_ONE_BOX`, `ZANE_PREFETCH`, `ZANE_PARTIAL_INLINE`,
`ZANE_ASSIGN_LET`. All on in every build here.

## Off: measured, no help or slower

| Switch | Result |
| --- | --- |
| `ZANE_PEEL_RECURSION` | Step 24: Binarytrees::Arena 0.584 → 0.608, Sort::Quick slower. After step 26: geomean 0.998 over all 50 (3 rounds), the extremes all within noise on re-runs, Arena included. |
| `ZANE_LOOP_RANGES` | Slower: the range test cost more than the checks it removed (compiler `docs/experiments/goose-comparison`). |
| `ZANE_BUMP_REGIONS` | No gain: the frontier's load and store were the chain, not the free list (goose-comparison). |
| `ZANE_CHUNK_BOXES` | About 5% slower on binarytrees than image boxes, same memory; for platforms where the image window cannot be placed (goose-comparison). |

## Off: never tried in LangArena

`ZANE_POOLED_VARIANTS`, `ZANE_POOL_REGISTERS`, `ZANE_POOL_UNCHECKED`,
`ZANE_PACKED_NODES`: a recursive variant kept as packed nodes in one pool,
as Goose's are. In the compiler's goose-comparison experiment pooled
binarytrees took a quarter less user time. Worth trying on
Binarytrees::Obj (1.29× at step 27); keep them only if all 50 checks pass
and a full run does not regress.

## Debug and tooling switches (not optimizations)

`ZANE_*_DEBUG`, `ZANE_DUMP_PRE`, `ZANE_DUMP_OPT`, `ZANE_DUMP_BEFORE`,
`ZANE_DUMP_AFTER`, `ZANE_LLVM_OPTS`, `ZANE_FRAME_SHADOW_ONLY`,
`ZANE_FRAME_SHADOW_SLOTS`, `ZANE_SHADOW_AGAIN`, `ZANE_INTERLEAVE_REPORT`.

# Zane

All 50 LangArena workloads, ported from the Crystal reference. The manifest
pins compiler **v0.31** and core **v0.8**.

## Run

Install the [Zane CLI](https://github.com/zane-lang/zane), then:

```sh
cd zane
zane toolchain install v0.31
zane fetch
./test.sh                    # all test.js checksums
./run                     # full run.js workloads
./test.sh Graph              # case-insensitive substring filter
zane test                 # codec/support regression tests
python3 tests/runner.py    # executable protocol tests
```

Set `ZANE` to your CLI path if it is not on PATH. The scripts build an optimized
executable before running. For custom configurations, use
`./out/host/zane path/to/config.json [filter]`.

Checksum mismatches exit 1. Invalid configuration, unknown workloads, and
filters matching nothing exit 2. Output follows the suite's startup, result,
and summary protocol. Warmup mutations count exactly as in the reference;
the RNG resets between preparation/warmup and measurement.

## Structure

- `bin/zane`: command-line dispatch and runtime thread configuration.
- `lib/<workload>`: native algorithms and benchmark state, one family per package.
- `lib/codec`: compression test data and bit streams.
- `lib/arena`: configuration, RNG, checksums, containers, and C bindings.
- `test` and `tests`: regression checks.

The quicksort, mergesort, hash maps, priority queue, parsers, neural network,
graph/maze traversals, and four compression codecs are native Zane.
The parallel matrix variants spawn 4, 8, or 16 row workers and configure the
runtime pool before measurement.

## C boundary and layouts

C supplies APIs missing from core v0.8: JSON through yyjson, CSV parsing,
Base64, POSIX regular expressions, mutable byte storage, string byte access,
decimal formatting, file input, timing, and `qsort` for `Sort::Self`.
Foreign data handles own their allocations. Only the root's foreign `Host`
capability reads files, observes clocks, prints, or exits; computation
bindings have no mutable global state.

Graph connectivity, maze cells, and calculator AST links use indices into
native containers. Value records use core's 64-bit `Int`; byte workloads
use a C-backed byte buffer. These layouts affect memory and speed.
The reference's `Hash::SHA256` is a custom small hash; this implementation
preserves it rather than substituting cryptographic SHA-256. The reference
priority queue's exact sift/tie ordering is retained for traversal checksums.

## Docker

```sh
docker compose build base zane
docker compose run --rm zane ./test.sh
TEST=1 ruby benchmarks.rb Zane
PROD=1 ruby benchmarks.rb Zane
```

The image pins CLI v0.15 with its SHA-256 and installs compiler v0.31.
The suite records both versions. Source-size measurements include bindings
and exclude vendored yyjson.

## Dependency

`lib/arena/vendor/yyjson.{c,h}` and `LICENSE` are from
[ibireme/yyjson](https://github.com/ibireme/yyjson), commit
`ebb8d7e5aaa51bea4edefb39ee73a235066b0023` (MIT).
Vendoring keeps the package's declarative C build self-contained.

#!/bin/sh
# Build the LangArena Zane port with the compiler built from the experiment
# branch (zane-lang/compiler perf/zane-vs-c in $COMPILER, default
# /home/user/compiler), run inside a copy of the v0.36 release toolchain so
# the runtime and linker are the release's (a bare dev zanec compiles the
# runtime with the system clang, which changes the code). Copies the result
# to $1 if given. Environment switches (ZANE_*) pass through to zanec.
set -e
COMPILER=${COMPILER:-/home/user/compiler}
T=$HOME/.zane/toolchains
[ -d "$T/dev" ] || cp -r "$T/v0.36" "$T/dev"
cp "$COMPILER/_build/default/bin/zanec/zanec.exe" "$T/dev/libexec/zanec"
cd "$(dirname "$(readlink -f "$0")")/../../../zane"
ZANE_COMPILER="$T/dev/bin/zanec" "${ZANE:-zane}" build 2>&1 | grep -v 'LLD could not\|unable to find library' || true
if [ -n "${1:-}" ]; then cp out/host/zane "$1"; fi

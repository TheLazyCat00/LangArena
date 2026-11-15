#!/bin/sh
# med.sh N TEST BIN... : N interleaved runs pinned to CPU 2, median per binary
N=$1; T=$2; shift 2
for i in $(seq $N); do for b in "$@"; do printf '%s ' "$b"; taskset -c 2 $b /home/user/LangArena/run.js "$T" | grep -o 'in [0-9.]*s' | tr -d 'ins '; done; done | python3 "$(dirname "$0")/med.py"

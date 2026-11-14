# Sampling profiler

`perf` cannot open counters in the cloud container, so this samples the PC
on SIGPROF (the kernel's tick, about 3 ms of CPU time per sample) from an
LD_PRELOAD library and names each sample's function with `nm`.

    gcc -O2 -shared -fPIC sampler.c -o sampler.so
    SAMPLER_OUT=out.txt LD_PRELOAD=$PWD/sampler.so BIN run.js TEST
    python3 symbolize.py out.txt 20

libc's internal functions have no symbols, so its memcpy, memset and
malloc show under the nearest exported name (`__nss_database_lookup`).

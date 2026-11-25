# Runtime Performance

## Asbestos ARM64 Interpreter

Measured on **2026-11-01** on an Apple M1/macOS development host with a Debian 13 ARM64 filesystem fixture, comparing:

- Build 899 (`a1632e5a`), Asbestos interpreter (Meson debugoptimized).
- Updated Asbestos interpreter (Meson debugoptimized).

**Method:** three alternating rounds per runtime; medians and min–max below. Microbenchmarks report **ns/iteration**; macro workloads (`python_start` onward) report **wall-clock ms**. Output checksums matched across all runs.

The microbenchmark source is at [interp_bench.c](../tests/linuxrunner/bench/interp_bench.c). Ratios are Build 899 time / candidate time (above 1.0× means faster).

| workload | rel 899 median (min–max) | current interpreter | interpreter vs 899 | outputs |
|---|---|---|---|---|
| alu | 13.81 (11.42–14) | 11.53 (11.41–14.77) | 1.20× | identical |
| branch | 17.82 (14.66–18.32) | 16.08 (14.49–26.06) | 1.11× | identical |
| mem_seq | 230075 (200050–245550) | 212350 (187875–325625) | 1.08× | identical |
| mem_rand | 84.5 (72.99–114.4) | 77.37 (73.83–87.83) | 1.09× | identical |
| call | 40.25 (39.16–58.96) | 39.4 (39.09–39.94) | 1.02× | identical |
| indirect | 30.06 (27.44–42.53) | 27.41 (27.35–27.54) | 1.10× | identical |
| float | 14.01 (12.13–21.39) | 12.17 (12.12–13.38) | 1.15× | identical |
| neon | 21130 (19060–22520) | 16740 (16665–23455) | 1.26× | identical |
| string | 31292.5 (28340–32290) | 23645 (23470–27787.5) | 1.32× | identical |
| atomic | 58.27 (53.97–87.54) | 49.55 (49.3–76.27) | 1.18× | identical |
| mutex | 133.8 (119.19–155.95) | 109.33 (106.82–136.67) | 1.22× | identical |
| syscall | 166.21 (165.56–183.6) | 154.05 (142.42–177.62) | 1.08× | identical |
| pingpong | 9113.6 (7804.4–13183.4) | 7627.6 (7197.2–11092.2) | 1.19× | identical |
| python_start | 171 (141–212) | 148 (135–207) | 1.16× | identical |
| python_compute | 822 (668–987) | 830 (675–831) | 0.99× | identical |
| python_json | 1163 (904–1198) | 1063 (916–1083) | 1.09× | identical |
| gcc_compile | 5654 (4695–6770) | 4806 (4656–6134) | 1.18× | identical |
| perl_regex | 197 (180–253) | 178 (165–242) | 1.11× | identical |
| gzip | 356 (337–617) | 351 (328–412) | 1.01× | identical |
| xz | 696 (636–935) | 637 (632–785) | 1.09× | identical |
| sort | 466 (454–583) | 465 (420–549) | 1.00× | identical |
| sha256 | 15 (15–32) | 15 (14–16) | 1.00× | identical |

## Interpret the Numbers Carefully

NEON and string microbenchmarks show interpreter improvements of about 1.26× and 1.32×. These are development-host measurements, not physical-iPhone benchmarks.

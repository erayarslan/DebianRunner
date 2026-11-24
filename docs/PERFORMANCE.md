# Runtime Performance

## Interpreter and Optional JIT

Measured on **2026-11-01** on an Apple M1/macOS development host with a Debian 13 ARM64 filesystem fixture, comparing:

- Build 899 (`a1632e5a`), interpreter, Meson debugoptimized with JIT disabled.
- Updated Asbestos interpreter, debugoptimized, JIT disabled.
- Updated runtime with optional ARM64 JIT enabled (JIT code version 14).

**Method:** three alternating rounds per runtime; medians and min–max below. Microbenchmarks report **ns/iteration**; macro workloads (`python_start` onward) report **wall-clock ms**. Output checksums matched across all runs. Correctness gates (`jit_fault_registers_contract`, `precise_fault_pc_contract`, `jit_smoke`) passed on each compared runtime.

The microbenchmark source is at [interp_bench.c](../tests/linuxrunner/bench/interp_bench.c). Ratios are Build 899 time / candidate time (above 1.0× means faster).

| workload | rel 899 median (min–max) | current interpreter | current JIT | interpreter vs 899 | JIT vs 899 | outputs |
|---|---|---|---|---|---|---|
| alu | 13.81 (11.42–14) | 11.53 (11.41–14.77) | 2.56 (2.56–3.03) | 1.20× | 5.39× | identical |
| branch | 17.82 (14.66–18.32) | 16.08 (14.49–26.06) | 4.26 (4.24–5.32) | 1.11× | 4.18× | identical |
| mem_seq | 230075 (200050–245550) | 212350 (187875–325625) | 176100 (175475–186325) | 1.08× | 1.31× | identical |
| mem_rand | 84.5 (72.99–114.4) | 77.37 (73.83–87.83) | 73.69 (72.75–128.1) | 1.09× | 1.15× | identical |
| call | 40.25 (39.16–58.96) | 39.4 (39.09–39.94) | 9.52 (9.17–10.61) | 1.02× | 4.23× | identical |
| indirect | 30.06 (27.44–42.53) | 27.41 (27.35–27.54) | 4.96 (4.79–5.31) | 1.10× | 6.06× | identical |
| float | 14.01 (12.13–21.39) | 12.17 (12.12–13.38) | 13.82 (13.43–14.15) | 1.15× | 1.01× | identical |
| neon | 21130 (19060–22520) | 16740 (16665–23455) | 13455 (12070–13720) | 1.26× | 1.57× | identical |
| string | 31292.5 (28340–32290) | 23645 (23470–27787.5) | 19545 (19055–19842.5) | 1.32× | 1.60× | identical |
| atomic | 58.27 (53.97–87.54) | 49.55 (49.3–76.27) | 57.05 (56.32–60.02) | 1.18× | 1.02× | identical |
| mutex | 133.8 (119.19–155.95) | 109.33 (106.82–136.67) | 122.88 (122.4–127.89) | 1.22× | 1.09× | identical |
| syscall | 166.21 (165.56–183.6) | 154.05 (142.42–177.62) | 173.54 (160.77–184.74) | 1.08× | 0.96× | identical |
| pingpong | 9113.6 (7804.4–13183.4) | 7627.6 (7197.2–11092.2) | 7808.8 (7399.8–9593) | 1.19× | 1.17× | identical |
| python_start | 171 (141–212) | 148 (135–207) | 198 (197–238) | 1.16× | 0.86× | identical |
| python_compute | 822 (668–987) | 830 (675–831) | 488 (475–596) | 0.99× | 1.68× | identical |
| python_json | 1163 (904–1198) | 1063 (916–1083) | 675 (673–861) | 1.09× | 1.72× | identical |
| gcc_compile | 5654 (4695–6770) | 4806 (4656–6134) | 4505 (4147–5638) | 1.18× | 1.26× | identical |
| perl_regex | 197 (180–253) | 178 (165–242) | 202 (199–265) | 1.11× | 0.98× | identical |
| gzip | 356 (337–617) | 351 (328–412) | 382 (339–517) | 1.01× | 0.93× | identical |
| xz | 696 (636–935) | 637 (632–785) | 677 (666–895) | 1.09× | 1.03× | identical |
| sort | 466 (454–583) | 465 (420–549) | 461 (453–520) | 1.00× | 1.01× | identical |
| sha256 | 15 (15–32) | 15 (14–16) | 23 (22–27) | 1.00× | 0.65× | identical |

## Interpret the Numbers Carefully

NEON and string microbenchmarks show interpreter improvements of about 1.26× and 1.32×. The optional JIT benefits longer compute-heavy workloads (`python_compute`, `python_json`, `gcc_compile`), while translation overhead can make short-lived commands (`python_start`, `sha256`) slower than the interpreter.

These are development-host measurements, not physical-iPhone benchmarks. See [JIT implementation](engine/IOS_JIT.md).

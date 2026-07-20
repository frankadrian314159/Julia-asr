# Julia-asr benchmarks

All 14 benchmarks ported from FOL's own `benchmarks/fol-code/asr-*.fol`,
the paper's full Table 1 set - the same benchmarks `cpython-asr` and
`BEAM-asr` both ported. Each benchmark is a plain script (not a module)
defining three functions - `X_plain`, `@asr X_asr`, and `X_counted`
(plain, but bumps a `Counter` immediately before every constructor call -
Julia structs have no monkey-patchable constructor either, so this is
the exact-count alternative both prior ports' own harnesses use).

Grouped by which Julia-asr feature tier each one exercises:

- **v1 (single accumulator, direct reconstruction)**: Particle, Counter, Assoc
- **v1.1 (interprocedural inlining)**: Rotation, Biquad, Comoments, Lorenz, Mandelbrot, Projectile - each routes its reconstruction through a separate helper function rather than reconstructing directly in the loop body
- **v1.2 (branch-shaped reconstruction)**: Bounce (3-way `if`/`elseif`/`else`), Clamp (2-way `if`/`else`), Phase (3-way on `i % 3`) - unlike BEAM-asr's clause-dispatch (free), a `while` loop has one body block, so this genuinely needed new tree-walking code, not just a benchmark port
- **v1.3 (multi-accumulator)**: Kalman (two record types, asymmetric field counts, cross-coupled via intermediate bindings), Twobody (two accumulators of the *same* record type, each reading the other directly)

## Running

```bash
julia benchmarks/run_all.jl
```

Correctness (baseline vs. `@asr`'d output, bit-identical) gates any
timing report, matching both prior ports' protocol.

## Results (mean of 30 trials after 1 warmup call, 500,000 iterations)

```
Benchmark      Base ms     ASR ms Speedup  Base constr ASR constr
----------------------------------------------------------------------------
Particle          0.37       0.37    1.0x      500001x 0 (eliminated)
Counter           0.37       0.37    1.0x      500001x 0 (eliminated)
Assoc             0.37       0.37    1.0x      500001x 0 (eliminated)
Rotation          0.89       0.89    1.0x      500001x 0 (eliminated)
Biquad            1.12       1.12    1.0x      500001x 0 (eliminated)
Comoments         2.49       2.49    1.0x      500001x 0 (eliminated)
Lorenz            1.76       1.76    1.0x      500001x 0 (eliminated)
Mandelbrot        1.24       1.24    1.0x      500001x 0 (eliminated)
Projectile        0.44       0.44    1.0x      500001x 0 (eliminated)
Bounce            0.47       0.47    1.0x      500001x 0 (eliminated)
Clamp             0.59       0.58    1.0x      500001x 0 (eliminated)
Phase             0.36       0.36    1.0x      500001x 0 (eliminated)
Kalman            5.05       5.82   0.87x     1000002x 0 (eliminated)
Twobody           2.23       2.24    1.0x     1000002x 0 (eliminated)
```

Single machine, Julia 1.10.0. Kalman and Twobody's construction counts
are ~2x the others (two accumulator constructions per loop step),
correctly eliminated to 0 in both cases regardless of the timing result.

## Two findings, not one: near-zero speedup, and occasionally *negative*

The first finding (established with Particle/Counter/Assoc, holds across
all 12 single-accumulator-or-branch benchmarks): speedup is consistently
~1.0x, confirmed via `@allocated` to be because Julia's own JIT (LLVM
SROA + escape analysis on the monomorphically-typed, non-escaping, fully
inlined loop) already eliminates the struct allocation before `@asr`
ever runs - not a bug, a real host-compiler-dependent result. This held
even after fixing a genuine benchmark-harness bug along the way: a naive
timing loop whose result went unused let the JIT dead-code-eliminate the
entire 500,000-iteration benchmark (caught via an impossible ~77ns
result); `bench_util.jl`'s `mean_time_ms` fixes this by sinking each
call's result into an escaping `Ref`, the same technique
`BenchmarkTools.jl` uses internally.

**Kalman is the first (and so far only) benchmark where `@asr` measures
*slower* than baseline (0.87x) - reproduced consistently across three
separate runs, not noise.** `@allocated` confirms both `kalman_plain`
and `kalman_asr` are already zero-allocation, so this isn't a case where
ASR is fighting for an allocation win it can't get - it's `@asr`'s own
**parallel temp-then-assign staging** (`Phase 2`'s `__asr_tmp_*`
mechanism, needed for general correctness - see the design notes' Phase
2 section) adding real, measurable copy-through overhead that Julia's
optimizer doesn't fully absorb for Kalman specifically. Kalman is by far
the largest of the 14 benchmarks: two accumulators (5 scalar fields
total, each getting its own temp), plus 13 intermediate local
variables already in the source - the transformed function ends up with
roughly 23 total local bindings versus the baseline's more compact
2-struct-plus-13-locals representation, and at that size the extra
temp-copy indirection stops being free. This is a genuinely new kind of
finding versus the other 13 benchmarks (and versus cpython-asr/BEAM-asr,
where the transform never measured a regression): in a host language
whose compiler already does the allocation-elimination work ASR is
designed to do, the transform can occasionally cost more than it saves
for a sufficiently large, already-optimized function - a real, concrete
illustration of "host-compiler-dependent payoff" going *negative*, not
just *smaller*.

## Caveats (v1-v1.3 scope)

Single machine, no statistical significance testing beyond the trial
mean. Per-function opt-in only (`@asr function ... end`). Still out of
scope, deferred to v1.4+: `for` loops as an alternative to `while`;
mutable-struct/mutation mode; intra-clause `case`/`if` *guarding* a
reconstruction that isn't itself branch-shaped (already covered by
v1.2); two-level (chained) interprocedural inlining - see
`src/AsrTransform.jl`'s module docstring and commit history for the
full qualification rules.

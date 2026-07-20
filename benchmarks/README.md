# Julia-asr benchmarks

Three benchmarks ported from FOL's own `benchmarks/fol-code/asr-*.fol`
(Particle, Counter, Assoc), the same minimal set `cpython-asr` and
`BEAM-asr` both launched with. Each benchmark is a plain script (not a
module) defining three functions - `X_plain`, `@asr X_asr`, and
`X_counted` (plain, but bumps a `Counter` immediately before every
constructor call - Julia structs have no monkey-patchable constructor
either, so this is the exact-count alternative both prior ports' own
harnesses use).

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
Particle          0.82        0.8   1.02x      500001x 0 (eliminated)
Counter           0.81       0.81    1.0x      500001x 0 (eliminated)
Assoc             0.81        0.8    1.0x      500001x 0 (eliminated)
```

Single machine, Julia 1.10.0. Construction counts (500,001 to 0) are
exact per-run tallies from `X_counted`, not estimates.

## A genuinely different finding than cpython-asr or BEAM-asr: near-zero measured speedup, for a real reason

Unlike the other two ports, this isn't a "smaller but real" win - it's
close to *no measurable wall-time win at all* (1.0-1.02x). This was
confirmed to be a real result, not a benchmark bug, after first hitting
(and fixing) an actual bug: a naive `time_ns()`-based timing loop whose
result was discarded let Julia's JIT dead-code-eliminate the *entire*
500,000-iteration loop (a first measurement showed ~77 nanoseconds for
500,000 iterations - physically impossible, immediately diagnostic of
this). `bench_util.jl`'s `mean_time_ms` fixes this by sinking each
call's result into a `Ref` that escapes the timing loop, the standard
technique `BenchmarkTools.jl` itself uses under the hood - this project
deliberately avoids that dependency, per the design notes, but needed
its own version of the same fix.

With that fixed, `@allocated` confirms the *baseline* (untransformed)
functions already allocate **zero bytes** for the whole 500,000-iteration
run - before `@asr` ever touches them. This holds even though the
benchmark structs (`Particle`, `Ctr`, `AssocParticle`) are declared with
untyped fields (`struct Particle x; y end`), which makes them NOT
`isbitstype` by Julia's own static type-system test
(`isbitstype(Particle) == false`) - so this isn't the simple "small
concrete-field struct is a value type" case. What's actually happening:
Julia's JIT specializes each function per call-site argument types (here,
always concrete `Float64`), and its LLVM backend's escape analysis (SROA
- Scalar Replacement of Aggregates) proves the accumulator never escapes
the fully-inlined loop, unboxing it automatically - the same *effect*
`@asr` is designed to produce, achieved by the host compiler itself,
with no source-level transform involved at all.

This is a real, citable, and somewhat surprising finding for the paper's
own discussion, not a null result to bury: of the four language targets,
Julia is the first where the **host compiler already performs a closely
related optimization automatically** for this benchmark shape (small,
non-escaping, monomorphically-typed accumulator, fully inlinable loop).
`@asr` still does the transform correctly - the source-level record
disappears from the AST just as reliably as in the other three ports -
but its *marginal* wall-time contribution here is genuinely close to
zero, because there was very little left to win. This doesn't undermine
the existence-proof claim (the mechanism transfers correctly across all
four languages, mechanically), but it does sharpen it: the *payoff* of
ASR is host-compiler-dependent in a way that's easy to miss testing only
one or two languages, exactly the kind of nuance this project's own
four-language spread was built to surface. A follow-up worth flagging
(not pursued here, v1 scope): a benchmark shape Julia's own escape
analysis can't handle - a larger struct, a non-monomorphic call site, or
one with a genuinely escaping reference - would be needed to see `@asr`
produce a real measured win specifically *because of* the transform
rather than in spite of the host compiler already having done the work.

## Caveats (v1 scope)

Single machine, no statistical significance testing beyond the trial
mean. Per-function opt-in only (`@asr function ... end`), no `for`
loops, no mutable-struct/mutation mode, no multi-accumulator, no
interprocedural inlining, no branch-shaped reconstruction - see the
Julia-asr design notes for the full v1 qualification rules and what's
explicitly deferred to v1.1+.

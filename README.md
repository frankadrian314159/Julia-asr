# Julia-asr

A Julia port of FOL's Aggregate Scalar Replacement (ASR). Built as the
fourth-language existence-proof referenced in the CGO 2027 paper
*"Objects Without Allocation"*'s Threats to Validity section, which
asserts the mechanism "transfers to other transpiled dynamic languages"
without demonstrating it beyond FOL itself. `cpython-asr` is language
#2, `BEAM-asr` is language #3, this is language #4, completing the
CPython -> BEAM -> Julia roadmap.

Julia - like Python - has an actual `while` loop with a rebindable
accumulator, rather than BEAM's clause-dispatch tail recursion, making
`cpython-asr`'s v1 phase structure the closest precedent (see
`src/AsrTransform.jl`'s module docstring). `@asr` is a **per-function
macro** (`@asr function ... end`): given a `while` loop that threads an
immutable struct accumulator through its own back-edge via a positional
constructor call (full or partial), it splits the accumulator into one
scalar local per field, re-boxing only where a bare accumulator
reference survives after the loop.

**No world-guard mechanism is needed** (unlike FOL and `cpython-asr`,
and for a different reason than BEAM's): Julia raises a hard
compile-time error (`invalid redefinition of constant`) when redefining
a struct's field layout in the same session, so already-compiled code
can never observe a stale layout - verified for direct top-level/script
redefinition; `Revise.jl`-mediated redefinition during interactive
development is a separate, not-yet-checked case, so this claim is
explicitly scoped to non-Revise sessions.

## Status: v1

| Concept | This port |
|---|---|
| Qualification (which functions are safe to scalarize) | `AsrTransform.find_accumulator`/`classify_loop`/`classify_post` - scans pre-loop statements for the accumulator init, the loop body for a single reconstruction assignment, and post-loop statements for at most one bare (re-boxing) return |
| The classify-and-rewrite walk | `AsrTransform.check_only_field_reads`/`subst_field_reads` - a whole-node-match-before-recursion walker (Julia's `Expr(:(=), varname, ...)` has no Load/Store context marker the way Python's `ast.Name` does, so the walker must special-case the assignment LHS and field-read receiver explicitly, never recursing into either as an independent bare occurrence) |
| No distinct "partial update" shape | Julia's default struct constructor always requires every field positionally, so unlike `BEAM-asr`'s three-way ArgKind split (full/update/passthrough), there's only one shape here: extract each positional argument expression and substitute field reads within it |
| Record-field-read/collision safety | `check_collisions` - synthesized scalar names (`p_x`) *and* parallel-update temp names (`__asr_tmp_p_x`) checked against every textual occurrence (read or write) anywhere in the whole function body, once per function (Julia has no per-clause scoping to exploit the way BEAM does) |
| No FOL/BEAM analog - interface preservation | the function's own signature `Expr` is copied through completely unmodified; only the body is rewritten |
| No FOL/cpython-asr analog - world guard | not needed; see above |

Explicitly deferred to v1.1+: `for` loops as an alternative to `while`;
mutable structs / direct field-mutation mode (`cpython-asr`'s v1.4
analog); multi-accumulator (`cpython-asr`'s v1.2); interprocedural
inlining through a helper function; branch-shaped reconstruction
(`if`/`elseif`/`else` choosing between reconstructions) - not "free,"
declines cleanly if seen; parametric structs (`T isa DataType` required,
a deliberate exclusion, not an accident); a `while` loop wrapped in a
performance macro like `@inbounds`/`@simd`/`@fastmath`.

## Layout

- `src/AsrTransform.jl` - the `@asr` macro entry point, qualification (phase 1), and rewrite (phase 2)
- `test/runtests.jl` - `Test`-based tests, 8 positive cases (full reconstruction, partial update, field-read guard condition, bare-return re-boxing, early return, `let`-block struct declaration, plus a structural check) and 15 negative/abort-safe cases (short-form function, zero/two while loops, mutable/parametric struct, keyword/wrong-arity constructor call, bare accumulator reference, bare early return, scalar/temp name collision including a colliding free read of an outer name, double reconstruction, `@inbounds`-wrapped loop)
- `benchmarks/` - Particle, Counter, and Assoc, ported from FOL's `benchmarks/fol-code/asr-*.fol`; see `benchmarks/README.md` for results (including a genuinely different finding than the other two ports - near-zero measured speedup, because Julia's own JIT already eliminates the allocation for this benchmark shape) and how to run them

## Running

```bash
julia test/runtests.jl
julia benchmarks/run_all.jl
```

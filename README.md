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

## Status: v1 + v1.1 (interprocedural inlining) + v1.2 (branch-shaped reconstruction) + v1.3 (multi-accumulator)

| Concept | This port |
|---|---|
| Qualification (which functions are safe to scalarize) | `AsrTransform.find_and_classify_accumulators`/`classify_loop`/`classify_post` - scans pre-loop statements for EVERY candidate accumulator init, qualifies each fully independently, the loop body for each one's own single reconstruction, and post-loop statements for at most one bare (re-boxing) return |
| The classify-and-rewrite walk | `AsrTransform.check_only_field_reads`/`subst_field_reads` - a whole-node-match-before-recursion walker (Julia's `Expr(:(=), varname, ...)` has no Load/Store context marker the way Python's `ast.Name` does, so the walker must special-case the assignment LHS and field-read receiver explicitly, never recursing into either as an independent bare occurrence) |
| No distinct "partial update" shape | Julia's default struct constructor always requires every field positionally, so unlike `BEAM-asr`'s three-way ArgKind split (full/update/passthrough), there's only one shape here: extract each positional argument expression and substitute field reads within it |
| Record-field-read/collision safety | `check_collisions_multi` - synthesized scalar names (`p_x`), parallel-update temp names (`__asr_tmp_p_x`), and inline gensym names checked against every textual occurrence (read or write) anywhere in the whole function body AND against every OTHER qualifying accumulator's own synthesized names, once per function (Julia has no per-clause scoping to exploit the way BEAM does) |
| No FOL/BEAM analog - interface preservation | the function's own signature `Expr` is copied through completely unmodified; only the body is rewritten |
| No FOL/cpython-asr analog - world guard | not needed; see above |
| `_try_inline_call` (cpython-asr v1.1) | `AsrTransform.try_inline_helper` - one-level inlining of a single-method helper whose ORIGINAL source `Expr` is recovered via `functionloc` + re-reading and re-parsing its source file (the same reflection `inspect.getsource` performs - Julia macros only see the Expr they're applied to, not the whole module, so there's no `parse_transform`-style Forms list to scan the helper from) |
| `_try_branch_reconstruction` (cpython-asr v1.2) | `AsrTransform.classify_branch_tree` - unlike BEAM-asr (free via clause dispatch), a `while` loop has one body block, so an `if`/`elseif`/`else` statement needed genuine new tree-walking/tree-rewriting code, with a mandatory terminal else |
| Multi-accumulator fixpoint (cpython-asr v1.2) | `AsrTransform.find_and_classify_accumulators` - every candidate position qualifies fully independently (cross-accumulator field reads are already tolerated for free), combined via a cross-accumulator collision check and a `subs`-list substitution fold (`subst_all`) threaded through every rewrite function so one accumulator's reconstruction can read another's fields directly |

Explicitly deferred to v1.4+: `for` loops as an alternative to `while`;
mutable structs / direct field-mutation mode (`cpython-asr`'s v1.4
analog); two-level (chained) interprocedural inlining; intra-clause
`case`/`if` guarding a reconstruction that isn't itself the whole
branch-shaped statement; parametric structs (`T isa DataType` required,
a deliberate exclusion, not an accident); a `while` loop wrapped in a
performance macro like `@inbounds`/`@simd`/`@fastmath`.

## Layout

- `src/AsrTransform.jl` - the `@asr` macro entry point, qualification (phase 1), and rewrite (phase 2)
- `test/runtests.jl` - `Test`-based tests, 14 positive cases (full reconstruction, partial update, field-read guard condition, bare-return re-boxing, early return, `let`-block struct declaration, inlining with/without intermediate bindings, 2-/3-way branch-shaped reconstruction, symmetric/asymmetric multi-accumulator, plus a structural check) and 23 negative/abort-safe cases - see the module docstring and test file for the full list
- `benchmarks/` - all 14 benchmarks from the paper's Table 1, ported from FOL's `benchmarks/fol-code/asr-*.fol`; see `benchmarks/README.md` for results, including two genuinely different findings from the other ports: near-zero measured speedup for 13 of 14 (Julia's own JIT already eliminates the allocation), and a measured *regression* (0.87x) for Kalman specifically, where ASR's own temp-staging overhead outweighs an allocation win that was already free

## Running

```bash
julia test/runtests.jl
julia benchmarks/run_all.jl
```

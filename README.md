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

## Status: v1 + v1.1 (interprocedural inlining) + v1.2 (branch-shaped reconstruction) + v1.3 (multi-accumulator) + v1.4 (parametric structs) + v1.5 (if-dispatch fix) + v1.6 (non-sole-argument opaque-call passthrough) + v1.7 (for-loop support)

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
| Parametric structs (v1.4, corpus-study finding) | `try_accumulator_stmt` unwraps a `UnionAll` (e.g. `InetAddr{T<:IPAddr}`) via `Base.unwrap_unionall` before checking `isstructtype`/`ismutabletype`/`fieldnames` - field shape is fixed by the struct's own declaration, never by which concrete type parameter a given call instantiates, so nothing else in the module needed to change: `typename` was already a bare Symbol everywhere, and the reconstruction call this transform emits is the same syntactic shape (`TypeName(args...)`) the original code used, letting Julia's own type-parameter inference resolve it identically either way. Requires the bare-call form (`Paramed(...)`); an explicit `Paramed{Float64}(...)` still declines, since the constructor callee is then an `Expr(:curly,...)`, not a Symbol |
| If-dispatch fix (v1.5, corpus-study finding) | `classify_loop` no longer dispatches *any* top-level `if` statement to `classify_branch_tree` unconditionally - `if_tree_attempts_reconstruction` is a non-throwing pre-check that only commits to that stricter validation (mandatory terminal else included) when at least one leaf's own last statement actually looks like `varname = ...(...)`; an unrelated guard clause (no leaf resembling a reconstruction) falls through to the same generic `check_only_field_reads` safety check any other ordinary statement gets, so it no longer blocks a genuine reconstruction appearing later in the loop body |
| Non-sole-argument opaque-call passthrough (v1.6, corpus-study finding) | `verify_safe_passthrough_arg` - the accumulator passed bare as one of SEVERAL arguments to a call (`bind(sock, addr)`, distinct from v1.1's `helper(varname)`-shaped sole-argument inlining) is safe when the callee's single applicable method, resolved via multiple dispatch on the accumulator's own type at that position, only reads that parameter's fields; the rewrite phase re-boxes in place (`rebox_call`) since qualification having passed guarantees no other shape can survive there. Two more, genuinely pre-existing v1.1 bugs surfaced fixing this - both invisible until tested against real stdlib source: `Method.file` reports the BUILD machine's own path for sysimage-compiled code (`resolve_source_file`), and a real source file is typically its own `module X ... end`, which the original flat top-level-only helper-source scan never recursed into (`find_all_function_defs!`) |
| `for`-loop support (v1.7, corpus-study finding) | `locate_loop` - generalizes loop detection to `while` OR `for`, treating a `for`'s `iterexpr` (evaluated once, at entry) the same way `while`'s `cond` always was; every other mechanism (branch-shaped reconstruction, inlining, opaque-call passthrough, multi-accumulator) needed NO changes at all, since none of them ever look at the loop header - confirmed by a dedicated composition test. One new hazard: a `for`-loop's own iteration variable can shadow the accumulator's name, declined per-candidate in `find_and_classify_accumulators` rather than risk misattributing references |

Motivated directly by `corpus-study/README.md`'s own findings, each
verified against real code, not just reasoned about in the abstract:
parametric structs were the single largest exclusion (10 of 15
record-shaped hits); `Sockets.listenany`'s `InetAddr` retry loop was
the corpus's cleanest example, but even after the v1.4 fix it still
declined, for a *second*, independent, previously-invisible reason -
its loop body's first statement is `if bind(sock,addr) && ...; return
...; end`, no terminal `else`, and the OLD `classify_loop` treated that
unconditionally as an attempted branch-reconstruction of `addr`,
declining ("requires a terminal else") before ever reaching the real
reconstruction (`addr = InetAddr(addr.host, addr.port+1)`) later in the
same loop body. **v1.5 fixes this too, verified two ways**: an
unrelated guard clause that doesn't touch the accumulator no longer
blocks a later reconstruction (confirmed with a positive test case);
one that passes the accumulator bare into an opaque call (exactly
`listenany`'s own `bind(sock, addr)`) still correctly declines,
now for the *true* reason ("bare accumulator reference outside a field
read") rather than the previous false one. **`listenany` itself still
declines post-v1.5**, for that true, structurally different reason -
`bind(sock, addr)` passes `addr` bare as one of TWO arguments, a shape
v1.1's own sole-argument-only inlining never covered. Re-running the
full corpus study after v1.4+v1.5 confirmed this was not an isolated
case: 0 of 15 candidates qualified.

**v1.6 closes this third gap.** `bind`'s own `InetAddr` method -
`bind(sock::TCPServer, addr::InetAddr) = bind(sock, addr.host,
addr.port)` - is itself a one-line destructuring pass-through that only
reads `addr`'s fields, so it's genuinely safe; `verify_safe_passthrough_arg`
resolves the callee via multiple dispatch to the single applicable
method (filtered by the accumulator's own type at the matching
position, not `length(methods(f)) == 1` - `bind` has many methods) and
confirms that method's matching parameter is used only via field reads,
one level deep. Getting there surfaced two more real, previously-latent
v1.1 bugs, both invisible until tested against actual stdlib source
rather than hand-written test helpers: `Method.file` reports the BUILD
machine's own path for anything compiled into a precompiled sysimage,
not this install's real location; and a real source file is typically
its own `module X ... end`, which the original flat top-level-only
helper-source scan never recursed into at all. Both are fixed for v1.1
too, not just v1.6. With all three gaps closed, `Sockets.listenany`
qualifies end-to-end - confirmed via the gate-faithful oracle AND by
actually running the rewritten function (including its retry-on-taken-port
path) and comparing output to the baseline. **The corpus study now
shows 1 of 15 candidates qualifying** (see `corpus-study/README.md` for
the complete, updated breakdown).

**v1.7 adds `for`-loop support** - not a shape-loosening fix like
v1.4-v1.6, but genuinely new infrastructure, motivated by a corpus-study
finding of a completely different kind: Pass 1's own record-accumulator
scan had only ever been wired up for `:single_while` sites, so 86% of
the corpus's loop-bearing functions (everything `for`-shaped - 81% of
all loop sites, Julia's dominant idiom) were never even CHECKED for a
record-shaped accumulator, let alone declined. Extending Pass 1 to scan
`for`-loop bodies too (costs nothing extra - `classify_candidates` never
looked at the loop header anyway) found **245 more real syntactic
candidates**, all blocked by the same single structural gate. `locate_loop`
generalizes qualification to accept either loop kind, treating `for`'s
`iterexpr` the way `while`'s `cond` always was; `classify_loop`/
`classify_branch_tree`/`try_inline_helper`/`verify_safe_passthrough_arg`
needed no changes at all (confirmed via a dedicated test: branch-shaped
reconstruction composes correctly inside a `for` loop with zero code
changes to that mechanism). Re-running the corpus study with real
`for`-loop qualification (not just Pass-1 scanning) **still shows only 1
of 160 candidates qualifying** - the same real-code pattern that
dominates the `while` set (mutable/reference-semantics objects, not
reconstructed records) turns out to dominate the `for` set even more
heavily: `Ref`/`RefValue` alone account for 102 of 130 "no candidate
found" declines, and `Ref` is a structurally different, even MORE
fundamental mismatch than "mutable struct" - it's an ABSTRACT type
(`isabstracttype(Ref) == true`), not a concrete struct, and it mutates
via `x[] = ...`, not `.field = ...`, so mutable-struct support alone
wouldn't cover it either. See `corpus-study/README.md` for the full
breakdown.

Explicitly deferred: mutable structs / direct field-mutation mode
(`cpython-asr`'s v1.4 analog); `Ref`/`RefValue` mutation-via-getindex
(a distinct, even bigger extension than mutable-struct support - see
above); two-level (chained) interprocedural inlining and two-level
opaque-call passthrough (v1.1/v1.6 both stop at one level); a loop
wrapped in a performance macro like `@inbounds`/`@simd`/`@fastmath`;
multi-iterator `for` headers (`for i in a, j in b`).

## Layout

- `src/AsrTransform.jl` - the `@asr` macro entry point, qualification (phase 1), and rewrite (phase 2)
- `test/runtests.jl` - `Test`-based tests, 17 positive cases (full reconstruction, partial update, field-read guard condition, bare-return re-boxing, early return, `let`-block struct declaration, inlining with/without intermediate bindings, 2-/3-way branch-shaped reconstruction, symmetric/asymmetric multi-accumulator, parametric struct, unrelated guard clause not blocking a later reconstruction, v1.7 for-loop direct reconstruction and branch-shaped composition, plus a structural check) and 32 negative/abort-safe cases, including v1.6's non-sole-argument opaque-call passthrough (long-form, short-form, ambiguous-dispatch decline, parametric-method regression) and v1.7's for-loop shadowing/multi-iterator declines - see the module docstring and test file for the full list
- `benchmarks/` - all 14 benchmarks from the paper's Table 1, ported from FOL's `benchmarks/fol-code/asr-*.fol`; see `benchmarks/README.md` for results, including two genuinely different findings from the other ports: near-zero measured speedup for 13 of 14 (Julia's own JIT already eliminates the allocation), and a measured *regression* (0.87x) for Kalman specifically, where ASR's own temp-staging overhead outweighs an allocation win that was already free
- `corpus-study/` - a shape-recognizing analyzer run against Julia 1.10's *entire* Base plus 12 stdlib modules (365 files, 272K LOC - small enough to cover exhaustively, unlike the other ports' own sampled corpora), measuring ASR candidate-loop density and hand-auditing why all 15 record-shaped hits found decline; see `corpus-study/README.md`

## Running

```bash
julia test/runtests.jl
julia benchmarks/run_all.jl
julia corpus-study/analyzer/run_corpus_scan.jl
```

# Julia-asr corpus study

A shape-recognizing analyzer for ASR candidate loops in Julia, run
against Julia 1.10's own standard distribution, reporting
candidate-loop density and a categorized, hand-audited breakdown of why
none qualify under the real transform. Methodology mirrors FOL's own
corpus study (`../../FOL/fol/docs/cgo2027/corpus-study/`),
`cpython-asr`'s (`../../cpython-asr/corpus-study/`), and `BEAM-asr`'s
(`../../BEAM-asr/corpus-study/`): a syntactic-shape Pass 1 (an
upper-bound proxy) followed by a gate-faithful Pass 2 that runs the
*real* `AsrTransform.rewrite_function` as a black-box oracle - the same
entry point `@asr` itself calls, never a re-implementation that could
drift from the actual v1–v1.5 rules.

**Update (v1.4)**: this study's own finding - parametric structs were
the single largest exclusion in real code (10 of 15 hits) - was fed
back into `AsrTransform.jl` as a targeted fix (unwrap a `UnionAll` via
`Base.unwrap_unionall` before checking `isstructtype`/`ismutabletype`/
`fieldnames`; see `README.md`'s Status table). Re-running this exact
study against the updated transform still showed 0 of 15 qualifying -
not a bug: `Sockets.listenany`, the corpus's one clean example, now
cleared type resolution (confirmed directly - `try_accumulator_stmt`
succeeded) but declined for a second, independent, previously-invisible
reason: its loop body's first statement is an `if` with no terminal
`else` (an early-return guard clause, unrelated to the accumulator),
and `classify_loop` dispatched *any* top-level `if` to
`classify_branch_tree` unconditionally - so it never reached the
genuine reconstruction (`addr = InetAddr(addr.host, addr.port+1)`)
appearing later in the same loop body.

**Update (v1.5)**: that if-dispatch issue was itself fixed
(`if_tree_attempts_reconstruction` - only commit to
`classify_branch_tree`'s strict validation when a leaf actually looks
like a reconstruction attempt; see `README.md`'s Status table).
Verified two ways, both against real code shapes: an unrelated guard
clause that doesn't touch the accumulator no longer blocks a later
reconstruction; one that passes the accumulator bare into an opaque
call still correctly declines. **`Sockets.listenany` itself still
declines even after this fix** - its guard clause is
`if bind(sock, addr) && ...`, and `addr` is passed *bare* into `bind`,
a call the transform has no way to reason about safely (does `bind`
retain or alias the reference?). This is a structurally different,
third reason, distinct from both the parametric-struct wall (v1.4) and
the if-dispatch wall (v1.5) - and it's not one either fix was ever
meant to address. **Re-running the full study confirms this holds
corpus-wide: 0 of 15 candidates qualify after both v1.4 and v1.5.**
Both fixes are real, independently verified, and each closed a genuine
gap - this corpus's own specific 15 candidates simply each have their
own separate, additional reason to decline, on top of whichever wall
motivated each fix. The numbers below reflect the final re-run; the
categorization table further down is kept as originally written (what
motivated the v1.4 fix) with a "Status" column noting what's fixed vs.
still open as of v1.5.

**A real methodological difference from the sibling studies, not just a
smaller number**: Erlang/OTP and the Python package ecosystem are both
far too large to scan exhaustively, so BEAM-asr and cpython-asr each
work from a deliberately-chosen sample (30 files / 27 projects) and
have to argue for its representativeness. Julia's own standard
distribution is small enough to cover *completely* - this study scans
**all of Base** (255 files) plus **12 representative stdlib modules**
(110 files) that ship with every Julia install, not a hand-picked
subset. There's no "why these files" question to answer.

A second, structural difference: unlike BEAM-asr's pure-AST oracle
(`parse_transform` never evaluates anything) or cpython-asr's static
analysis, `AsrTransform.rewrite_function` needs a real `Module` in
which the candidate's accumulator *type* actually resolves
(`resolve_type` calls `Core.eval(mod, typename)` - see
`src/AsrTransform.jl`'s own module docstring). This is exactly why the
corpus is Julia's own Base/stdlib: those types are already loaded in
any running Julia session (Base always; each stdlib module after this
study's own driver `using`s it once), so Pass 2 never needs to
`include`/resolve dependencies for arbitrary third-party code - a real
practical constraint a broader third-party-package corpus would have
had to solve first.

## The analyzer

`analyzer/analyze.jl` (`Analyze` module) finds every **loop site** - a
top-level, long-form `function name(...) ... end` definition containing
at least one `for` or top-level `while` loop - and classifies its
**shape**:

| Shape | Meaning | In scope for `@asr`? |
|---|---|---|
| `single_while` | exactly one top-level `while`, no `for` | yes - `rewrite_function`'s own hard precondition |
| `has_for` | one or more `for` loops, no `while` | no - `for` loops are explicitly unsupported (deferred to v1.4+) |
| `multi_while` | two or more top-level `while` loops, no `for` | no |
| `mixed` | both `for` and `while` present | no |

For `single_while` sites, pre-loop statements are scanned for a
candidate accumulator - `varname = TypeName(args...)`, `TypeName` a
capitalized Symbol, purely positional args - mirroring
`AsrTransform.try_accumulator_stmt`'s own shape exactly, *minus* the
type resolution (which requires a real Module and is Pass 2's job).
Well-known Base collection/map constructor names (`Vector`, `Dict`,
`Set`, `StringVector`, ...) and primitive/numeric type names (`Int`,
`UInt64`, `Char`, `String`, ...) are excluded from the "record"
bucket up front, the same way BEAM-asr's own scanner excludes them -
not a separate mechanism, just a tighter syntactic proxy, confirmed
necessary by direct inspection (see Results). Each surviving candidate
is classified by how the loop body rebuilds it:

| Kind | Shape | ASR-addressable? |
|---|---|---|
| `record_strong` | `varname = TypeName(newargs...)` - same TypeName, directly in the loop body | yes (the only shape `@asr` v1 recognizes) |
| `record_weak` | `varname = helper(...)` - reassigned via some other call | *possibly* (v1.1 inlining) - not verified here |
| `record_mutate` | `varname.field = ...` anywhere in the loop body | no - Julia-asr has no mutation mode |
| `record_other` | reassigned some other way, or never reassigned in the loop body at all | no |

`analyzer/gate_check.jl` (`GateCheck` module) is Pass 2: for every
`record_*` candidate, it re-parses the file, locates the named
function, and calls `AsrTransform.rewrite_function` directly - the
actual, tested, shipped transform, in the resolution Module the
manifest assigns that file. Returns `:qualified`, `:declined` (with
`AsrDecline`'s own message), or `:error` (a shape the transform itself
errors on rather than cleanly declining - none occurred in this run).

## Corpus

365 files, 272,688 lines: all of Julia 1.10's `Base` (255 files), plus
12 stdlib modules chosen for domain spread (`corpus-study/manifest.jl`
has the full list with domain tags): `LinearAlgebra`, `Statistics`,
`SparseArrays` (numeric), `Dates`, `Random`, `Printf` (utility),
`Sockets`, `Serialization` (I/O), `Unicode`, `Logging` (text/
diagnostics), `REPL`, `Test` (tooling). `Base` itself already spans
core collections, strings, numerics, I/O, and the vendored `JuliaSyntax`
parser/tokenizer (`base/JuliaSyntax/`), so domain coverage is broad even
before the stdlib additions.

**Corpus provenance**: the Base/stdlib source shipped with the locally
installed Julia 1.10.0
(`C:\Users\frank\AppData\Local\Programs\Julia-1.10.0\share\julia\`) -
not a separate clone, since this *is* the reference distribution the
`Julia-asr` package itself targets (Project.toml's own compat bound).

## Running

```bash
cd corpus-study
julia analyzer/run_corpus_scan.jl
```

Raw output from the run this report is based on is saved at
`results-raw.txt`.

## Results

```
Files scanned OK: 365 / 365
Total LOC: 272,688
Total loop sites (functions with >=1 while/for): 1,809
Loop-site shape breakdown: single_while=254  has_for=1,469  mixed=66  multi_while=20
Record-shaped candidate positions: 15
Gate-faithful qualification: qualified=0  declined=15  error=0
```

**Headline finding #1, before the record-shape question is even
reached: `for` loops overwhelmingly dominate Julia's own idiomatic
style.** Of 1,809 loop-bearing functions, only 254 (14.0%) are even the
*right loop shape* (`single_while`, no `for`) for `@asr` to consider at
all - 1,469 (81.2%) use `for` exclusively, with a further 86 (4.8%)
mixing `for` with `while` or using multiple `while` loops. This is a
structural, language-level finding distinct from anything the BEAM or
Python studies surfaced (Erlang has no `for`; Python's `while`/`for`
split is far less lopsided) - `for` loops as an alternative loop shape
is already on Julia-asr's own deferred list, but this measures *how
much* of the corpus that gap alone accounts for, before any other
qualification question matters.

**Headline finding #2: even restricted to the 254 in-scope
`single_while` functions, a syntactically record-accumulator-shaped
pre-loop init occurs in only 15 positions (5.9% of in-scope functions,
0.83% of all loop sites) - and all 15 decline, every one for a reason
already documented as a deliberate v1-v1.3 exclusion, not a new gap.**

### Why all 15 decline: two already-documented walls account for 13

Every hit was read directly and re-run against `GateCheck.qualifies`
(never inferred from the tool's own decline message alone) to confirm
the actual cause, following up in each type's own defining module when
the corpus's own module-resolution choice wasn't the right one to
check in:

| Category | Count | Sites | Reason | Status |
|---|---|---|---|---|
| **Parametric struct** | 10 | `RefValue`×3 (`pwd`, `tempdir`, `homedir`), `IOContext`×2 (`point_to_line`), `Ref`×2 (`parse_array`, `unicode.jl::iterate`), `InetAddr`×1 (`Sockets.listenany`), `REPLDisplay`×2 (`REPL.run_frontend`) | `resolve_type` returned a `UnionAll` (e.g. `Base.RefValue{T}`, `Sockets.InetAddr{T<:IPAddr}`), not a `DataType` - `T isa DataType` failed by design (a deliberate v1-v1.3 exclusion). | **Fixed in v1.4** - `try_accumulator_stmt` now unwraps the `UnionAll` first. `RefValue`/`IOContext`/`Ref`/`REPLDisplay` are *also* mutable, so they still correctly decline on that separate wall; `InetAddr` alone clears type resolution, confirmed directly. It then hit the `if`-dispatch wall (also now fixed in v1.5, confirmed directly) - but still declines regardless, for a *third*, distinct reason: `addr` is passed bare into `bind(sock, addr)`, an opaque call the transform can't safely reason about. Three independent walls on one function, each real, each verified, each requiring its own fix. |
| **Mutable struct** | 3 | `IOBuffer`×1 (`REPL.normalize_key`), `TOMLDict`×1 (`= Dict{String,Any}`, `parse_inline_table`), `ParseStream`×1 (`mutable struct ParseStream`, JuliaSyntax) | `ismutabletype(T)` is true - Julia-asr has no mutation mode (`cpython-asr`'s v1.4 analog, unimplemented here). `TOMLDict`/`ParseStream` initially reported "doesn't resolve" because the corpus scan checks types in `Base` directly, not their own vendored submodule (`Base.TOML`, `Base.JuliaSyntax`) - confirmed by direct definition lookup (`TOMLDict = Dict{String,Any}`; `mutable struct ParseStream`) that both land on this same wall once resolved correctly, not a third category. | Unaffected by v1.4 - still correctly declines; unimplemented mutation mode is a separate, structurally bigger feature (see below). |
| **Pass-1 syntactic false positive: method type parameter** | 1 | `T` (`intfuncs.jl::binomial`, `rr = T(2)`) | `T` here is a `where T` method type parameter, not a module-level type binding - `T(2)` is syntactically identical to a type-constructor call, but `Core.eval(Base, :T)` is an `UndefVarError`. A Pass-1 imprecision (no signature-tracking), not a transform finding - mirrors BEAM-asr's own "record_weak is deliberately loose" caveat. | Unaffected by v1.4 - not a real transform limitation. |
| **Genuine non-parametric, non-mutable struct - declines for an unrelated loop-shape reason** | 1 | `SummarySize` (`summarysize.jl::summarysize`) | The one candidate that clears type resolution entirely. `ss = SummarySize(IdDict(), Any[], Int[], exclude, chargeall)` is never reassigned inside the loop - only its own *mutable-array fields* (`ss.frontier_x`, `ss.frontier_i`) are grown/shrunk via `push!`/`pop!` (a DFS/BFS worklist), the same "stateful helper object mutated via its own container fields" idiom found repeatedly among the `record_other`-then-excluded hits below. Declines with `"no candidate accumulator qualified"` - `classify_loop` never finds a reconstruction assignment for `ss` at all. | Unaffected by v1.4 - genuinely not an ASR accumulator loop, no fix applies. |

**13 of 15 (87%) hit one of Julia-asr's own already-documented v1-v1.3
exclusions** (parametric or mutable structs) - this corpus doesn't
surface a new gap so much as it *confirms*, against real code, that
those two documented boundaries are the actual reason a real
record-shaped loop declines when one occurs at all. `Sockets.listenany`
was the cleanest example: a genuine port-retry loop,
`addr = InetAddr(addr.host, addr.port + UInt16(1))` reconstructed once
per attempt - textbook ASR shape. Parametric-struct support (v1.4,
below) has since removed that specific block, but `listenany` still
declines, for the unrelated `classify_loop` if-dispatch reason
described in "What would unlock the most real code."

### The dominant pattern behind the *other* false positives: mutable helper objects, not reconstructed records

Beyond the 15 gate-checked hits, the broader pattern in Julia's own
idiomatic code - visible even before Pass 1's exclusion list was
tightened (an earlier, unfiltered pass found 21 raw hits; 6 were
primitive-type-conversion noise like `UInt64(0)`/`Char(x)` and one more
was a `StringVector`-preallocate-then-index-fill buffer idiom, both now
excluded by name the same way `Dict`/`Vector`/`Set` already were) - is
that Julia code needing loop-carried state overwhelmingly reaches for a
**mutable object whose own fields get mutated via method calls**
(`push!`, indexed assignment, `print`) rather than an **immutable
struct rebuilt via a fresh constructor call each iteration** - `pwd`/
`tempdir`/`homedir`'s `Base.StringVector`-then-`resize!` buffers,
`point_to_line`'s `IOContext`-then-`print` builders, and
`summarysize`'s own `SummarySize` worklist are all instances of the
same idiom. This is the flip side of what BEAM-asr's own study found
(Erlang has no mutation at all, so *every* stateful loop is forced into
ASR's target shape or an equivalent) and is consistent with what
`benchmarks/README.md` already documents about the language itself:
Julia's JIT already eliminates small immutable-struct allocations for
free in a tight loop (13 of 14 synthetic benchmarks measure ~1.0x, not
because ASR's mechanism is wrong but because there's no allocation left
to eliminate) - so idiomatic Julia has correspondingly less pressure to
write the reconstruction-style loop ASR targets in the first place,
independent of whether `@asr` could handle it.

## Honest caveats

- **Exhaustive, not sampled, but still one language's own standard
  library** - 365 files is Julia's entire Base plus a representative
  stdlib slice, not a cross-section of the wider package ecosystem
  (`DataFrames.jl`, `Flux.jl`, `JuMP.jl`, and similar large,
  widely-used packages are not part of this corpus). Base/stdlib code
  is also unusually performance-conscious and mutation-heavy by its own
  house style (it's written by people optimizing the language's own
  primitives) - a broader package corpus, especially domain code
  translated more directly from a functional/immutable style (physics
  simulations, parsers, ASTs), might show a different balance. Treat
  the 0.83%-shaped / 0%-qualifying numbers as this corpus's own honest
  data point, not a claim about "Julia code in general."
- **15 hits is a small enough number that this study reads every one**
  (unlike BEAM-asr/cpython-asr's own sampling of a `record_weak`
  subset) - there's no "lower bound, not measured" caveat needed here.
- **The gate-faithful Pass 2 oracle is exactly the shipped
  `AsrTransform.jl`**, so its own known scope boundaries apply
  unchanged: interprocedural inlining, branch-shaped reconstruction,
  and multi-accumulator qualification are all exercised by the real
  transform during Pass 2 exactly as they'd run in production - a
  candidate declining here is a genuine decline under the current
  shipped rules, not an artifact of a simplified study-only checker.
- **0% qualifying should not be read as "ASR is useless for real Julia
  code"** - `benchmarks/README.md` demonstrates the mechanism itself
  works correctly end-to-end (14/14 synthetic benchmarks correct,
  speedup near 1.0x for the reason above, not because the transform
  failed). This study's finding is about *incidence*, not
  *correctness*: real Julia standard-library code needing loop-carried
  state overwhelmingly reaches for parametric types, mutable objects,
  or `for` loops - shapes `@asr` v1-v1.3 was never targeting - rather
  than the specific immutable-record-rebuilt-via-`while`  pattern the
  transform recognizes.

## Two real, verified fixes - zero net new qualifications, and why that's still a good outcome

**Both parametric-struct support (v1.4) and the `classify_loop`
if-dispatch fix (v1.5) were implemented and independently verified**
against real code, each closing a genuine, previously-undetected gap
(see `README.md`'s Status table). Re-running this exact study after
both still shows **0 of 15 qualifying**, because `Sockets.listenany`
- the one candidate either fix could plausibly have unlocked -
turned out to have not one blocker but three, stacked in the same
function: the parametric type (v1.4), the if-dispatch issue (v1.5),
and now a third, genuinely different one neither fix touches - `addr`
is passed *bare* into `bind(sock, addr)`, an opaque call the transform
has no way to verify is safe (does `bind` retain or alias the
reference it's given?). This mirrors the exact shape of finding from
the BEAM-asr/CGO project's own iterative corpus-study-then-fix cycle:
a fix can be fully correct, independently verified, and still not move
a headline number, because real code routinely stacks more than one
qualification-blocking idiom in the very same function. Both v1.4 and
v1.5 are real progress - confirmed by dedicated positive/negative tests
proving each mechanism works correctly in isolation (`test/runtests.jl`)
- even though *this specific corpus's* own candidates didn't happen to
have only-one-blocker-each.

**The bare-accumulator-into-an-opaque-call shape is now the study's
own highest-leverage remaining target**, and it's a materially harder
one than the previous two: unlike `try_inline_helper`'s existing
one-level inlining (which only ever accepts a helper called with the
accumulator as its *sole* argument, so its own body can be fully
re-validated against the same field-read-only rules), `bind(sock, addr)`
passes the accumulator as *one of several* arguments to a function
whose body isn't even necessarily Julia source the transform could
re-parse (native/ccall-heavy code, in this case) - genuinely requiring
either real interprocedural purity analysis or accepting a soundness
risk, not a shape-recognition loosening like v1.4/v1.5 were. Not
attempted in this session.

Mutable-struct support (Julia-asr's own analog of `cpython-asr`'s v1.4
mutation mode) remains the other real, structurally bigger extension (3
of 15 hits here): unlike reconstruction, which only ever needs to track
the *current* scalar values, in-place mutation requires escape analysis
(does the mutated struct alias anything the transform can't see?) that
this corpus's own hits (`IOBuffer`, `TOMLDict`, `ParseStream`) don't
obviously simplify, since none of them are single-owner, non-escaping
mutation in the way a freshly-constructed local accumulator naturally
is.

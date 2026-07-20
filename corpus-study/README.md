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

**Update (v1.6)**: the third wall was investigated rather than accepted
as final - `bind`'s own `InetAddr` method turns out to be
`bind(sock::TCPServer, addr::InetAddr) = bind(sock, addr.host,
addr.port)`, a one-line destructuring pass-through that only ever reads
`addr`'s fields, so passing the accumulator bare into it is genuinely
safe, just not a shape v1.1's sole-argument-only inlining could ever
recognize. `verify_safe_passthrough_arg` generalizes it: resolve the
callee via multiple dispatch to the single method whose signature
accepts the accumulator's own type at the matching argument position
(not "exactly one method total", the way v1.1's helper inlining works -
`bind` genuinely has several methods across Sockets.jl, PipeServer.jl,
and Base's own channels.jl), then confirm that method's matching
parameter is used only via field reads, one level deep. Getting this to
actually work against real code surfaced two more real,
previously-latent v1.1 bugs, both invisible until tested against actual
stdlib source rather than hand-written test helpers: `Method.file`
reports the *build machine's* own path for anything compiled into a
precompiled sysimage (confirmed for `Sockets.bind`: it pointed at
`C:\workdir\usr\share\julia\...`, a path that doesn't exist on this
machine, even though `Base.find_source_file` - which `functionloc`
itself relies on - didn't fix it either; recovered by locating the
path's own `stdlib/vX.Y/...` suffix and rejoining it onto `Sys.STDLIB`,
which *does* resolve correctly); and a real source file is typically
its own `module X ... end` (`Sockets.jl` itself is `module Sockets
... end`), which the original flat top-level-only helper-source scan
never recursed into at all - so v1.1's interprocedural inlining had
silently found nothing for any module-wrapped helper source since it
first shipped, just never exercised against one until now. Both fixes
apply to v1.1 as much as v1.6. A third bug - `m.sig` is a `UnionAll`,
not a plain `DataType`, for a parametric method (`f(x::Vector{T}) where
T`), and `.parameters` doesn't exist on a `UnionAll` - was caught by
this exact corpus study re-run itself: `toml_parser.jl`'s
`point_to_line` calls a parametric IO-printing method and turned a
clean decline into an uncaught `error`, fixed by unwrapping first (same
discipline as v1.4's own struct-type handling). **With all three walls
addressed, `Sockets.listenany` now qualifies** - confirmed both via the
gate-faithful oracle and by actually running the rewritten function
(including its retry-on-taken-port path, which exercises more than one
loop iteration) side by side with the baseline. **The corpus study now
shows 1 of 15 candidates qualifying.**

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
Gate-faithful qualification: qualified=1  declined=14  error=0
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
0.83% of all loop sites) - 14 of which decline, every one for a reason
already documented as a deliberate v1-v1.3 exclusion, not a new gap,
and one of which (`Sockets.listenany`) now qualifies as of v1.6.**

### Why all 15 decline: two already-documented walls account for 13

Every hit was read directly and re-run against `GateCheck.qualifies`
(never inferred from the tool's own decline message alone) to confirm
the actual cause, following up in each type's own defining module when
the corpus's own module-resolution choice wasn't the right one to
check in:

| Category | Count | Sites | Reason | Status |
|---|---|---|---|---|
| **Parametric struct** | 10 | `RefValue`×3 (`pwd`, `tempdir`, `homedir`), `IOContext`×2 (`point_to_line`), `Ref`×2 (`parse_array`, `unicode.jl::iterate`), `InetAddr`×1 (`Sockets.listenany`), `REPLDisplay`×2 (`REPL.run_frontend`) | `resolve_type` returned a `UnionAll` (e.g. `Base.RefValue{T}`, `Sockets.InetAddr{T<:IPAddr}`), not a `DataType` - `T isa DataType` failed by design (a deliberate v1-v1.3 exclusion). | **Fixed in v1.4** - `try_accumulator_stmt` now unwraps the `UnionAll` first. `RefValue`/`IOContext`/`Ref`/`REPLDisplay` are *also* mutable, so they still correctly decline on that separate wall; `InetAddr` alone clears type resolution, confirmed directly. It then hit the `if`-dispatch wall (fixed in v1.5) and, after that, a third wall - `addr` passed bare into `bind(sock, addr)` - **fixed in v1.6** (`verify_safe_passthrough_arg`). **`Sockets.listenany` now qualifies**, the only one of these 10 to clear all three walls (the other 9 are also mutable, a separate, still-unimplemented wall). |
| **Mutable struct** | 3 | `IOBuffer`×1 (`REPL.normalize_key`), `TOMLDict`×1 (`= Dict{String,Any}`, `parse_inline_table`), `ParseStream`×1 (`mutable struct ParseStream`, JuliaSyntax) | `ismutabletype(T)` is true - Julia-asr has no mutation mode (`cpython-asr`'s v1.4 analog, unimplemented here). `TOMLDict`/`ParseStream` initially reported "doesn't resolve" because the corpus scan checks types in `Base` directly, not their own vendored submodule (`Base.TOML`, `Base.JuliaSyntax`) - confirmed by direct definition lookup (`TOMLDict = Dict{String,Any}`; `mutable struct ParseStream`) that both land on this same wall once resolved correctly, not a third category. | Unaffected by v1.4 - still correctly declines; unimplemented mutation mode is a separate, structurally bigger feature (see below). |
| **Pass-1 syntactic false positive: method type parameter** | 1 | `T` (`intfuncs.jl::binomial`, `rr = T(2)`) | `T` here is a `where T` method type parameter, not a module-level type binding - `T(2)` is syntactically identical to a type-constructor call, but `Core.eval(Base, :T)` is an `UndefVarError`. A Pass-1 imprecision (no signature-tracking), not a transform finding - mirrors BEAM-asr's own "record_weak is deliberately loose" caveat. | Unaffected by v1.4 - not a real transform limitation. |
| **Genuine non-parametric, non-mutable struct - declines for an unrelated loop-shape reason** | 1 | `SummarySize` (`summarysize.jl::summarysize`) | The one candidate that clears type resolution entirely. `ss = SummarySize(IdDict(), Any[], Int[], exclude, chargeall)` is never reassigned inside the loop - only its own *mutable-array fields* (`ss.frontier_x`, `ss.frontier_i`) are grown/shrunk via `push!`/`pop!` (a DFS/BFS worklist), the same "stateful helper object mutated via its own container fields" idiom found repeatedly among the `record_other`-then-excluded hits below. Declines with `"no candidate accumulator qualified"` - `classify_loop` never finds a reconstruction assignment for `ss` at all. | Unaffected by v1.4 - genuinely not an ASR accumulator loop, no fix applies. |

**Of the 14 that still decline, 12 (86%) hit the mutable-struct wall**
(the 9 remaining parametric-and-mutable hits, plus the 3 directly
mutable ones) - Julia-asr's one still-unimplemented v1-v1.3 exclusion;
this corpus doesn't surface a new gap so much as it *confirms*, against
real code, that mutable-struct support (`cpython-asr`'s v1.4 analog) is
the single highest-leverage remaining extension. `Sockets.listenany`
was the cleanest example of the other kind: a genuine port-retry loop,
`addr = InetAddr(addr.host, addr.port + UInt16(1))` reconstructed once
per attempt - textbook ASR shape, immutable, no mutation-mode dependency
at all. It took three separate fixes (v1.4 parametric structs, v1.5
if-dispatch, v1.6 opaque-call passthrough) to actually clear it, and it
now qualifies - the corpus study's first genuinely qualifying real-world
file, and direct confirmation that the mechanism really does transfer to
real code, not just synthetic benchmarks.

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
  the 0.83%-shaped / 1-of-15-qualifying numbers as this corpus's own
  honest data point, not a claim about "Julia code in general."
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
- **1-of-15 qualifying should not be read as "ASR barely applies to
  real Julia code"** - `benchmarks/README.md` demonstrates the
  mechanism itself works correctly end-to-end (14/14 synthetic
  benchmarks correct, speedup near 1.0x for the reason above, not
  because the transform failed), and `Sockets.listenany` demonstrates
  it working correctly on real, unmodified stdlib source, retry loop
  and all. This study's finding is still mostly about *incidence*, not
  *correctness*: real Julia standard-library code needing loop-carried
  state overwhelmingly reaches for mutable objects or `for` loops -
  shapes `@asr` doesn't target at all - rather than the specific
  immutable-record-rebuilt-via-`while` pattern the transform
  recognizes; but where that shape genuinely occurs, v1.4-v1.6 show the
  transform can be pushed, with real (not speculative) fixes, all the
  way to actually handling it.

## Three real, verified fixes - one net new qualification, and the trail that got there

**Parametric-struct support (v1.4) and the `classify_loop` if-dispatch
fix (v1.5) were each implemented and independently verified** against
real code, each closing a genuine, previously-undetected gap (see
`README.md`'s Status table) - yet re-running this exact study after
both still showed **0 of 15 qualifying**, because `Sockets.listenany`
turned out to have not one blocker but three, stacked in the same
function: the parametric type (v1.4), the if-dispatch issue (v1.5),
and a third - `addr` passed *bare* into `bind(sock, addr)` - that
neither fix touched. This mirrored the exact shape of finding from the
BEAM-asr/CGO project's own iterative corpus-study-then-fix cycle: a fix
can be fully correct, independently verified, and still not move a
headline number, because real code routinely stacks more than one
qualification-blocking idiom in the very same function.

**Rather than stopping there, the third blocker was investigated
directly**: is passing `addr` bare into `bind` actually unsafe, or just
unrecognized? Reading `bind`'s own `InetAddr` method answered it -
`bind(sock::TCPServer, addr::InetAddr) = bind(sock, addr.host,
addr.port)` is a one-line destructuring pass-through that only ever
reads `addr`'s fields, so it's genuinely safe, just a shape v1.1's
sole-argument-only interprocedural inlining could never recognize.
**v1.6 (`verify_safe_passthrough_arg`) generalizes it**: resolve the
callee via multiple dispatch to the single method whose signature
accepts the accumulator's own type at the matching argument position
(not "exactly one method total" - `bind` has several, across three
different files), then confirm that method's matching parameter is used
only via field reads, one level deep, same discipline as v1.1's
existing inlining.

Actually making this work against real code surfaced two more real,
previously-latent **v1.1** bugs (not v1.6-only), both invisible until
tested against real stdlib source rather than hand-written test
helpers: `Method.file` reports the *build machine's* own path for
anything compiled into a precompiled sysimage - `C:\workdir\usr\share\...`
for `Sockets.bind` on this machine, a path that doesn't exist here, and
`Base.find_source_file` (which `functionloc` itself uses) didn't fix it
either; recovered by locating the path's own `stdlib/vX.Y/...` suffix
and rejoining it onto `Sys.STDLIB`, which does resolve correctly. And a
real source file is typically its own `module X ... end` - `Sockets.jl`
is `module Sockets ... end` - which the original flat, top-level-only
helper-source scan never recursed into at all, meaning v1.1's
interprocedural inlining had silently found nothing for any
module-wrapped helper since it first shipped, never exercised against
one until now. A third bug, caught by this exact corpus re-run: `m.sig`
is a `UnionAll`, not a plain `DataType`, for a parametric method
(`f(x::Vector{T}) where T`) - `toml_parser.jl`'s `point_to_line` calls
one and turned a clean decline into an uncaught `error`, fixed by
unwrapping first (same discipline as v1.4's own struct-type handling).

**With all three walls addressed, `Sockets.listenany` now qualifies** -
confirmed via the gate-faithful oracle, dedicated positive/negative
tests (`test/runtests.jl`), and by actually running the rewritten
function (including its retry-on-taken-port path, exercising more than
one loop iteration) side by side with the baseline. This is the
corpus's first genuinely qualifying real-world file, and direct,
end-to-end confirmation - not just synthetic-benchmark confirmation -
that the ASR mechanism transfers to real Julia code when its target
shape genuinely occurs.

Mutable-struct support (Julia-asr's own analog of `cpython-asr`'s v1.4
mutation mode) remains the other real, structurally bigger extension
(3 of the 14 still-declining hits here): unlike reconstruction, which
only ever needs to track the *current* scalar values, in-place mutation
requires escape analysis (does the mutated struct alias anything the
transform can't see?) that this corpus's own hits (`IOBuffer`,
`TOMLDict`, `ParseStream`) don't obviously simplify, since none of them
are single-owner, non-escaping mutation in the way a freshly-constructed
local accumulator naturally is. Not attempted in this session.

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
drift from the actual v1–v1.7 rules.

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

**Update (v1.7)**: a fundamentally different question than v1.4-v1.6's
narrow shape-recognition fixes - not "is this specific blocked case
actually safe," but "how much of the corpus was never even LOOKED at."
Pass 1's own record-accumulator scan (`classify_candidates`) had only
ever been wired up for `:single_while` sites; for every other shape
(`:has_for`, `:multi_while`, `:mixed` - 86% of the corpus's 1,809
loop-bearing functions) `candidates` was a hardcoded empty list, because
`@asr` only ever accepted `while` loops. Given the study's own headline
finding #1 (81% of all loop sites are `for`-shaped, only 14% are the
`while`-only shape `@asr` could even consider), this meant the vast
majority of Julia's own idiomatic loop-carried-state code had never
been checked for this shape at all - not declined, never scanned.
Extending Pass 1 to also scan `:single_for` sites (a `for`-loop analog
of `:single_while` - exactly one `for` loop, at the top level, nothing
else loop-shaped in the function) cost nothing extra, since
`classify_candidates` only ever looks at `pre_stmts`/`loop_stmts`, never
the loop header: **260 record-shaped candidates, up from 15** (245 new,
all in `for`-loop bodies). Two of those 245 turned out to be more Pass-1
false positives, same category as before - `BlasInt` (a LinearAlgebra
type ALIAS for `Int64`/`Int32`, `isstructtype(BlasInt) == false`, not a
struct at all) and `Matrix` (a Base collection type, same category as
the already-excluded `Vector`/`Array`) together accounted for 100 of the
245, both now excluded the same way `T`/`UInt64` were before, bringing
the honest count to **160 total candidates**.

`AsrTransform.jl` itself then gained real `for`-loop support
(`locate_loop` - see `README.md`'s Status table): `while`'s `cond` and
`for`'s `iterexpr` are treated identically (field-read-only checked,
substituted, spliced back into whichever loop head shape it came from),
and every OTHER mechanism - branch-shaped reconstruction, inlining,
opaque-call passthrough, multi-accumulator - needed zero code changes,
since none of them ever look at the loop header, confirmed by a
dedicated test composing v1.2's branch-shaped reconstruction inside a
`for` loop. One genuinely new hazard `while` never has: a `for`-loop's
own iteration variable can shadow the accumulator's name (`for p in
items` where `p` is also the accumulator) - declined per-candidate
rather than risk misattributing loop-variable references as accumulator
ones.

**Re-running the corpus study with real qualification (not just Pass-1
scanning) still shows only 1 of 160 candidates qualifying** -
`Sockets.listenany`, unaffected, since it was already `:single_while`.
This is not a null result in the uninteresting sense: it's the SAME
dominant real-code pattern found in the `while` set (mutable/
reference-semantics helper objects, not reconstructed records)
recurring at much larger scale in the `for` set, now with real numbers
behind it rather than an inference from 15 examples. `Ref`/`RefValue`
alone account for 102 of 130 "no candidate accumulator found in
pre-loop statements" declines - and `Ref` is a structurally different,
even MORE fundamental mismatch than "mutable struct": `Ref` is an
ABSTRACT type (`isabstracttype(Ref) == true`), so `try_accumulator_stmt`
never even gets past `isstructtype` - and its mutation idiom is
`x[] = ...`/`x[] += ...` (`getindex`/`setindex!`), not `.field = ...`,
so mutable-struct support (the other deferred extension) wouldn't
directly cover it either. The remaining declines are the same
categories already documented below (`IOBuffer`/`IOContext` print
builders, a handful more Pass-1 false positives like `T`/`Expr`/
`SSAValue` from macro-heavy compiler-internals code, and 20 cases where
`GateCheck`'s simple name-based function lookup found a different
same-named method than Pass 1 scanned).

**Would multi-loop support help?** A cheap Pass-1-only extension
(`scan_all_top_level_loops`, exploratory - `AsrTransform` has no
multi-loop qualification path, so every candidate found this way still
declines at Pass 2) scanned the remaining `multi_while`/`has_for`/
`mixed` bucket (858 functions, never checked before) and found 87 more
raw candidates - dominated by `Ref` again (106, much the same
population re-counted across multiple loop positions, an acknowledged
overlap in this approximate scan) plus, new this time, Julia's own
compiler-internals mutable IR types (`CFG`, `IncrementalCompact`,
`BitSetBoundedMinPrioritySet`). Sampling these directly
(`compiler/ssair/ir.jl :: complete`'s `cfg::CFG`) confirmed the exact
same pattern: genuinely mutable, inherently graph-like data structures
that need real reference semantics for the algorithm's own correctness,
not reconstructed records. **Conclusion: multi-loop support would not
meaningfully help** - the wall is the same wall, at similar scale, not
a structurally different population. Not built.

**Would mutable-struct field-mutation mode help?** (`p.field = expr`,
`cpython-asr`'s v1.4 analog - the feature most naturally suggested by
"12 of 14 declining `while` candidates are mutable structs.") Checked
directly before implementing, not assumed: 7 real declining candidates
were read at the source level across every domain sampled (Base arrays,
Base compiler internals, REPL, JuliaSyntax, LinearAlgebra) -
`normalize_key`'s `IOBuffer` (mutated via `write(buf, c)`/`take!(buf)`),
`tokenize`'s `ParseStream` (mutated via `parse!(ps, ...)`),
`gebrd!`'s `Ref{BlasInt}` (mutated via a ccall out-parameter,
genuinely un-eliminable - native code writes through the raw pointer),
`map_n!`'s `LinearIndices` and `_show_nd`'s `CartesianIndices` (not
accumulators at all - Pass-1 false positives, used only as the loop's
OWN iteration source, never touched inside the body), and
`count_const_size`'s `DataTypeFieldDesc` (a read-only lookup table,
same story). **7 of 7: zero used bare `p.field = expr` anywhere.**
Idiomatic Julia mutates through the type's own API methods almost
universally, not direct field assignment - a genuine, if unexpected,
cultural difference from `cpython-asr`'s own `self.x = expr` target
(Python's non-frozen-dataclass idiom, which DOES commonly write fields
directly). **Conclusion: mutable-struct field-mutation mode, as
classically scoped, would very likely have near-zero yield in this
corpus.** Not built; the evidence pointed toward a different, larger
extension instead (below).

**Update (v1.8)**: given `IOBuffer`/`ParseStream`/`Ref` are all mutated
through opaque STDLIB METHOD calls rather than direct field assignment,
the natural question became whether v1.6's own opaque-call-passthrough
check (`verify_safe_passthrough_arg`) could be generalized to reach
through such calls - it was already capable of proving a callee safe
when its body is field-*read*-only, just hard-capped at exactly one
level deep. FOL's own project has real prior art for exactly this kind
of generalization: an interprocedural summary-inference system built
for its PLDI 2027 escape-analysis paper
(`../../FOL/fol/docs/escape-analysis-design.md`,
`../../FOL/fol/src/summary-inference.lisp`) that infers each function's
own effect on its parameters from its body (not hand-annotated),
memoized over a call graph with cycle handling via fixpoint iteration.
`cpython-asr` has no equivalent (its own interprocedural reach stops at
v1.1-style single-method inlining, same ceiling Julia-asr had before
this). v1.8 is a narrow port of that idea: `check_method_param_safe`
recurses to arbitrary depth (bounded by `MAX_PASSTHROUGH_DEPTH`),
memoizing each `(Method, position)` result in a `cache` threaded
through `check_only_field_reads`, with a `:computing` sentinel making a
cyclic call chain resolve to "unsafe" rather than looping forever.
Confirmed working via a dedicated test (a genuine two-level
pass-through chain, declined under v1.6's cap, now qualifies - verified
STRUCTURALLY, not just by output equality, since "declined and fell
back to the unchanged original" would trivially also pass an
equality-only check) and a cyclic chain correctly declining.

**Re-running the corpus study found zero additional qualifying
candidates - the honest, expected result, not a surprise.** This was
scoped correctly going in: `IOBuffer`/`ParseStream`/`Ref` need
MUTATION-awareness (does this call write into the object, and does
that observably escape?), not more DEPTH on an already-supported
read-only shape - v1.8 generalized the wrong axis for these specific
candidates, by design, since building mutation-aware summaries is a
materially larger undertaking than depth-generalizing a read-only
check, and this session scoped v1.8 to the smaller, well-understood
piece rather than attempt the larger one speculatively. The
depth-generalization itself is real, tested, shipped capability - it
simply doesn't happen to be what this corpus's own remaining candidates
need.

**Update (v1.9)**: mutation-awareness itself - the extension v1.8's own
update explicitly named and deferred - was built next.
`try_accumulator_stmt` no longer rejects mutable structs;
`classify_loop_mutable` recognizes direct field mutation (`p.x =
expr`/`p.x += expr`, at the loop body's own top level -
`cpython-asr`'s v1.4 analog) as an alternative to whole-object
reconstruction. Building it surfaced a real, previously-LATENT
soundness gap in `check_only_field_reads`, dormant since v1.6 only
because mutable types were categorically unreachable before now:
`is_field_read`'s shape match (`Expr(:., varname, QuoteNode(f))`)
doesn't distinguish read from write context, so a callee that
genuinely MUTATES a field could have been wrongly verified "safe
read-only" by `verify_safe_passthrough_arg` - whose rewrite re-boxes a
fresh, throwaway copy and discards it after the call, which would have
silently dropped any real mutation. Closed by having
`check_only_field_reads` explicitly reject any field-write shape it
wasn't specifically asked to tolerate; `classify_loop_mutable` is the
only place that positively recognizes one, and only at the loop's own
top level, never through an opaque-call passthrough (v1.9 deliberately
does not attempt mutation-aware INTERPROCEDURAL summaries - that
remains the larger, not-yet-attempted extension). No separate
escape-analysis pass was needed to make mutation itself sound: the
"decline on any untracked bare occurrence" discipline already in place
since v1 already guarantees the accumulator never aliases anywhere
unverified.

**Investigated before implementing, not assumed - and confirmed twice,
independently.** The same 7 real declining candidates sampled to
answer "would mutable-struct support help" (see below) were checked
again for this question: zero of them use direct field mutation
anywhere. Re-running the corpus study with real mutation-mode
qualification found **zero additional qualifying candidates** - and,
independently, Pass 1's OWN `record_mutate` candidate kind (a
mutation-shaped pre-loop init, distinct from `record_strong`/
`record_weak`'s reconstruction shape - see the analyzer table below)
has **zero hits across the entire 272,688-LOC corpus**, a second,
completely independent confirmation from the opposite direction (a
syntactic scan, not a targeted sample) of the same finding. v1.9 is
real, sound, fully tested capability - not dead code - it simply isn't
what this specific corpus's own remaining candidates need, for the
exact reason predicted before it was built.

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
Loop-site shape breakdown: single_while=254  single_for=697  has_for=772  mixed=66  multi_while=20
Record-shaped candidate positions: 247
Gate-faithful qualification: qualified=1  declined=246  error=0
```

(247 = 160 from `single_while`/`single_for`, the two shapes Pass 1 does
a full field-shape scan for, plus 87 more from a separate, cheaper,
exploratory-only scan of the remaining `multi_while`/`has_for`/`mixed`
bucket - see "Would multi-loop support help?" below. `AsrTransform`
itself has no multi-loop qualification path, so those 87 all decline
at Pass 2 regardless of what v1.4-v1.9 built.)

**Headline finding #1, before the record-shape question is even
reached: `for` loops overwhelmingly dominate Julia's own idiomatic
style.** Of 1,809 loop-bearing functions, only 254 (14.0%) are the
*right loop shape for `while`-only ASR* (`single_while`) - but 697
(38.5%) are the `for`-loop analog (`single_for`, exactly one top-level
`for`, nothing else loop-shaped), with a further 772 (42.7%) using
`for` in a more complex shape (nested, multiple, or mixed with `while`)
and 86 (4.8%) mixed/multi-`while`. `single_while + single_for` together
- 951 functions, 52.6% of the corpus - is the realistic ASR-addressable
ceiling as of v1.7; the remaining 858 (`has_for`'s complex cases plus
`mixed`/`multi_while`) are out of scope for a different, structural
reason (more than one loop, unclear which owns the accumulator) than
"wrong loop keyword," and remain deferred.

**Headline finding #2: restricted to the 951 in-scope `single_while`/
`single_for` functions, a syntactically record-accumulator-shaped
pre-loop init occurs in 160 positions (16.8% of in-scope functions,
8.8% of all loop sites) - 159 of which decline, and one of which
(`Sockets.listenany`) qualifies. The overwhelming majority of the 159
(130, dominated by `Ref`/`RefValue` at 102) hit the same real-code
pattern already documented for the `while`-only set: Julia code needing
loop-carried state overwhelmingly reaches for a mutable or
reference-semantics helper object, not a record rebuilt via a fresh
constructor call each iteration - now confirmed at 10x the original
sample size, not just inferred from 15 examples.**

### Why the original 15 (`single_while` only) decline: two already-documented walls account for 13

The table below is the original, hand-audited `single_while`-only set
(15 candidates, pre-v1.7) - every hit read directly and re-run against
`GateCheck.qualifies` (never inferred from the tool's own decline
message alone), following up in each type's own defining module when
the corpus's own module-resolution choice wasn't the right one to check
in. The 245 additional `for`-loop candidates v1.7 found are NOT
individually tabulated here (160 total candidates is too many for the
same one-by-one hand audit) - see the "Update (v1.7)" section above for
their own characterization by type-name frequency instead, which shows
the same two dominant categories (`Ref`-style reference-semantics
objects, structurally distinct from "mutable struct" but the same
underlying "not a reconstructed record" story) at much larger scale:

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
  the 8.8%-shaped / 1-of-160-qualifying numbers as this corpus's own
  honest data point, not a claim about "Julia code in general."
- **The original 15 `single_while` hits were each read by hand; the
  245 additional `for`-loop hits (v1.7) were characterized by type-name
  frequency instead** - 160 is too many for the same one-by-one audit
  the original 15 got. The categorization is still grounded (every
  frequency count comes from the real Pass-2 oracle's own output, and
  the dominant `Ref`/`BlasInt`/`Matrix` categories were each verified
  directly - `isabstracttype(Ref)`, `isstructtype(BlasInt)`, etc. - not
  just inferred from the type name), but is coarser than the original
  table.
- **The gate-faithful Pass 2 oracle is exactly the shipped
  `AsrTransform.jl`**, so its own known scope boundaries apply
  unchanged: interprocedural inlining, branch-shaped reconstruction,
  and multi-accumulator qualification are all exercised by the real
  transform during Pass 2 exactly as they'd run in production - a
  candidate declining here is a genuine decline under the current
  shipped rules, not an artifact of a simplified study-only checker.
- **1-of-247 qualifying should not be read as "ASR barely applies to
  real Julia code"** - `benchmarks/README.md` demonstrates the
  mechanism itself works correctly end-to-end (14/14 synthetic
  benchmarks correct, speedup near 1.0x for the reason above, not
  because the transform failed), and `Sockets.listenany` demonstrates
  it working correctly on real, unmodified stdlib source, retry loop
  and all. This study's finding is still mostly about *incidence*, not
  *correctness*: real Julia standard-library code needing loop-carried
  state overwhelmingly reaches for mutable, reference-semantics objects
  mutated through opaque method calls - shapes `@asr` doesn't target at
  all (confirmed directly, not inferred, across every domain sampled)
  - rather than the specific immutable-record-rebuilt-via-loop pattern
  the transform recognizes; but where that shape genuinely occurs,
  v1.4-v1.9 show the transform can be pushed, with real (not
  speculative) fixes, all the way to actually handling it.

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

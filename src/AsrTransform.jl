"""
Aggregate Scalar Replacement for Julia.

Per-function macro: `@asr function ... end`.

Given a `while` or `for` loop that threads one or more immutable struct
accumulators through its own back-edge (each rebound every iteration via
a positional constructor call, full or partial, directly or through a
one-level-inlinable helper, or across an if/elseif/else branch tree),
splits each accumulator into one scalar local per field, re-boxing only
where a bare accumulator reference survives after the loop. v1.1 adds
interprocedural inlining (`try_inline_helper`); v1.2 adds branch-shaped
reconstruction (`classify_branch_tree` - unlike BEAM-asr's clause
dispatch, this needed genuine new code, since a `while` loop has only
one body block); v1.3 adds multi-accumulator support
(`find_and_classify_accumulators`, `subst_all`); v1.4 adds parametric
struct support (`try_accumulator_stmt` unwraps a `UnionAll` via
`Base.unwrap_unionall` before checking `isstructtype`/`ismutabletype`/
`fieldnames` - field shape is fixed by the struct's own declaration,
never by which concrete type parameter a given call instantiates, so
this needs no other change: `typename` stays a bare Symbol everywhere
else, and the reconstruction call this transform emits is the exact
syntactic shape the original code already used, letting Julia's own
type-parameter inference resolve it identically either way). Found by
the corpus study (`corpus-study/README.md`) to be the single
highest-leverage exclusion in real code - `Sockets.listenany`'s
`InetAddr{T<:IPAddr}` retry loop is the corpus's cleanest example,
though it still declined (at the time) for an unrelated, second reason:
its loop body's first statement is an `if` with no terminal `else` (an
early-return guard clause, not an attempted reconstruction of the
accumulator at all), and `classify_loop` dispatched to
`classify_branch_tree` for *any* top-level `if` unconditionally,
without first checking whether its leaves reference the accumulator's
own reconstruction shape. v1.5 fixes exactly this
(`if_tree_attempts_reconstruction` - a non-throwing pre-check: only
commit to `classify_branch_tree`'s own strict validation, mandatory
terminal else included, when at least one leaf's last statement
actually looks like `varname = ...(...)`; otherwise fall through to the
same generic `check_only_field_reads` safety check any other ordinary
statement gets). Verified against real code both ways: an unrelated
guard clause that doesn't touch the accumulator no longer blocks a
later genuine reconstruction, but one that passes the accumulator bare
into an opaque call still correctly declines - `Sockets.listenany`
itself does exactly this (`bind(sock, addr)`), so it still declines
post-v1.5 too, now for that true reason ("bare accumulator reference
outside a field read") rather than the previous false one. v1.6 closes
this third and final gap (`verify_safe_passthrough_arg`): `bind`'s own
`InetAddr` method - `bind(sock::TCPServer, addr::InetAddr) =
bind(sock, addr.host, addr.port)` - is itself a one-line destructuring
pass-through that only ever reads `addr`'s fields, so passing the
accumulator bare into it is genuinely safe, just not something
`try_inline_helper`'s `helper(varname)`-shaped SOLE-argument inlining
(v1.1) could recognize. `verify_safe_passthrough_arg` generalizes this:
resolves the callee via multiple dispatch to the single method whose
signature accepts the accumulator's own declared type at the matching
argument position (not `length(methods(f)) == 1`, since a stdlib
function like `bind` genuinely has many methods), recovers that
method's source (long- or short-form), and confirms its own matching
parameter is used only via field reads throughout the entire method
body - one level deep, no second level of pass-through allowed, same
discipline as v1.1's own interprocedural inlining. The rewrite phase
(`subst_field_reads`) mirrors this: a bare accumulator surviving as a
call argument this far can only be a verified-safe pass-through (by
construction - anything else would have declined at qualification), so
it's re-boxed in place (`rebox_call`) rather than left dangling.
Finding and fixing this surfaced two more, genuinely pre-existing bugs,
both invisible until tested against real stdlib source rather than
hand-written test helpers: `Method.file` reports the BUILD machine's
own path for anything compiled into a precompiled sysimage, not this
install's real location (`resolve_source_file` - also fixes v1.1's own
identical, previously-latent bug); and a real source file is typically
its own `module X ... end`, which the original flat top-level-only
`find_function_def` (v1.1) never recursed into at all
(`find_all_function_defs!` - likewise fixes v1.1, not just v1.6). With
all three gaps closed, `Sockets.listenany` is the corpus study's first
genuinely qualifying real-world file (`corpus-study/README.md`).

v1.7 adds `for`-loop support (`locate_loop`): the corpus study found
245 real record-shaped candidates blocked purely by the "no `for`
loops" restriction once Pass 1 was extended to actually scan `for`-loop
bodies (previously it only ever populated candidates for `:single_while`
sites - 86% of all loop-bearing functions in the corpus were never even
checked). `locate_loop` generalizes loop detection to accept either
kind, treating `for`'s `iterexpr` (evaluated once, at loop entry) the
same way `while`'s `cond` always was (field-read-only checked,
substituted, spliced back into whichever loop head shape it came from)
- `classify_loop`/`classify_branch_tree`/`try_inline_helper`/
`verify_safe_passthrough_arg` needed NO changes at all, since none of
them ever look at the loop header, only `loop_stmts` (confirmed by a
dedicated test: branch-shaped reconstruction, v1.2, composes correctly
inside a `for` loop with zero code changes to that mechanism). One new
hazard `while` never has: a `for`-loop's own iteration variable can
shadow the accumulator's name (`for p in items` where `p` is also the
accumulator) - `find_and_classify_accumulators` declines just that one
candidate rather than risk misattributing loop-variable references as
accumulator references. Re-running the corpus study with real `for`-loop
qualification (not just Pass-1 scanning) still shows only 1 of 160
candidates qualifying (`listenany`, unaffected) - the same dominant
real-code pattern that blocks most `while`-shaped candidates
(mutable/reference-semantics objects, not reconstructed records) turns
out to dominate `for`-shaped ones even more heavily: `Ref`/`RefValue`
alone account for 102 of the 130 "no candidate found" declines, and
`Ref` is a structurally different, even more fundamental mismatch than
"mutable struct" - it's an ABSTRACT type (`isabstracttype(Ref) ==
true`), not a concrete struct at all, and it mutates via `x[] = ...`
(`getindex`/`setindex!`), not `.field = ...`, so mutable-struct support
alone wouldn't cover it either. See `corpus-study/README.md` for the
full breakdown.

See Julia-asr design notes for the full qualification/rewrite spec
this module implements.

No world-guard mechanism is needed (unlike FOL and cpython-asr): Julia
raises a hard compile-time error on redefining a struct's field layout in
the same plain session, so already-compiled code can never observe a
stale layout. This has only been verified for direct top-level/script
redefinition; Revise.jl-mediated redefinition during interactive
development is a separate, not-yet-checked case.
"""
module AsrTransform

export @asr

struct AsrDecline <: Exception
    msg::String
end

macro asr(funcdef)
    new_funcdef = try
        rewrite_function(funcdef, __module__)
    catch e
        e isa AsrDecline || rethrow()
        funcdef
    end
    return esc(new_funcdef)
end

# -----------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------

"""Locates the function's single top-level loop - `while` (v1) or `for`
(v1.7) - and splits it into `(loop_kind, loopvar, header, loop_stmts,
pre_stmts, post_stmts)`. `header` plays the same role for both kinds:
`while`'s `cond` (checked/substituted every iteration in the ORIGINAL
semantics) or `for`'s `iterexpr` (evaluated once, at loop entry) - this
transform treats both identically downstream (field-read-only checked,
substituted the same way, spliced back into whichever loop head shape
it came from), since neither one is what drives reconstruction; only
`loop_stmts` is. `loopvar` is `nothing` for `while`.

v1.7 scope: only a single-iterable `for var in iterexpr` header
qualifies (`Expr(:(=), var::Symbol, iterexpr)`) - a multi-iterator `for
i in a, j in b` parses to a `:block` header instead and declines
cleanly, same "start simple" discipline as every other shape restriction
in this module."""
function locate_loop(stmts)
    loop_idxs = findall(s -> Meta.isexpr(s, :while) || Meta.isexpr(s, :for), stmts)
    length(loop_idxs) == 1 || throw(AsrDecline("expected exactly one top-level while/for loop"))
    loop_idx = loop_idxs[1]
    pre_stmts = stmts[1:loop_idx-1]
    loop_expr = stmts[loop_idx]
    post_stmts = stmts[loop_idx+1:end]

    length(loop_expr.args) == 2 || throw(AsrDecline("unexpected loop expr shape"))
    if loop_expr.head === :while
        cond, loopbody = loop_expr.args
        loop_kind, loopvar, header = :while, nothing, cond
    else
        for_header, loopbody = loop_expr.args
        (Meta.isexpr(for_header, :(=)) && length(for_header.args) == 2) ||
            throw(AsrDecline("unsupported for-loop header shape"))
        loopvar, iterexpr = for_header.args
        loopvar isa Symbol || throw(AsrDecline("for-loop variable is not a plain symbol"))
        loop_kind, header = :for, iterexpr
    end
    Meta.isexpr(loopbody, :block) || throw(AsrDecline("loop body is not a block"))
    loop_stmts = strip_linenums(loopbody.args)

    return (loop_kind=loop_kind, loopvar=loopvar, header=header, loop_stmts=loop_stmts,
            pre_stmts=pre_stmts, post_stmts=post_stmts)
end

function rewrite_function(funcdef, mod::Module)
    Meta.isexpr(funcdef, :function) || throw(AsrDecline("not a long-form function definition"))
    length(funcdef.args) == 2 || throw(AsrDecline("unexpected function expr shape"))
    sig, body = funcdef.args
    Meta.isexpr(body, :block) || throw(AsrDecline("function body is not a block"))

    stmts = strip_linenums(body.args)
    loc = locate_loop(stmts)
    pre_stmts, header, loop_stmts, post_stmts = loc.pre_stmts, loc.header, loc.loop_stmts, loc.post_stmts

    accum_plans = find_and_classify_accumulators(pre_stmts, header, loop_stmts, post_stmts, mod, loc.loop_kind, loc.loopvar)
    check_collisions_multi(pre_stmts, header, loop_stmts, post_stmts, accum_plans, loc.loopvar)
    subs = [(ap.varname, ap.scalar_names, ap.typename, ap.fields) for ap in accum_plans]

    new_pre = rewrite_pre_multi(pre_stmts, accum_plans)
    new_header = subst_all(header, subs)
    new_loop_stmts = rewrite_loop_stmts_multi(loop_stmts, accum_plans, subs)
    new_post = rewrite_post_multi(post_stmts, accum_plans, subs)

    new_loop = if loc.loop_kind === :while
        Expr(:while, new_header, Expr(:block, new_loop_stmts...))
    else
        Expr(:for, Expr(:(=), loc.loopvar, new_header), Expr(:block, new_loop_stmts...))
    end
    new_body = Expr(:block, new_pre..., new_loop, new_post...)
    return Expr(:function, sig, new_body)
end

"""Finds every candidate accumulator among the pre-loop statements and
qualifies each one fully INDEPENDENTLY (each accumulator's own
`classify_loop`/`classify_post` only cares about its own variable name -
a statement that reconstructs a DIFFERENT accumulator, or reads a
DIFFERENT accumulator's fields, simply doesn't mention this one at all,
so it's tolerated for free without any special-casing). One qualifying
accumulator is the ordinary single-accumulator case (v1); more than one
is multi-accumulator (v1.3, e.g. a Kalman filter's coupled state and
covariance, or two accumulators of the same type reading each other's
old values every step). v1.7: `loop_kind`/`loopvar` let a `for`-loop
candidate whose own iteration variable shadows it (`for p in items`
where `p` is also the accumulator's own name - a real hazard `while`
never has, since `while` introduces no new binding at all) decline
just that ONE candidate, the same way any other per-candidate
`classify_loop` failure does, rather than crashing on the ambiguity or
silently misattributing loop-variable references as accumulator
references."""
function find_and_classify_accumulators(pre_stmts, header, loop_stmts, post_stmts, mod::Module,
                                          loop_kind::Symbol, loopvar)
    candidates = Any[]
    for s in pre_stmts
        acc = try_accumulator_stmt(s, mod)
        acc !== nothing && push!(candidates, acc)
    end
    isempty(candidates) && throw(AsrDecline("no candidate accumulator found in pre-loop statements"))

    plans = Any[]
    for (varname, typename, fields) in candidates
        plan = try
            loop_kind === :for && loopvar === varname &&
                throw(AsrDecline("accumulator name shadowed by the for-loop's own iteration variable"))
            recon = classify_loop(header, loop_stmts, varname, typename, fields, mod)
            classify_post(post_stmts, varname, fields, typename, mod)
            scalar_names = Dict(f => scalar_name(varname, f) for f in fields)
            tmp_names = Dict(f => tmp_name(varname, f) for f in fields)
            int_names = Set{Symbol}()
            if recon.kind === :inline
                union!(int_names, recon.int_names)
            elseif recon.kind === :branch
                collect_inline_int_names!(int_names, recon.tree)
            end
            inline_gensym_names = Dict(nm => gensym_name(varname, nm) for nm in int_names)
            (varname=varname, typename=typename, fields=fields, recon=recon, scalar_names=scalar_names,
             tmp_names=tmp_names, inline_gensym_names=inline_gensym_names)
        catch e
            e isa AsrDecline || rethrow()
            nothing
        end
        plan !== nothing && push!(plans, plan)
    end
    isempty(plans) && throw(AsrDecline("no candidate accumulator qualified"))
    return plans
end

strip_linenums(exprs) = [e for e in exprs if !(e isa LineNumberNode)]

# -----------------------------------------------------------------------
# Phase 1: qualification
# -----------------------------------------------------------------------

"""Returns `(varname, typename, fields)` if `s` is `varname =
TypeName(args...)` where TypeName resolves to a defined immutable
struct (parametric or not) whose field count matches the (purely
positional) constructor call, else `nothing`.

v1.4: a parametric struct (`resolve_type` returns a `UnionAll`, e.g.
`InetAddr{T<:IPAddr}`) is unwrapped via `Base.unwrap_unionall` before
checking `isstructtype`/`ismutabletype`/`fieldnames` - field names and
count are fixed by the struct's own declaration, never by which
concrete type parameter a given call instantiates, so this is safe for
any instantiation without knowing which one applies. `typename` itself
stays a bare Symbol throughout the rest of this module (qualification
and rewrite alike) - the reconstruction call this transform emits is
the exact same syntactic shape (`TypeName(scalar1, scalar2, ...)`) the
original code already used, and Julia's own type-parameter inference
from argument types resolves it identically either way; nothing here
ever needs the concrete instantiated type itself, only its field
shape. Confirmed against real code: `Sockets.listenany`'s
`InetAddr(addr.host, addr.port + 1)` retry loop, found by the corpus
study (`corpus-study/README.md`) as the corpus's one clean
`record_strong` example, blocked on exactly this check before this
fix."""
function try_accumulator_stmt(s, mod::Module)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    (lhs isa Symbol && Meta.isexpr(rhs, :call)) || return nothing
    callargs = rhs.args
    typename = callargs[1]
    typename isa Symbol || return nothing
    ctor_args = callargs[2:end]
    any(a -> Meta.isexpr(a, :kw) || Meta.isexpr(a, :...) || Meta.isexpr(a, :parameters), ctor_args) && return nothing
    T = resolve_type(mod, typename)
    T === nothing && return nothing
    T_body = T isa UnionAll ? Base.unwrap_unionall(T) : T
    (T_body isa DataType && isstructtype(T_body) && !ismutabletype(T_body)) || return nothing
    fields = collect(fieldnames(T_body))
    length(ctor_args) == length(fields) || return nothing
    return (lhs, typename, fields)
end

function resolve_type(mod::Module, typename::Symbol)
    try
        Core.eval(mod, typename)
    catch
        nothing
    end
end

"""Walks the loop's header expression (`while`'s `cond`, checked every
iteration in the ORIGINAL semantics, or `for`'s `iterexpr`, evaluated
once at loop entry - v1.7 treats both identically here, since neither
is what drives reconstruction) and body for every occurrence of
`varname`. Returns a NamedTuple describing the single qualifying
reconstruction: `(idx, kind=:direct, ctor_args)` for `varname =
TypeName(...)`; `(idx, kind=:inline, qname, intermediate, int_names,
ctor_args)` for `varname = helper(varname)` where `helper`'s own body
is a one-level-inlinable straight-line sequence of field-read-only
bindings terminating in a reconstruction (v1.1); or `(idx, kind=:branch,
tree)` for an `if`/`elseif`/`else` statement whose every leaf
independently reconstructs (v1.2, requires a mandatory terminal else -
see `classify_branch_tree`)."""
function classify_loop(header, loop_stmts, varname, typename, fields, mod::Module)
    recons = Any[]
    for (i, s) in enumerate(loop_stmts)
        direct = try_direct_reconstruction(s, varname, typename, fields, mod)
        if direct !== nothing
            push!(recons, (idx=i, kind=:direct, ctor_args=direct))
            continue
        end
        helper_name = try_inline_call_shape(s, varname)
        if helper_name !== nothing
            plan = try_inline_helper(helper_name, mod, typename, fields)
            push!(recons, (idx=i, kind=:inline, qname=plan.qname, intermediate=plan.intermediate,
                            int_names=plan.int_names, ctor_args=plan.ctor_args))
            continue
        end
        # v1.5: only commit to classify_branch_tree's own strict
        # validation (mandatory terminal else included) when at least
        # one leaf of this if/elseif/else actually looks like it's
        # trying to reconstruct `varname` - otherwise this is unrelated
        # control flow that merely happens to appear in the loop body
        # (an early-return guard clause, say), and unconditionally
        # dispatching ANY top-level `if` here would decline the WHOLE
        # loop on that unrelated statement's own shape before a genuine
        # reconstruction elsewhere in the body is ever examined. Found
        # by the corpus study (corpus-study/README.md): Sockets.jl's
        # listenany has exactly this shape, an `if bind(...) ...; end`
        # guard with no else, ahead of its own real reconstruction.
        if Meta.isexpr(s, :if) && if_tree_attempts_reconstruction(s, varname)
            tree = classify_branch_tree(s, varname, typename, fields, mod)
            push!(recons, (idx=i, kind=:branch, tree=tree))
            continue
        end
        check_only_field_reads(s, varname, fields, typename, mod)
    end
    check_only_field_reads(header, varname, fields, typename, mod)
    length(recons) == 1 || throw(AsrDecline("expected exactly one reconstruction assignment in loop body"))
    return recons[1]
end

"""Lightweight, non-throwing pre-check: does at least one leaf of the
if/elseif/else tree's own last statement look like `varname =
...(...)` - the same shape `try_direct_reconstruction`/
`try_inline_call_shape` validate strictly? Not a validation itself
(classify_branch_tree's own stricter checks, including the mandatory
terminal else, still run afterward and can still correctly decline) -
just decides whether `classify_loop` should attempt that stricter
validation for THIS if-statement at all, rather than falling through to
it unconditionally for every top-level `if` regardless of whether it
has anything to do with the accumulator."""
function if_tree_attempts_reconstruction(ifexpr, varname)
    Meta.isexpr(ifexpr, :if) || return false
    length(ifexpr.args) in (2, 3) || return false
    leaf_last_stmt_assigns(ifexpr.args[2], varname) && return true
    length(ifexpr.args) == 3 || return false
    return else_part_attempts_reconstruction(ifexpr.args[3], varname)
end

function else_part_attempts_reconstruction(else_part, varname)
    if Meta.isexpr(else_part, :elseif)
        length(else_part.args) == 3 || return false
        _, then_block, else_part2 = else_part.args
        leaf_last_stmt_assigns(then_block, varname) && return true
        return else_part_attempts_reconstruction(else_part2, varname)
    elseif Meta.isexpr(else_part, :block)
        return leaf_last_stmt_assigns(else_part, varname)
    end
    return false
end

function leaf_last_stmt_assigns(block, varname)
    Meta.isexpr(block, :block) || return false
    stmts = strip_linenums(block.args)
    isempty(stmts) && return false
    last_stmt = stmts[end]
    return Meta.isexpr(last_stmt, :(=)) && length(last_stmt.args) == 2 && last_stmt.args[1] === varname
end

"""Returns the reconstruction call's positional args if `s` is
`varname = TypeName(args...)` matching `typename`/`fields`, else
`nothing`. Field-expressions may reference `varname` only via field
reads - checked directly here since this statement is excluded from
the caller's generic "every other statement" pass."""
function try_direct_reconstruction(s, varname, typename, fields, mod::Module)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    (lhs === varname && Meta.isexpr(rhs, :call)) || return nothing
    callargs = rhs.args
    (callargs[1] === typename) || return nothing
    ctor_args = callargs[2:end]
    any(a -> Meta.isexpr(a, :kw) || Meta.isexpr(a, :...) || Meta.isexpr(a, :parameters), ctor_args) && return nothing
    length(ctor_args) == length(fields) || return nothing
    for a in ctor_args
        check_only_field_reads(a, varname, fields, typename, mod)
    end
    return ctor_args
end

"""Returns the helper function's name if `s` is `varname =
helper(varname)` (the accumulator passed as the sole, unchanged
argument), else `nothing`."""
function try_inline_call_shape(s, varname)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    (lhs === varname && Meta.isexpr(rhs, :call) && length(rhs.args) == 2) || return nothing
    helper_name, arg = rhs.args
    (helper_name isa Symbol && arg === varname) || return nothing
    return helper_name
end

# -----------------------------------------------------------------------
# Branch-shaped reconstruction (v1.2)
# -----------------------------------------------------------------------

"""Classifies an `Expr(:if, cond, then_block[, else_part])` loop-body
statement as a branch-shaped reconstruction: every leaf of the
if/elseif/else tree must independently reconstruct (direct or
inlined), and a terminal `else` is mandatory - unlike clause-head
dispatch (BEAM-asr's free case), a `while` loop has only one body
block, so there is no other way for every code path to be covered.
Returns a recursive tree: `(kind=:branch, cond, then, else_)` at
internal nodes, `(kind=:leaf, leaf, prefix)` at leaves, where `leaf` is
a `:direct`/`:inline` plan (as in `classify_loop`) and `prefix` is the
leaf block's own non-reconstruction statements."""
function classify_branch_tree(ifexpr, varname, typename, fields, mod::Module)
    length(ifexpr.args) in (2, 3) || throw(AsrDecline("malformed if expression"))
    length(ifexpr.args) == 3 || throw(AsrDecline("branch-shaped reconstruction requires a terminal else"))
    cond, then_block, else_part = ifexpr.args
    check_only_field_reads(cond, varname, fields, typename, mod)
    Meta.isexpr(then_block, :block) || throw(AsrDecline("if-branch body is not a block"))
    then_leaf = classify_leaf_block(strip_linenums(then_block.args), varname, typename, fields, mod)
    else_leaf = classify_else_part(else_part, varname, typename, fields, mod)
    return (kind=:branch, cond=cond, then=then_leaf, else_=else_leaf)
end

function classify_else_part(else_part, varname, typename, fields, mod::Module)
    if Meta.isexpr(else_part, :elseif)
        length(else_part.args) == 3 || throw(AsrDecline("malformed elseif"))
        cond_block, then_block, else_part2 = else_part.args
        Meta.isexpr(cond_block, :block) || throw(AsrDecline("malformed elseif condition"))
        cond_stmts = strip_linenums(cond_block.args)
        length(cond_stmts) == 1 || throw(AsrDecline("malformed elseif condition"))
        cond = cond_stmts[1]
        check_only_field_reads(cond, varname, fields, typename, mod)
        Meta.isexpr(then_block, :block) || throw(AsrDecline("elseif body is not a block"))
        then_leaf = classify_leaf_block(strip_linenums(then_block.args), varname, typename, fields, mod)
        else_leaf = classify_else_part(else_part2, varname, typename, fields, mod)
        return (kind=:branch, cond=cond, then=then_leaf, else_=else_leaf)
    elseif Meta.isexpr(else_part, :block)
        return classify_leaf_block(strip_linenums(else_part.args), varname, typename, fields, mod)
    else
        throw(AsrDecline("unrecognized else-part shape"))
    end
end

"""A leaf branch's own body: its last statement must itself be a
direct or inlined reconstruction (reusing the same shape-detection as
the flat, non-branching loop body); earlier statements must be
field-read-only."""
function classify_leaf_block(stmts, varname, typename, fields, mod::Module)
    isempty(stmts) && throw(AsrDecline("branch leaf body is empty"))
    last_stmt = stmts[end]
    prefix = stmts[1:end-1]
    direct = try_direct_reconstruction(last_stmt, varname, typename, fields, mod)
    leaf = if direct !== nothing
        (kind=:direct, ctor_args=direct)
    else
        helper_name = try_inline_call_shape(last_stmt, varname)
        helper_name === nothing && throw(AsrDecline("branch leaf's last statement is not a reconstruction"))
        plan = try_inline_helper(helper_name, mod, typename, fields)
        (kind=:inline, qname=plan.qname, intermediate=plan.intermediate, int_names=plan.int_names,
         ctor_args=plan.ctor_args)
    end
    for s in prefix
        check_only_field_reads(s, varname, fields, typename, mod)
    end
    return (kind=:leaf, leaf=leaf, prefix=prefix)
end

"""Collects every intermediate-binding name from every inlined leaf in
a branch tree, for the collision check - reusing the same gensym'd
name across two mutually-exclusive branches is safe (only one branch's
assignment ever executes per iteration), so this is a plain Set, not
per-leaf-scoped."""
function collect_inline_int_names!(names::Set{Symbol}, node)
    if node.kind === :branch
        collect_inline_int_names!(names, node.then)
        collect_inline_int_names!(names, node.else_)
    else
        node.leaf.kind === :inline && union!(names, node.leaf.int_names)
    end
end

# -----------------------------------------------------------------------
# Interprocedural inlining (one level, v1.1)
# -----------------------------------------------------------------------

"""Resolves a `Method.file` path to a file that actually exists on THIS
machine. For a method compiled into a precompiled sysimage (any stdlib
function on a downloaded binary release, not just user code),
`Method.file` - and `Base.find_source_file`, confirmed empirically to
NOT fix this case - can both still report the BUILD machine's own path
(e.g. `C:\\workdir\\usr\\share\\julia\\stdlib\\v1.10\\Sockets\\src\\Sockets.jl`
for `Sockets.bind` on this machine) rather than this install's real
location. Falls back to locating the path's own `stdlib/vX.Y/...`
suffix and rejoining it onto `Sys.STDLIB`, which - unlike `Method.file`
itself - DOES resolve correctly for the running process, before giving
up. Shared by `try_inline_helper` (v1.1) and `verify_safe_passthrough_arg`
(v1.6) - both recover a helper's source this same way, and both were
equally affected by this until it was caught testing v1.6 against real
stdlib code (`Sockets.listenany`)."""
function resolve_source_file(raw::AbstractString)
    isfile(raw) && return raw
    found = Base.find_source_file(raw)
    found !== nothing && isfile(found) && return found
    parts = splitpath(raw)
    idx = findfirst(==("stdlib"), parts)
    if idx !== nothing && idx + 2 <= length(parts)
        candidate = joinpath(Sys.STDLIB, parts[idx+2:end]...)
        isfile(candidate) && return candidate
    end
    return nothing
end

"""Resolves `helper_name` to a single-method function taking exactly
one argument, recovers its ORIGINAL source `Expr` via `functionloc` +
re-reading and re-parsing the source file (the same reflection
`cpython-asr`'s `inspect.getsource` performs - Julia macros only see
the Expr they're literally applied to, not the whole module, so there
is no `parse_transform`-style Forms list to scan the helper from), and
validates its body is a straight-line sequence of field-read-only
intermediate bindings terminating in a full reconstruction matching
`typename`/`fields`."""
function try_inline_helper(helper_name::Symbol, mod::Module, typename, fields)
    helper_fn = try
        Core.eval(mod, helper_name)
    catch
        nothing
    end
    (helper_fn !== nothing && helper_fn isa Function) || throw(AsrDecline("helper not resolvable to a function"))
    ms = methods(helper_fn)
    length(ms) == 1 || throw(AsrDecline("helper must have exactly one method"))
    m = only(ms)
    m.nargs == 2 || throw(AsrDecline("helper must take exactly one argument"))

    file = resolve_source_file(String(m.file))
    file === nothing && throw(AsrDecline("helper source file not found on disk"))
    src = try
        read(file, String)
    catch
        throw(AsrDecline("could not read helper source file"))
    end
    parsed = Meta.parseall(src; filename = file)
    fdef = find_function_def(parsed, helper_name)
    fdef === nothing && throw(AsrDecline("could not locate helper source at top level"))

    sig, body = fdef.args
    Meta.isexpr(body, :block) || throw(AsrDecline("helper body is not a block"))
    length(sig.args) == 2 || throw(AsrDecline("helper signature shape not supported"))
    qname = sig.args[2]
    qname isa Symbol || throw(AsrDecline("helper parameter not a plain symbol"))

    hstmts = strip_linenums(body.args)
    isempty(hstmts) && throw(AsrDecline("helper body is empty"))
    last_stmt = hstmts[end]
    Meta.isexpr(last_stmt, :call) || throw(AsrDecline("helper body must end in a reconstruction call"))
    (last_stmt.args[1] === typename) || throw(AsrDecline("helper reconstruction type mismatch"))
    ctor_args = last_stmt.args[2:end]
    any(a -> Meta.isexpr(a, :kw) || Meta.isexpr(a, :...) || Meta.isexpr(a, :parameters), ctor_args) &&
        throw(AsrDecline("helper reconstruction uses keyword/splat args"))
    length(ctor_args) == length(fields) || throw(AsrDecline("helper reconstruction field count mismatch"))
    for a in ctor_args
        check_only_field_reads(a, qname, fields, typename, mod)
    end

    intermediate = hstmts[1:end-1]
    int_names = Symbol[]
    for s in intermediate
        (Meta.isexpr(s, :(=)) && length(s.args) == 2) ||
            throw(AsrDecline("helper intermediate statement is not a simple assignment"))
        newvar, valexpr = s.args
        newvar isa Symbol || throw(AsrDecline("helper intermediate assignment target not a plain symbol"))
        check_only_field_reads(valexpr, qname, fields, typename, mod)
        push!(int_names, newvar)
    end

    return (qname=qname, intermediate=intermediate, int_names=int_names, ctor_args=ctor_args)
end

"""Recursively finds EVERY function definition - long-form (`function
f(...) ... end`) or short-form (`f(...) = ...`, which parses to the
same `(sig, body)` shape, `body` wrapped in a `:block`) - matching
`name`, at any depth reached through `:toplevel`/`:module`/`:block`/
docstring-`:macrocall` wrappers. A real source file is typically its
own `module X ... end` (confirmed against `Sockets.jl` while testing
v1.6 against `Sockets.bind` - a flat top-level-only scan, this
function's ORIGINAL v1.1 shape, silently found nothing and always had,
for any module-wrapped file; never caught before because prior tests
only exercised bare, module-free helper source). Does not recurse into
arbitrary expressions (call arguments, other functions' own bodies,
etc.) - only these specific "transparent" structural wrappers - to
avoid false-positiving on an unrelated shadowed/local name."""
function find_all_function_defs!(into::Vector, term, name::Symbol)
    term isa Expr || return into
    if Meta.isexpr(term, :function) && length(term.args) == 2
        sig = term.args[1]
        Meta.isexpr(sig, :call) && sig.args[1] === name && push!(into, term)
    elseif Meta.isexpr(term, :(=)) && length(term.args) == 2
        sig = term.args[1]
        if Meta.isexpr(sig, :call) && sig.args[1] === name && Meta.isexpr(term.args[2], :block)
            push!(into, term)
        end
    end
    if term.head in (:toplevel, :module, :block, :macrocall)
        for a in term.args
            find_all_function_defs!(into, a, name)
        end
    end
    return into
end

"""Finds a `function name(...) ... end`/`name(...) = ...` definition by
name anywhere in a `Meta.parseall`-produced `:toplevel` Expr (see
`find_all_function_defs!`); the first match, matching the "exactly one
method" restriction `try_inline_helper` already requires above (so
there is at most one candidate arity to find in practice)."""
function find_function_def(toplevel, name::Symbol)
    candidates = find_all_function_defs!(Any[], toplevel, name)
    return isempty(candidates) ? nothing : first(candidates)
end

gensym_name(varname::Symbol, inner::Symbol) = Symbol(varname, :_inl_, inner)

"""Walks Term for `varname`: a whole-node field read (Expr(:., varname,
QuoteNode(f))) with f in fields is fine and not recursed into further;
any other bare occurrence of the Symbol `varname` declines - UNLESS it's
a positional argument to a call this transform can prove is a safe
one-level pass-through (v1.6, `allow_call_passthrough` - see
`verify_safe_passthrough_arg`), e.g. `Sockets.jl`'s
`bind(sock::TCPServer, addr::InetAddr) = bind(sock, addr.host,
addr.port)`: `addr` appears bare as one of TWO arguments to `bind`, not
as the reconstruction, so this is a different case from
`try_inline_helper`'s `helper(varname)`-shaped sole-argument inlining.
`allow_call_passthrough=false` when re-walking a resolved pass-through
helper's own body, bounding this to exactly one level - a nested
opaque call inside THAT body still declines, same discipline as v1.1's
interprocedural inlining."""
function check_only_field_reads(term, varname, fields, typename, mod::Module; allow_call_passthrough::Bool=true)
    if is_field_read(term, varname, fields)
        return
    elseif term isa Symbol
        term === varname && throw(AsrDecline("bare accumulator reference outside a field read"))
    elseif Meta.isexpr(term, :call) && allow_call_passthrough
        callee = term.args[1]
        callargs = term.args[2:end]
        for (i, a) in enumerate(callargs)
            if a === varname
                verify_safe_passthrough_arg(callee, i, callargs, typename, fields, mod) ||
                    throw(AsrDecline("bare accumulator reference outside a field read"))
            else
                check_only_field_reads(a, varname, fields, typename, mod)
            end
        end
    elseif term isa Expr
        for a in term.args
            check_only_field_reads(a, varname, fields, typename, mod; allow_call_passthrough=allow_call_passthrough)
        end
    end
end

function is_field_read(term, varname, fields)
    Meta.isexpr(term, :., 2) || return false
    recv, fieldnode = term.args
    (recv === varname && fieldnode isa QuoteNode) || return false
    return fieldnode.value in fields
end

"""One-level interprocedural safety check for the accumulator passed
BARE as a non-sole positional argument to some other call (v1.6,
distinct from `try_inline_helper`'s `helper(varname)`-shaped sole-arg
inlining). Resolves `callee` via multiple dispatch to the SINGLE method
whose signature accepts the accumulator's own declared type at the
matching position - filtering by type at that position, not by
`length(methods(f)) == 1` the way `try_inline_helper` does, since a
stdlib function like `bind` genuinely has many methods across many
files. Recovers that method's source (long- or short-form; a
one-line short-form def is exactly `Sockets.jl`'s own
`bind(sock, addr) = bind(sock, addr.host, addr.port)`) and confirms its
own matching parameter is used ONLY via field reads throughout the
ENTIRE method body - the same safety bar as everywhere else in this
transform, just checked one level down, with no second level of
pass-through allowed. Declines (returns false) on anything not cleanly
resolvable: an unresolvable callee, zero or more than one applicable
method, a parameter that isn't a plain (possibly `::Typed`) symbol, a
method body this can't locate/parse, or any bare use of that parameter
beyond a field read. `pos` is the accumulator's 1-indexed position
among `callargs` - passed explicitly by the caller's own `enumerate`
rather than re-derived via `findfirst(a -> a === arg, callargs)`, since
Symbols are interned (`:p === :p` regardless of position) and a call
with the accumulator appearing at more than one argument position
(`f(p, p)`) would otherwise have every occurrence resolve to the
FIRST position's index."""
function verify_safe_passthrough_arg(callee, pos::Int, callargs, typename, fields, mod::Module)
    callee isa Symbol || return false
    f = try
        Core.eval(mod, callee)
    catch
        nothing
    end
    (f !== nothing && f isa Function) || return false

    T = resolve_type(mod, typename)
    T === nothing && return false

    nargs = length(callargs)

    candidates = Method[]
    for m in methods(f)
        m.nargs == nargs + 1 || continue
        # m.sig is a UnionAll (not a plain DataType with a .parameters
        # field) for a parametric method (`f(x::Vector{T}) where T`) -
        # unwrap first, same discipline as v1.4's struct-type handling.
        # Caught via the corpus study: TOML.jl's `point_to_line` calls
        # a parametric IO-printing method, which crashed this check
        # with an uncaught `UnionAll has no field parameters` error
        # before this fix - this transform must always cleanly decline
        # an unsupported shape, never raise past `AsrDecline`.
        sig_body = m.sig isa UnionAll ? Base.unwrap_unionall(m.sig) : m.sig
        sig_body isa DataType || continue
        params = sig_body.parameters
        pos + 1 <= length(params) || continue
        applicable = try
            T <: params[pos+1]
        catch
            false
        end
        applicable && push!(candidates, m)
    end
    length(candidates) == 1 || return false
    m = only(candidates)

    file = resolve_source_file(String(m.file))
    file === nothing && return false
    src = try
        read(file, String)
    catch
        return false
    end
    parsed = try
        Meta.parseall(src; filename = file)
    catch
        return false
    end
    fdef = find_function_def_by_arity(parsed, callee, nargs)
    fdef === nothing && return false

    sig, body = fdef.args
    Meta.isexpr(body, :block) || return false
    sig_params = sig.args[2:end]
    pos <= length(sig_params) || return false
    pname = param_name(sig_params[pos])
    pname === nothing && return false

    return try
        check_only_field_reads(body, pname, fields, typename, mod; allow_call_passthrough=false)
        true
    catch e
        e isa AsrDecline || rethrow()
        false
    end
end

param_name(p::Symbol) = p
function param_name(p)
    Meta.isexpr(p, :(::), 2) && p.args[1] isa Symbol && return p.args[1]
    return nothing
end

"""Finds a function definition (see `find_all_function_defs!` for the
long-/short-form shapes and structural wrappers this looks through)
matching `name` AND the given positional arity. Matching by arity too
(not just name) matters here: the call site's own argument count
already disambiguates which of possibly several same-named methods
`verify_safe_passthrough_arg` resolved via dispatch above, and
re-matching by name alone in this function could hit an unrelated
same-named method with a different signature entirely."""
function find_function_def_by_arity(toplevel, name::Symbol, nargs::Int)
    candidates = find_all_function_defs!(Any[], toplevel, name)
    for s in candidates
        sig = s.args[1]
        length(sig.args) - 1 == nargs && return s
    end
    return nothing
end

"""Walks post-loop statements for uses of `varname`: field reads are
fine anywhere; at most one bare occurrence is allowed, and only as a
`return varname` statement or the function's bare trailing expression."""
function classify_post(post_stmts, varname, fields, typename, mod::Module)
    for (i, s) in enumerate(post_stmts)
        is_tail = (i == length(post_stmts))
        if is_tail && is_bare_return_or_tail(s, varname)
            continue
        end
        check_only_field_reads(s, varname, fields, typename, mod)
    end
end

function is_bare_return_or_tail(s, varname)
    s === varname && return true
    Meta.isexpr(s, :return) && length(s.args) == 1 && s.args[1] === varname && return true
    return false
end

"""Every synthesized scalar/temp/inline-gensym name, from EVERY
qualifying accumulator, must not occur anywhere (read or write) in the
original function body, and no two DIFFERENT accumulators may
synthesize the same name (the same name reused by the SAME accumulator
across its own uses is fine and expected - only cross-accumulator
collisions are rejected here). v1.7: `loopvar` (a `for`-loop's own
iteration variable, `nothing` for `while`) is added directly - it
isn't part of `header`/`loop_stmts`/anything else collected below (the
header assignment's OWN target symbol, not an occurrence inside the
checked expressions), and must still be protected even if never
referenced inside the loop body at all (`for _unused in 1:5`-shaped
declared-but-unread locals still occupy the name)."""
function check_collisions_multi(pre_stmts, header, loop_stmts, post_stmts, accum_plans, loopvar)
    existing = Set{Symbol}()
    collect_all_names!(existing, Expr(:block, pre_stmts...))
    collect_all_names!(existing, header)
    collect_all_names!(existing, Expr(:block, loop_stmts...))
    collect_all_names!(existing, Expr(:block, post_stmts...))
    loopvar !== nothing && push!(existing, loopvar)

    owner = Dict{Symbol,Int}()
    for (idx, ap) in enumerate(accum_plans)
        for nm in Iterators.flatten((values(ap.scalar_names), values(ap.tmp_names), values(ap.inline_gensym_names)))
            nm in existing && throw(AsrDecline("synthesized name collision: $nm"))
            haskey(owner, nm) && owner[nm] != idx && throw(AsrDecline("cross-accumulator name collision: $nm"))
            owner[nm] = idx
        end
    end
end

function collect_all_names!(acc::Set{Symbol}, term)
    if term isa Symbol
        push!(acc, term)
    elseif term isa Expr
        for a in term.args
            collect_all_names!(acc, a)
        end
    end
end

# -----------------------------------------------------------------------
# Phase 2: rewrite
# -----------------------------------------------------------------------

scalar_name(varname::Symbol, f::Symbol) = Symbol(varname, :_, f)
tmp_name(varname::Symbol, f::Symbol) = Symbol(:__asr_tmp_, varname, :_, f)

function accumulator_stmt_fields(s, varname, fields)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    (lhs === varname && Meta.isexpr(rhs, :call)) || return nothing
    ctor_args = rhs.args[2:end]
    length(ctor_args) == length(fields) || return nothing
    return ctor_args
end

"""Replaces each qualifying accumulator's own init statement with its
N scalar-variable inits; every other pre-loop statement (and any
accumulator init that didn't itself qualify) passes through unchanged."""
function rewrite_pre_multi(pre_stmts, accum_plans)
    out = Any[]
    for s in pre_stmts
        owner = findfirst(ap -> accumulator_stmt_fields(s, ap.varname, ap.fields) !== nothing, accum_plans)
        if owner === nothing
            push!(out, s)
        else
            ap = accum_plans[owner]
            acc = accumulator_stmt_fields(s, ap.varname, ap.fields)
            for (f, expr) in zip(ap.fields, acc)
                push!(out, Expr(:(=), ap.scalar_names[f], expr))
            end
        end
    end
    return out
end

"""Folds `subst_field_reads` over every accumulator's own (varname,
scalar_names, typename, fields) tuple - each pass only touches its own
accumulator's field reads (and passthrough call-site reboxing, v1.6),
leaving everything else (including other accumulators' field reads,
substituted in a later pass) untouched, so a single reconstruction
expression that reads a DIFFERENT accumulator's fields directly (e.g.
one twobody accumulator reading the other's old value) still resolves
correctly regardless of substitution order."""
function subst_all(term, subs)
    for (vn, sn, tn, fs) in subs
        term = subst_field_reads(term, vn, sn, tn, fs)
    end
    return term
end

"""Walks loop_stmts once; at the position owned by some accumulator's
own reconstruction, expands THAT accumulator's recon (direct/inline/
branch), applying `subs` (every accumulator) for cross-accumulator field
reads throughout; every other statement is just cross-substituted."""
function rewrite_loop_stmts_multi(loop_stmts, accum_plans, subs)
    out = Any[]
    for (i, s) in enumerate(loop_stmts)
        owner = findfirst(ap -> ap.recon.idx == i, accum_plans)
        if owner !== nothing
            ap = accum_plans[owner]
            if ap.recon.kind === :branch
                push!(out, rewrite_branch_tree(ap.recon.tree, ap, subs))
            else
                append!(out, expand_recon_to_stmts(ap.recon, ap, subs))
            end
        else
            push!(out, subst_all(s, subs))
        end
    end
    return out
end

"""Expands a `:direct`/`:inline` leaf plan (owned by accumulator `ap`)
into its rewritten statements: any inlined prelude, then the parallel
temp-then-assign staging, cross-substituted via `subs` for every
accumulator - the same expansion used both for the flat (non-branching)
loop body and for each leaf of a branch tree."""
function expand_recon_to_stmts(leaf_plan, ap, subs)
    prelude, ctor_args = if leaf_plan.kind === :inline
        expand_inline(leaf_plan, ap.varname, subs, ap.inline_gensym_names)
    else
        (Any[], leaf_plan.ctor_args)
    end
    out = Any[]
    append!(out, prelude)
    for (f, arg) in zip(ap.fields, ctor_args)
        expr = subst_all(arg, subs)
        push!(out, Expr(:(=), ap.tmp_names[f], expr))
    end
    for f in ap.fields
        push!(out, Expr(:(=), ap.scalar_names[f], ap.tmp_names[f]))
    end
    return out
end

"""Rewrites a classified branch tree (owned by accumulator `ap`) into a
plain nested `Expr(:if, cond, then, else)` tree (Julia lowers `elseif`
to exactly this shape anyway - there is no separate semantics to
preserve), with each leaf's prefix statements cross-substituted via
`subs` and its own reconstruction expanded via `expand_recon_to_stmts`."""
function rewrite_branch_tree(node, ap, subs)
    if node.kind === :leaf
        prefix_stmts = [subst_all(s, subs) for s in node.prefix]
        recon_stmts = expand_recon_to_stmts(node.leaf, ap, subs)
        return Expr(:block, prefix_stmts..., recon_stmts...)
    else
        new_cond = subst_all(node.cond, subs)
        new_then = rewrite_branch_tree(node.then, ap, subs)
        new_else = rewrite_branch_tree(node.else_, ap, subs)
        return Expr(:if, new_cond, new_then, new_else)
    end
end

"""Splices an inlined helper's body into the caller's loop: renames the
helper's own parameter to the OWNING accumulator's variable and every
intermediate binding to its gensym'd name (collision-checked already at
qualification time), cross-substitutes the renamed statements via
`subs` exactly as if they'd been written directly in the caller, and
returns them as a prelude plus the (now plain, substitution-ready)
final reconstruction's positional argument expressions."""
function expand_inline(recon, owner_varname, subs, inline_gensym_names)
    rename_map = Dict{Symbol,Symbol}(recon.qname => owner_varname)
    for nm in recon.int_names
        rename_map[nm] = inline_gensym_names[nm]
    end
    renamed_intermediate = [rename_vars(s, rename_map) for s in recon.intermediate]
    renamed_ctor_args = [rename_vars(a, rename_map) for a in recon.ctor_args]
    prelude = [subst_all(s, subs) for s in renamed_intermediate]
    return (prelude, renamed_ctor_args)
end

"""Renames every Symbol occurrence matching a key in `rename_map`.
Generic recursion otherwise."""
function rename_vars(term, rename_map)
    if term isa Symbol
        return get(rename_map, term, term)
    elseif term isa Expr
        return Expr(term.head, [rename_vars(a, rename_map) for a in term.args]...)
    end
    return term
end

"""At most one accumulator can own the tail bare-return/re-boxing
(Julia's `return` takes a single expression); every other post-loop
statement is cross-substituted via `subs`."""
function rewrite_post_multi(post_stmts, accum_plans, subs)
    out = Any[]
    for (i, s) in enumerate(post_stmts)
        is_tail = (i == length(post_stmts))
        owner = is_tail ? findfirst(ap -> is_bare_return_or_tail(s, ap.varname), accum_plans) : nothing
        if owner !== nothing
            ap = accum_plans[owner]
            rebox = rebox_call(ap.typename, ap.scalar_names, ap.fields)
            if Meta.isexpr(s, :return)
                push!(out, Expr(:return, rebox))
            else
                push!(out, rebox)
            end
        else
            push!(out, subst_all(s, subs))
        end
    end
    return out
end

rebox_call(typename, scalar_names, fields) = Expr(:call, typename, [scalar_names[f] for f in fields]...)

"""Replaces every whole-node field read Expr(:., varname, QuoteNode(f))
with the scalar variable for f; never recurses into a matched
field-read node's own children. A bare occurrence of `varname` as a
call argument (v1.6) is replaced with a freshly re-boxed
`typename(scalar1, scalar2, ...)` at that exact call site - by
construction (qualification already ran `check_only_field_reads` over
this same term and would have declined otherwise), the ONLY way a bare
`varname` Symbol can still be present here is as a verified-safe
passthrough call argument, so no re-verification is needed, just the
rebox. Generic recursion otherwise."""
function subst_field_reads(term, varname, scalar_names, typename, fields)
    if Meta.isexpr(term, :., 2)
        recv, fieldnode = term.args
        if recv === varname && fieldnode isa QuoteNode && haskey(scalar_names, fieldnode.value)
            return scalar_names[fieldnode.value]
        end
    end
    if Meta.isexpr(term, :call)
        callee = term.args[1]
        newargs = [a === varname ? rebox_call(typename, scalar_names, fields) :
                                    subst_field_reads(a, varname, scalar_names, typename, fields)
                   for a in term.args[2:end]]
        return Expr(:call, callee, newargs...)
    end
    if term isa Expr
        return Expr(term.head, [subst_field_reads(a, varname, scalar_names, typename, fields) for a in term.args]...)
    end
    return term
end

end # module

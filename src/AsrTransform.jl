"""
Aggregate Scalar Replacement for Julia.

Per-function macro: `@asr function ... end`.

Given a `while` loop that threads one or more immutable struct
accumulators through its own back-edge (each rebound every iteration via
a positional constructor call, full or partial, directly or through a
one-level-inlinable helper, or across an if/elseif/else branch tree),
splits each accumulator into one scalar local per field, re-boxing only
where a bare accumulator reference survives after the loop. v1.1 adds
interprocedural inlining (`try_inline_helper`); v1.2 adds branch-shaped
reconstruction (`classify_branch_tree` - unlike BEAM-asr's clause
dispatch, this needed genuine new code, since a `while` loop has only
one body block); v1.3 adds multi-accumulator support
(`find_and_classify_accumulators`, `subst_all`). See Julia-asr design
notes for the full qualification/rewrite spec this module implements.

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

function rewrite_function(funcdef, mod::Module)
    Meta.isexpr(funcdef, :function) || throw(AsrDecline("not a long-form function definition"))
    length(funcdef.args) == 2 || throw(AsrDecline("unexpected function expr shape"))
    sig, body = funcdef.args
    Meta.isexpr(body, :block) || throw(AsrDecline("function body is not a block"))

    stmts = strip_linenums(body.args)

    while_idxs = findall(s -> Meta.isexpr(s, :while), stmts)
    length(while_idxs) == 1 || throw(AsrDecline("expected exactly one top-level while loop"))
    loop_idx = while_idxs[1]
    pre_stmts = stmts[1:loop_idx-1]
    loop_expr = stmts[loop_idx]
    post_stmts = stmts[loop_idx+1:end]

    length(loop_expr.args) == 2 || throw(AsrDecline("unexpected while expr shape"))
    cond, loopbody = loop_expr.args
    Meta.isexpr(loopbody, :block) || throw(AsrDecline("while body is not a block"))
    loop_stmts = strip_linenums(loopbody.args)

    accum_plans = find_and_classify_accumulators(pre_stmts, cond, loop_stmts, post_stmts, mod)
    check_collisions_multi(pre_stmts, cond, loop_stmts, post_stmts, accum_plans)
    subs = [(ap.varname, ap.scalar_names) for ap in accum_plans]

    new_pre = rewrite_pre_multi(pre_stmts, accum_plans)
    new_cond = subst_all(cond, subs)
    new_loop_stmts = rewrite_loop_stmts_multi(loop_stmts, accum_plans, subs)
    new_post = rewrite_post_multi(post_stmts, accum_plans, subs)

    new_while = Expr(:while, new_cond, Expr(:block, new_loop_stmts...))
    new_body = Expr(:block, new_pre..., new_while, new_post...)
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
old values every step)."""
function find_and_classify_accumulators(pre_stmts, cond, loop_stmts, post_stmts, mod::Module)
    candidates = Any[]
    for s in pre_stmts
        acc = try_accumulator_stmt(s, mod)
        acc !== nothing && push!(candidates, acc)
    end
    isempty(candidates) && throw(AsrDecline("no candidate accumulator found in pre-loop statements"))

    plans = Any[]
    for (varname, typename, fields) in candidates
        plan = try
            recon = classify_loop(cond, loop_stmts, varname, typename, fields, mod)
            classify_post(post_stmts, varname, fields)
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
TypeName(args...)` where TypeName resolves to a defined, non-parametric,
immutable struct whose field count matches the (purely positional)
constructor call, else `nothing`."""
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
    (T isa DataType && isstructtype(T) && !ismutabletype(T)) || return nothing
    fields = collect(fieldnames(T))
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

"""Walks the while loop's condition and body for every occurrence of
`varname`. Returns a NamedTuple describing the single qualifying
reconstruction: `(idx, kind=:direct, ctor_args)` for `varname =
TypeName(...)`; `(idx, kind=:inline, qname, intermediate, int_names,
ctor_args)` for `varname = helper(varname)` where `helper`'s own body
is a one-level-inlinable straight-line sequence of field-read-only
bindings terminating in a reconstruction (v1.1); or `(idx, kind=:branch,
tree)` for an `if`/`elseif`/`else` statement whose every leaf
independently reconstructs (v1.2, requires a mandatory terminal else -
see `classify_branch_tree`)."""
function classify_loop(cond, loop_stmts, varname, typename, fields, mod::Module)
    recons = Any[]
    for (i, s) in enumerate(loop_stmts)
        direct = try_direct_reconstruction(s, varname, typename, fields)
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
        if Meta.isexpr(s, :if)
            tree = classify_branch_tree(s, varname, typename, fields, mod)
            push!(recons, (idx=i, kind=:branch, tree=tree))
            continue
        end
        check_only_field_reads(s, varname, fields)
    end
    check_only_field_reads(cond, varname, fields)
    length(recons) == 1 || throw(AsrDecline("expected exactly one reconstruction assignment in loop body"))
    return recons[1]
end

"""Returns the reconstruction call's positional args if `s` is
`varname = TypeName(args...)` matching `typename`/`fields`, else
`nothing`. Field-expressions may reference `varname` only via field
reads - checked directly here since this statement is excluded from
the caller's generic "every other statement" pass."""
function try_direct_reconstruction(s, varname, typename, fields)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    (lhs === varname && Meta.isexpr(rhs, :call)) || return nothing
    callargs = rhs.args
    (callargs[1] === typename) || return nothing
    ctor_args = callargs[2:end]
    any(a -> Meta.isexpr(a, :kw) || Meta.isexpr(a, :...) || Meta.isexpr(a, :parameters), ctor_args) && return nothing
    length(ctor_args) == length(fields) || return nothing
    for a in ctor_args
        check_only_field_reads(a, varname, fields)
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
    check_only_field_reads(cond, varname, fields)
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
        check_only_field_reads(cond, varname, fields)
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
    direct = try_direct_reconstruction(last_stmt, varname, typename, fields)
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
        check_only_field_reads(s, varname, fields)
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

    file = String(m.file)
    isfile(file) || throw(AsrDecline("helper source file not found on disk"))
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
        check_only_field_reads(a, qname, fields)
    end

    intermediate = hstmts[1:end-1]
    int_names = Symbol[]
    for s in intermediate
        (Meta.isexpr(s, :(=)) && length(s.args) == 2) ||
            throw(AsrDecline("helper intermediate statement is not a simple assignment"))
        newvar, valexpr = s.args
        newvar isa Symbol || throw(AsrDecline("helper intermediate assignment target not a plain symbol"))
        check_only_field_reads(valexpr, qname, fields)
        push!(int_names, newvar)
    end

    return (qname=qname, intermediate=intermediate, int_names=int_names, ctor_args=ctor_args)
end

"""Finds a top-level `function name(...) ... end` definition by name in
a `Meta.parseall`-produced `:toplevel` Expr. Not recursive - v1.1 only
supports a helper defined as an ordinary top-level function, matching
the "exactly one method" restriction already required above."""
function find_function_def(toplevel, name::Symbol)
    for s in toplevel.args
        if Meta.isexpr(s, :function) && length(s.args) == 2
            sig = s.args[1]
            if Meta.isexpr(sig, :call) && sig.args[1] === name
                return s
            end
        end
    end
    return nothing
end

gensym_name(varname::Symbol, inner::Symbol) = Symbol(varname, :_inl_, inner)

"""Walks Term for `varname`: a whole-node field read (Expr(:., varname,
QuoteNode(f))) with f in fields is fine and not recursed into further;
any other bare occurrence of the Symbol `varname` declines."""
function check_only_field_reads(term, varname, fields)
    if is_field_read(term, varname, fields)
        return
    elseif term isa Symbol
        term === varname && throw(AsrDecline("bare accumulator reference outside a field read"))
    elseif term isa Expr
        for a in term.args
            check_only_field_reads(a, varname, fields)
        end
    end
end

function is_field_read(term, varname, fields)
    Meta.isexpr(term, :., 2) || return false
    recv, fieldnode = term.args
    (recv === varname && fieldnode isa QuoteNode) || return false
    return fieldnode.value in fields
end

"""Walks post-loop statements for uses of `varname`: field reads are
fine anywhere; at most one bare occurrence is allowed, and only as a
`return varname` statement or the function's bare trailing expression."""
function classify_post(post_stmts, varname, fields)
    for (i, s) in enumerate(post_stmts)
        is_tail = (i == length(post_stmts))
        if is_tail && is_bare_return_or_tail(s, varname)
            continue
        end
        check_only_field_reads(s, varname, fields)
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
collisions are rejected here)."""
function check_collisions_multi(pre_stmts, cond, loop_stmts, post_stmts, accum_plans)
    existing = Set{Symbol}()
    collect_all_names!(existing, Expr(:block, pre_stmts...))
    collect_all_names!(existing, cond)
    collect_all_names!(existing, Expr(:block, loop_stmts...))
    collect_all_names!(existing, Expr(:block, post_stmts...))

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
scalar_names) pair - each pass only touches its own accumulator's field
reads, leaving everything else (including other accumulators' field
reads, substituted in a later pass) untouched, so a single reconstruction
expression that reads a DIFFERENT accumulator's fields directly (e.g.
one twobody accumulator reading the other's old value) still resolves
correctly regardless of substitution order."""
function subst_all(term, subs)
    for (vn, sn) in subs
        term = subst_field_reads(term, vn, sn)
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
            rebox = Expr(:call, ap.typename, [ap.scalar_names[f] for f in ap.fields]...)
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

"""Replaces every whole-node field read Expr(:., varname, QuoteNode(f))
with the scalar variable for f. Generic recursion otherwise; never
recurses into a matched field-read node's own children."""
function subst_field_reads(term, varname, scalar_names)
    if Meta.isexpr(term, :., 2)
        recv, fieldnode = term.args
        if recv === varname && fieldnode isa QuoteNode && haskey(scalar_names, fieldnode.value)
            return scalar_names[fieldnode.value]
        end
    end
    if term isa Expr
        return Expr(term.head, [subst_field_reads(a, varname, scalar_names) for a in term.args]...)
    end
    return term
end

end # module

"""
Aggregate Scalar Replacement for Julia.

Per-function macro: `@asr function ... end`.

Given a `while` loop that threads an immutable struct accumulator through
its own back-edge (rebound each iteration via a positional constructor
call, full or partial), splits the accumulator into one scalar local per
field, re-boxing only where a bare accumulator reference survives after
the loop. See Julia-asr design notes for the full qualification/rewrite
spec this module implements.

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

    varname, typename, fields = find_accumulator(pre_stmts, mod)
    recon_idx = classify_loop(cond, loop_stmts, varname, typename, fields)
    classify_post(post_stmts, varname, fields)

    scalar_names = Dict(f => scalar_name(varname, f) for f in fields)
    tmp_names = Dict(f => tmp_name(varname, f) for f in fields)
    check_collisions(pre_stmts, cond, loop_stmts, post_stmts, scalar_names, tmp_names)

    new_pre = rewrite_pre(pre_stmts, varname, fields, scalar_names)
    new_cond = subst_field_reads(cond, varname, scalar_names)
    new_loop_stmts = rewrite_loop_stmts(loop_stmts, recon_idx, varname, typename, fields, scalar_names, tmp_names)
    new_post = rewrite_post(post_stmts, varname, typename, fields, scalar_names)

    new_while = Expr(:while, new_cond, Expr(:block, new_loop_stmts...))
    new_body = Expr(:block, new_pre..., new_while, new_post...)
    return Expr(:function, sig, new_body)
end

strip_linenums(exprs) = [e for e in exprs if !(e isa LineNumberNode)]

# -----------------------------------------------------------------------
# Phase 1: qualification
# -----------------------------------------------------------------------

"""Scans pre-loop statements for `varname = TypeName(args...)` where
TypeName resolves to a defined, non-parametric, immutable struct whose
field count matches the (purely positional) constructor call."""
function find_accumulator(pre_stmts, mod::Module)
    for s in pre_stmts
        acc = try_accumulator_stmt(s, mod)
        acc === nothing || return acc
    end
    throw(AsrDecline("no candidate accumulator found in pre-loop statements"))
end

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
`varname`. Returns the index (into loop_stmts) of the single qualifying
reconstruction assignment."""
function classify_loop(cond, loop_stmts, varname, typename, fields)
    recon_idxs = Int[]
    for (i, s) in enumerate(loop_stmts)
        if is_reconstruction_assign(s, varname, typename, fields)
            push!(recon_idxs, i)
        else
            check_only_field_reads(s, varname, fields)
        end
    end
    check_only_field_reads(cond, varname, fields)
    length(recon_idxs) == 1 || throw(AsrDecline("expected exactly one reconstruction assignment in loop body"))
    return recon_idxs[1]
end

function is_reconstruction_assign(s, varname, typename, fields)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return false
    lhs, rhs = s.args
    (lhs === varname && Meta.isexpr(rhs, :call)) || return false
    callargs = rhs.args
    (callargs[1] === typename) || return false
    ctor_args = callargs[2:end]
    any(a -> Meta.isexpr(a, :kw) || Meta.isexpr(a, :...) || Meta.isexpr(a, :parameters), ctor_args) && return false
    length(ctor_args) == length(fields) || return false
    # Field-expressions may reference varname only via field reads -
    # checked generically by the caller once this statement is excluded
    # from the "every other statement" pass; verify that here directly.
    for a in ctor_args
        check_only_field_reads(a, varname, fields)
    end
    return true
end

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

"""Every synthesized scalar/temp name must not occur anywhere (read or
write) in the original function body, checked once per function."""
function check_collisions(pre_stmts, cond, loop_stmts, post_stmts, scalar_names, tmp_names)
    existing = Set{Symbol}()
    collect_all_names!(existing, Expr(:block, pre_stmts...))
    collect_all_names!(existing, cond)
    collect_all_names!(existing, Expr(:block, loop_stmts...))
    collect_all_names!(existing, Expr(:block, post_stmts...))
    for nm in Iterators.flatten((values(scalar_names), values(tmp_names)))
        nm in existing && throw(AsrDecline("synthesized name collision: $nm"))
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

function rewrite_pre(pre_stmts, varname, fields, scalar_names)
    out = Any[]
    for s in pre_stmts
        acc = accumulator_stmt_fields(s, varname, fields)
        if acc === nothing
            push!(out, s)
        else
            for (f, expr) in zip(fields, acc)
                push!(out, Expr(:(=), scalar_names[f], expr))
            end
        end
    end
    return out
end

function accumulator_stmt_fields(s, varname, fields)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    (lhs === varname && Meta.isexpr(rhs, :call)) || return nothing
    ctor_args = rhs.args[2:end]
    length(ctor_args) == length(fields) || return nothing
    return ctor_args
end

function rewrite_loop_stmts(loop_stmts, recon_idx, varname, typename, fields, scalar_names, tmp_names)
    out = Any[]
    for (i, s) in enumerate(loop_stmts)
        if i == recon_idx
            _, rhs = s.args
            ctor_args = rhs.args[2:end]
            for (f, arg) in zip(fields, ctor_args)
                expr = subst_field_reads(arg, varname, scalar_names)
                push!(out, Expr(:(=), tmp_names[f], expr))
            end
            for f in fields
                push!(out, Expr(:(=), scalar_names[f], tmp_names[f]))
            end
        else
            push!(out, subst_field_reads(s, varname, scalar_names))
        end
    end
    return out
end

function rewrite_post(post_stmts, varname, typename, fields, scalar_names)
    out = Any[]
    for (i, s) in enumerate(post_stmts)
        is_tail = (i == length(post_stmts))
        if is_tail && is_bare_return_or_tail(s, varname)
            rebox = Expr(:call, typename, [scalar_names[f] for f in fields]...)
            if Meta.isexpr(s, :return)
                push!(out, Expr(:return, rebox))
            else
                push!(out, rebox)
            end
        else
            push!(out, subst_field_reads(s, varname, scalar_names))
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

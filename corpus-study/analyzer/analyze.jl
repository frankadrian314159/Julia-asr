"""
Pass 1 (syntactic-shape proxy) of the Julia-asr corpus study. Mirrors
BEAM-asr's `asr_candidate_scanner.erl` / cpython-asr's `analyze.py` /
FOL's `analyze.clj`: a static, non-executing scan (no type resolution,
no `include`/`using`) that answers "does this position look
record-accumulator-shaped," not "would `@asr` actually transform it" -
that question is Pass 2's job (`gate_check.jl`), which calls the real
`AsrTransform.rewrite_function` as a black-box oracle.

A **loop site** is a top-level, long-form `function name(...) ... end`
definition whose body contains at least one `for` or top-level `while`
loop. `AsrTransform.rewrite_function`'s own precondition requires
*exactly one* top-level `while` and no `for` at all - deliberately
tracked as its own `shape` bucket here (`:single_while`), separate from
`:has_for`/`:multi_while`/`:mixed`, since which of these dominates is
itself the headline finding this study is designed to measure: Julia's
own idiomatic style favors `for` loops far more than `while`, and
`@asr` only ever looks at `while`.

For `:single_while` sites, pre-loop statements are scanned for a
candidate accumulator - `varname = TypeName(args...)`, TypeName a
capitalized Symbol, purely positional args (no kwargs/splat), mirroring
`AsrTransform.try_accumulator_stmt`'s own shape exactly, minus the type
resolution (`resolve_type`/`isstructtype`/`ismutabletype`/field-count
check) that requires a real Module and is Pass 2's job. Each candidate
is then classified by how the loop body rebuilds it:

| kind | shape | ASR-addressable? |
|---|---|---|
| `record_strong` | `varname = TypeName(newargs...)` - same TypeName, a literal reconstruction call, directly in the loop body | yes (the only shape `@asr` v1 recognizes) |
| `record_weak` | `varname = helper(...)` - reassigned via some OTHER call | *possibly* (v1.1 inlining) - not verified here |
| `record_mutate` | `varname.field = ...` anywhere in the loop body | no (Julia-asr has no mutation mode; `cpython-asr`'s v1.4 analog is unimplemented here) |
| `record_other` | reassigned some other way, or never reassigned in the loop body at all | no |

Non-record pre-loop inits (`[]`, `Dict()`, a numeric/bool/string/nothing
literal, or anything else) are classified `collection`/`map`/`scalar`/
`other` respectively, mirroring the sibling studies' own taxonomy.
"""
module Analyze

export scan_file, LoopSite, RecordCandidate

struct RecordCandidate
    varname::Symbol
    typename::Symbol
    kind::Symbol   # :record_strong, :record_weak, :record_mutate, :record_other
end

struct LoopSite
    fname::Symbol
    shape::Symbol            # :single_while, :multi_while, :has_for, :mixed
    n_while::Int
    n_for::Int
    accum_kind::Symbol       # :record_strong / :record_weak / :record_mutate / :record_other /
                              # :collection / :map / :scalar / :other / :none (no pre-loop candidate at all)
    candidates::Vector{RecordCandidate}
end

struct FileResult
    path::String
    ok::Bool
    loc::Int
    n_functions_longform::Int
    n_functions_shortform::Int
    loop_sites::Vector{LoopSite}
end

strip_linenums(exprs) = [e for e in exprs if !(e isa LineNumberNode)]

function scan_file(path::String)
    src = try
        read(path, String)
    catch e
        return FileResult(path, false, 0, 0, 0, LoopSite[])
    end
    loc = count(==('\n'), src) + 1
    parsed = try
        Meta.parseall(src; filename = path)
    catch e
        return FileResult(path, false, loc, 0, 0, LoopSite[])
    end

    longform = Any[]
    shortform_count = Ref(0)
    collect_function_defs!(longform, shortform_count, parsed)

    sites = LoopSite[]
    for fdef in longform
        site = analyze_function(fdef)
        site !== nothing && push!(sites, site)
    end

    return FileResult(path, true, loc, length(longform), shortform_count[], sites)
end

"""Recursively collects every top-level (or module-nested) long-form
`function name(...) ... end` definition. Short-form (`f(x) = ...`)
definitions are just counted, not collected - `@asr` doesn't support
them (`Meta.isexpr(funcdef, :function)` is a hard precondition), so
they can never be loop sites for this transform regardless of what
they contain."""
function collect_function_defs!(out, shortform_count, term)
    if Meta.isexpr(term, :function) && length(term.args) == 2
        push!(out, term)
    elseif Meta.isexpr(term, :(=)) && length(term.args) == 2 && Meta.isexpr(term.args[1], :call)
        shortform_count[] += 1
    elseif term isa Expr
        for a in term.args
            collect_function_defs!(out, shortform_count, a)
        end
    end
end

function analyze_function(fdef)
    fname = function_name(fdef.args[1])
    body = fdef.args[2]
    Meta.isexpr(body, :block) || return nothing
    stmts = strip_linenums(body.args)

    n_while = count(s -> Meta.isexpr(s, :while), stmts)
    n_for = count_for_anywhere(Expr(:block, stmts...))
    (n_while == 0 && n_for == 0) && return nothing

    if n_while == 1 && n_for == 0
        shape = :single_while
        loop_idx = findfirst(s -> Meta.isexpr(s, :while), stmts)
        pre_stmts = stmts[1:loop_idx-1]
        loopbody = stmts[loop_idx].args[2]
        loop_stmts = Meta.isexpr(loopbody, :block) ? strip_linenums(loopbody.args) : Any[loopbody]
        candidates = classify_candidates(pre_stmts, loop_stmts)
        accum_kind = isempty(candidates) ? :none : candidates[1].kind
    elseif n_while >= 2 && n_for == 0
        shape = :multi_while
        candidates = RecordCandidate[]
        accum_kind = :none
    elseif n_while == 0 && n_for > 0
        shape = :has_for
        candidates = RecordCandidate[]
        accum_kind = :none
    else
        shape = :mixed
        candidates = RecordCandidate[]
        accum_kind = :none
    end

    return LoopSite(fname, shape, n_while, n_for, accum_kind, candidates)
end

function count_for_anywhere(term)
    n = 0
    if Meta.isexpr(term, :for)
        n += 1
    end
    if term isa Expr
        for a in term.args
            n += count_for_anywhere(a)
        end
    end
    return n
end

function function_name(sig)
    if Meta.isexpr(sig, :call)
        return function_name(sig.args[1])
    elseif Meta.isexpr(sig, :(::))
        return function_name(sig.args[1])
    elseif Meta.isexpr(sig, :where)
        return function_name(sig.args[1])
    elseif sig isa Symbol
        return sig
    else
        return :unknown
    end
end

"""Finds every `varname = TypeName(args...)` pre-loop candidate
(TypeName capitalized, purely positional args - the same shape
`AsrTransform.try_accumulator_stmt` requires, minus type resolution)
and classifies it by how the loop body rebuilds `varname`."""
function classify_candidates(pre_stmts, loop_stmts)
    out = RecordCandidate[]
    for s in pre_stmts
        cand = try_pre_stmt(s)
        cand === nothing && continue
        varname, init_kind, typename = cand
        if init_kind !== :record
            push!(out, RecordCandidate(varname, Symbol(""), init_kind))
            continue
        end
        kind = classify_rebuild(loop_stmts, varname, typename)
        push!(out, RecordCandidate(varname, typename, kind))
    end
    return out
end

const MAP_TYPES = (:Dict, :IdDict, :OrderedDict, :WeakKeyDict)
const COLLECTION_TYPES = (:Vector, :Array, :Set, :BitSet, :OrderedSet, :StringVector)

# Primitive/numeric type conversions (`UInt64(0)`, `Char(x)`, `Int(y)`)
# are syntactically indistinguishable from a struct constructor call
# under a purely-syntactic Pass 1, but are never a "record accumulator"
# in the ASR sense - confirmed by direct inspection of Julia Base's own
# hits under an earlier, unfiltered version of this scanner (every one
# was either this or a COLLECTION_TYPES buffer-preallocation idiom, not
# a genuine struct). Excluded here the same way Dict/Vector/Set already
# are, not a separate mechanism.
const PRIMITIVE_TYPES = (
    :Int8, :Int16, :Int32, :Int64, :Int128, :Int,
    :UInt8, :UInt16, :UInt32, :UInt64, :UInt128, :UInt,
    :Float16, :Float32, :Float64,
    :Bool, :Char, :String, :Symbol, :BigInt, :BigFloat, :Complex, :Rational,
)

"""Callee of a `TypeName(...)` or `TypeName{...}(...)` call, stripping
one layer of `curly` (`Vector{Int}(...)` -> `:Vector`), else `nothing`."""
function call_typename(callee)
    if callee isa Symbol
        return callee
    elseif Meta.isexpr(callee, :curly) && callee.args[1] isa Symbol
        return callee.args[1]
    else
        return nothing
    end
end

"""Returns `(varname, :record, typename)` for `varname =
TypeName(args...)` (capitalized, positional-only, and not one of the
well-known Base collection/map constructor names below), `(varname,
kind, :none)` for a recognized non-record init (`:collection`/`:map`/
`:scalar`), or `nothing` if `s` isn't a plain `varname = expr`
assignment at all."""
function try_pre_stmt(s)
    (Meta.isexpr(s, :(=)) && length(s.args) == 2) || return nothing
    lhs, rhs = s.args
    lhs isa Symbol || return nothing
    if Meta.isexpr(rhs, :call)
        tn = call_typename(rhs.args[1])
        args = rhs.args[2:end]
        if tn in MAP_TYPES
            return (lhs, :map, :none)
        elseif tn in COLLECTION_TYPES
            return (lhs, :collection, :none)
        elseif tn in PRIMITIVE_TYPES
            return (lhs, :scalar, :none)
        elseif tn !== nothing && isuppercase_first(tn) &&
               !any(a -> Meta.isexpr(a, :kw) || Meta.isexpr(a, :...) || Meta.isexpr(a, :parameters), args)
            return (lhs, :record, tn)
        else
            return nothing
        end
    elseif Meta.isexpr(rhs, :vect)
        return (lhs, :collection, :none)
    elseif rhs isa Number || rhs isa Bool || rhs isa AbstractString || rhs === :nothing
        return (lhs, :scalar, :none)
    else
        return nothing
    end
end

isuppercase_first(sym::Symbol) = (s = String(sym); !isempty(s) && isuppercase(first(s)))

"""How `varname` gets its next value inside the loop body: a direct
reconstruction (`varname = TypeName(...)`, same TypeName), a
helper-mediated rebuild (`varname = other_call(...)`), a direct field
mutation (`varname.field = ...`), or none of the above found at all."""
function classify_rebuild(loop_stmts, varname, typename)
    found_mutate = false
    for s in loop_stmts
        if Meta.isexpr(s, :(=)) && length(s.args) == 2
            lhs, rhs = s.args
            if lhs === varname && Meta.isexpr(rhs, :call)
                callee = rhs.args[1]
                return callee === typename ? :record_strong : :record_weak
            elseif Meta.isexpr(lhs, :., 2) && lhs.args[1] === varname
                found_mutate = true
            end
        end
    end
    return found_mutate ? :record_mutate : :record_other
end

end # module

"""
Pass 2 (gate-faithful) of the Julia-asr corpus study: for every
`record_strong`/`record_weak`/`record_mutate`/`record_other` candidate
Pass 1 finds, runs the REAL `AsrTransform.rewrite_function` - the
actual, tested, shipped transform, never a re-implementation - directly
on the candidate function's own parsed `Expr`, exactly the entry point
`@asr` itself calls. This can never drift from the real qualification
rules, because it *is* the real qualification rules.

Unlike BEAM-asr's Forms-based oracle (pure AST manipulation, no
evaluation), `AsrTransform.rewrite_function` needs a real `Module` in
which the candidate's accumulator TYPE actually resolves
(`resolve_type` calls `Core.eval(mod, typename)`) - this is why the
corpus is Julia's own Base/stdlib source: those types are already
loaded in any running Julia session, so no separate `include`/`using`
step (with its own dependency-resolution risk for arbitrary third-party
code) is needed here.
"""
module GateCheck

export qualifies

"""Re-parses `path`, locates the function named `fname` (by simple name
match - good enough for this corpus, which doesn't multiply-define
same-named functions across single-`while`-loop-shaped methods within
one file), and calls `AsrTransform.rewrite_function` on it directly in
`mod`. Returns `:qualified`, `:declined`, or `{:error, msg}` (a
never-reached candidate, or a shape `rewrite_function` itself errors on
rather than cleanly declining - reported, not silently dropped)."""
function qualifies(asr_mod::Module, path::String, fname::Symbol, mod::Module)
    src = read(path, String)
    parsed = Meta.parseall(src; filename = path)
    fdef = find_named_function(parsed, fname)
    fdef === nothing && return (:error, "function not found on re-parse")
    try
        asr_mod.rewrite_function(fdef, mod)
        return (:qualified, "")
    catch e
        if e isa asr_mod.AsrDecline
            return (:declined, e.msg)
        else
            return (:error, sprint(showerror, e))
        end
    end
end

function find_named_function(term, fname::Symbol)
    if Meta.isexpr(term, :function) && length(term.args) == 2
        if function_name(term.args[1]) === fname
            return term
        end
    end
    if term isa Expr
        for a in term.args
            r = find_named_function(a, fname)
            r !== nothing && return r
        end
    end
    return nothing
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

end # module

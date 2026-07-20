include(joinpath(@__DIR__, "..", "src", "AsrTransform.jl"))
using .AsrTransform
using Test

# ---------------------------------------------------------------------
# Positive cases: functional equivalence between a plain twin and the
# @asr'd version, plus a structural check that qualification actually
# fired (the rewritten function no longer contains the original
# constructor-call shape in its loop body).
# ---------------------------------------------------------------------

struct Point
    x
    y
end

function plain_full(n)
    p = Point(0.0, 0.0)
    i = 0
    while i < n
        p = Point(p.x + 0.1, p.y + 0.2)
        i += 1
    end
    return p.x + p.y
end

@asr function asr_full(n)
    p = Point(0.0, 0.0)
    i = 0
    while i < n
        p = Point(p.x + 0.1, p.y + 0.2)
        i += 1
    end
    return p.x + p.y
end

function plain_partial(n)
    p = Point(0.0, 42.0)
    i = 0
    while i < n
        p = Point(p.x + 1.0, p.y)
        i += 1
    end
    return p
end

@asr function asr_partial(n)
    p = Point(0.0, 42.0)
    i = 0
    while i < n
        p = Point(p.x + 1.0, p.y)
        i += 1
    end
    return p
end

function plain_guard(n)
    p = Point(0.0, 0.0)
    i = 0
    while p.x < n
        p = Point(p.x + 1.0, p.y + 2.0)
        i += 1
    end
    return p.x + p.y
end

@asr function asr_guard(n)
    p = Point(0.0, 0.0)
    i = 0
    while p.x < n
        p = Point(p.x + 1.0, p.y + 2.0)
        i += 1
    end
    return p.x + p.y
end

function plain_bare_return(n)
    p = Point(0.0, 0.0)
    i = 0
    while i < n
        p = Point(p.x + 0.1, p.y + 0.2)
        i += 1
    end
    return p
end

@asr function asr_bare_return(n)
    p = Point(0.0, 0.0)
    i = 0
    while i < n
        p = Point(p.x + 0.1, p.y + 0.2)
        i += 1
    end
    return p
end

function plain_early_return(n)
    p = Point(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 50.0
            return p.x + p.y
        end
        p = Point(p.x + 1.0, p.y + 2.0)
        i += 1
    end
    return p.x + p.y
end

@asr function asr_early_return(n)
    p = Point(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 50.0
            return p.x + p.y
        end
        p = Point(p.x + 1.0, p.y + 2.0)
        i += 1
    end
    return p.x + p.y
end

let
    struct LetPoint
        x
        y
    end
    global function plain_let_struct(n)
        p = LetPoint(0.0, 0.0)
        i = 0
        while i < n
            p = LetPoint(p.x + 1.0, p.y + 1.0)
            i += 1
        end
        return p.x + p.y
    end
    @eval @asr function asr_let_struct(n)
        p = LetPoint(0.0, 0.0)
        i = 0
        while i < n
            p = LetPoint(p.x + 1.0, p.y + 1.0)
            i += 1
        end
        return p.x + p.y
    end
end

# Interprocedural inlining (v1.1): the reconstruction lives in a
# one-level-inlinable helper function, not literally in the loop body.

struct Rot
    re
    im
end

function rotate(z)
    Rot(z.re * 0.9950041652780258 - z.im * 0.09983341664682815,
        z.re * 0.09983341664682815 + z.im * 0.9950041652780258)
end

function plain_inline_direct(n)
    z = Rot(1.0, 0.0)
    i = 0
    while i < n
        z = rotate(z)
        i += 1
    end
    return z.re + z.im
end

@asr function asr_inline_direct(n)
    z = Rot(1.0, 0.0)
    i = 0
    while i < n
        z = rotate(z)
        i += 1
    end
    return z.re + z.im
end

struct Biquad
    x1
    x2
    y1
    y2
end

function biquad_step(st)
    x1 = st.x1
    x2 = st.x2
    y1 = st.y1
    y2 = st.y2
    xin = 1.0
    y = (((0.1 * xin) + (0.2 * x1)) + (0.1 * x2) + (0.9 * y1)) - (0.2 * y2)
    Biquad(xin, x1, y, y1)
end

function plain_inline_bindings(n)
    st = Biquad(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        st = biquad_step(st)
        i += 1
    end
    return st.y1
end

@asr function asr_inline_bindings(n)
    st = Biquad(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        st = biquad_step(st)
        i += 1
    end
    return st.y1
end

# Branch-shaped reconstruction (v1.2): an if/elseif/else statement
# whose every leaf independently reconstructs, mandatory terminal else.

struct Bounce
    x
    y
end

function plain_branch_3way(n)
    p = Bounce(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
        elseif p.x < -100.0
            p = Bounce(0.0, p.y)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

@asr function asr_branch_3way(n)
    p = Bounce(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
        elseif p.x < -100.0
            p = Bounce(0.0, p.y)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

function plain_branch_2way(n)
    p = Bounce(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

@asr function asr_branch_2way(n)
    p = Bounce(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

# v1.7 composition check: branch-shaped reconstruction (v1.2) inside a
# `for` loop rather than `while` - confirms classify_branch_tree and
# friends are genuinely loop-shape-agnostic (they only ever look at
# loop_stmts, never the loop header), not just coincidentally untested
# against `for`.
function plain_branch_for(n)
    p = Bounce(0.0, 0.0)
    for i in 1:n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
        end
    end
    return p.x + p.y
end

@asr function asr_branch_for(n)
    p = Bounce(0.0, 0.0)
    for i in 1:n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
        end
    end
    return p.x + p.y
end

# Multi-accumulator (v1.3): more than one accumulator threaded through
# the same loop simultaneously.

struct Vec2
    x
    y
end

function plain_multi_symmetric(n)
    a = Vec2(0.0, 0.0)
    b = Vec2(1.0, 1.0)
    i = 0
    while i < n
        a = Vec2(a.x + 0.01 * (b.x - a.x), a.y + 0.01 * (b.y - a.y))
        b = Vec2(b.x + 0.01 * (a.x - b.x), b.y + 0.01 * (a.y - b.y))
        i += 1
    end
    return a.x + a.y
end

@asr function asr_multi_symmetric(n)
    a = Vec2(0.0, 0.0)
    b = Vec2(1.0, 1.0)
    i = 0
    while i < n
        a = Vec2(a.x + 0.01 * (b.x - a.x), a.y + 0.01 * (b.y - a.y))
        b = Vec2(b.x + 0.01 * (a.x - b.x), b.y + 0.01 * (a.y - b.y))
        i += 1
    end
    return a.x + a.y
end

struct Kstate
    x
    v
end
struct Kcov
    p00
    p01
    p11
end

function plain_multi_asymmetric(n)
    s = Kstate(0.0, 0.0)
    c = Kcov(1.0, 0.0, 1.0)
    i = 0
    while i < n
        x = s.x
        v = s.v
        p00 = c.p00
        p01 = c.p01
        p11 = c.p11
        xp = x + v
        pp00 = (p00 + 2.0 * p01) + (p11 + 0.001)
        pp01 = p01 + p11
        pp11 = p11 + 0.001
        y = 10.0 - xp
        sden = pp00 + 0.1
        k0 = pp00 / sden
        k1 = pp01 / sden
        s = Kstate(xp + k0 * y, v + k1 * y)
        c = Kcov((1.0 - k0) * pp00, (1.0 - k0) * pp01, pp11 - k1 * pp01)
        i += 1
    end
    return s.x
end

@asr function asr_multi_asymmetric(n)
    s = Kstate(0.0, 0.0)
    c = Kcov(1.0, 0.0, 1.0)
    i = 0
    while i < n
        x = s.x
        v = s.v
        p00 = c.p00
        p01 = c.p01
        p11 = c.p11
        xp = x + v
        pp00 = (p00 + 2.0 * p01) + (p11 + 0.001)
        pp01 = p01 + p11
        pp11 = p11 + 0.001
        y = 10.0 - xp
        sden = pp00 + 0.1
        k0 = pp00 / sden
        k1 = pp01 / sden
        s = Kstate(xp + k0 * y, v + k1 * y)
        c = Kcov((1.0 - k0) * pp00, (1.0 - k0) * pp01, pp11 - k1 * pp01)
        i += 1
    end
    return s.x
end

struct Paramed{T}
    x::T
    y::T
end

# v1.4: a parametric struct accumulator - `Paramed(...)` (bare, no
# explicit `{T}` type application) lets Julia infer T from the
# constructor's own argument types, the same shape found in real code
# by the corpus study (Sockets.listenany's `InetAddr(host,
# default_port)`). An explicit `Paramed{Float64}(...)` call would NOT
# qualify - `try_accumulator_stmt` requires the constructor callee be a
# bare Symbol, not an `Expr(:curly, ...)`.
function plain_paramed(n)
    p = Paramed(0.0, 0.0)
    i = 0
    while i < n
        p = Paramed(p.x + 1.0, p.y + 2.0)
        i += 1
    end
    return p.x + p.y
end

@asr function asr_paramed(n)
    p = Paramed(0.0, 0.0)
    i = 0
    while i < n
        p = Paramed(p.x + 1.0, p.y + 2.0)
        i += 1
    end
    return p.x + p.y
end

# v1.7: a `for`-loop-shaped accumulator - direct reconstruction inside
# a `for i in range` body rather than `while`. The corpus study found
# 245 real record-shaped candidates blocked purely by the loop-shape
# restriction (245 of 260 total candidates, once Pass 1 was extended to
# actually look at for-loop bodies - see corpus-study/README.md), so
# this is the single highest-leverage extension after v1.6.
function plain_for(n)
    p = Point(0.0, 0.0)
    for i in 1:n
        p = Point(p.x + 1.0, p.y + 2.0)
    end
    return p.x + p.y
end

@asr function asr_for(n)
    p = Point(0.0, 0.0)
    for i in 1:n
        p = Point(p.x + 1.0, p.y + 2.0)
    end
    return p.x + p.y
end

@testset "AsrTransform positive cases" begin
    @test plain_full(1000) == asr_full(1000)
    @test plain_partial(500) == asr_partial(500)
    @test plain_guard(30) == asr_guard(30)
    @test plain_bare_return(1000) == asr_bare_return(1000)
    @test plain_early_return(1000) == asr_early_return(1000)
    @test plain_let_struct(500) == asr_let_struct(500)
    @test plain_inline_direct(1000) == asr_inline_direct(1000)
    @test plain_inline_bindings(1000) == asr_inline_bindings(1000)
    @test plain_branch_3way(500) == asr_branch_3way(500)
    @test plain_branch_2way(500) == asr_branch_2way(500)
    @test plain_multi_symmetric(1000) == asr_multi_symmetric(1000)
    @test plain_multi_asymmetric(1000) == asr_multi_asymmetric(1000)
    @test plain_paramed(1000) == asr_paramed(1000)
    @test plain_for(1000) == asr_for(1000)
    @test plain_branch_for(500) == asr_branch_for(500)

    # Structural check: qualification fired iff the rewritten Expr no
    # longer contains a `Point(...)` reconstruction call inside the loop.
    ex = :(function f(n)
        p = Point(0.0, 0.0)
        i = 0
        while i < n
            p = Point(p.x + 0.1, p.y + 0.2)
            i += 1
        end
        return p.x + p.y
    end)
    new_ex = AsrTransform.rewrite_function(ex, @__MODULE__)
    new_body_stmts = AsrTransform.strip_linenums(new_ex.args[2].args)
    loop_stmt = only(filter(s -> s isa Expr && s.head == :while, new_body_stmts))
    loop_body_str = string(loop_stmt.args[2])
    @test !occursin("Point(", loop_body_str)
    @test occursin("__asr_tmp_", loop_body_str)
end

# ---------------------------------------------------------------------
# Negative / abort-safe cases: must decline cleanly, leaving behavior
# (and, where checkable, the Expr itself) completely unchanged.
# ---------------------------------------------------------------------

mutable struct MPoint
    x
    y
end

# v1.4: a parametric AND mutable struct - confirms the parametric-struct
# fix composes correctly with the pre-existing mutable-struct exclusion
# (unwrap first, then the SAME `!ismutabletype` check as ever) rather
# than accidentally bypassing it.
mutable struct MParamed{T}
    x::T
    y::T
end

struct OtherPoint
    x
    y
end

# Long-form helpers for the inline-negative-case testsets below - must
# be true top-level definitions (not nested inside a @testset block),
# since `find_function_def` re-parses this file's own source text
# looking for a direct top-level `function name(...) ... end` and does
# not recurse into a @testset macrocall's block argument.
function multi_method_step(p::Point)
    Point(p.x + 1.0, p.y)
end
function multi_method_step(p::Point, extra)
    Point(p.x + extra, p.y)
end

function wrong_type_step(p)
    Point(p.x + 1.0, p.y)
end

function further_step(a, b)
    Point(a, b)
end
function chained_step(p)
    further_step(p.x + 1.0, p.y)
end

function collide_step(p)
    x1 = p.x + 1.0
    Point(x1, p.y)
end

# Mirrors Sockets.jl's `bind(sock, addr)` shape (an opaque call
# receiving the accumulator bare) but, unlike `bind`, genuinely RETAINS
# its argument rather than just reading fields from it - v1.6's
# interprocedural check must still decline this even though it can
# resolve the callee and its source, because the callee's own body uses
# its parameter as more than a field read. A helper that simply
# discarded `p` (e.g. `f(p) = true`) would be correctly PROVEN safe by
# v1.6 and is no longer a valid negative case for this shape.
const _GUARD_STORE = Ref{Any}(nothing)
function guard_use_bare(p)
    _GUARD_STORE[] = p
    return true
end

# v1.6: an opaque call receiving the accumulator as a NON-sole argument
# (position 2 of 2), long-form definition, whose body reads only fields
# of its matching parameter - the shape try_inline_helper never covered
# (it requires the accumulator be the SOLE argument).
function pt_probe(tag::Int, q::Point)
    tag + q.x + q.y
end

# v1.6: the same shape but short-form (`f(...) = expr`), directly
# mirroring Sockets.jl's own
# `bind(sock::TCPServer, addr::InetAddr) = bind(sock, addr.host, addr.port)`
# one-liner, which parses to a different top-level Expr shape than a
# long-form `function ... end` def.
pt_probe_short(tag::Int, q::Point) = tag + q.x + q.y

# v1.6 negative case: two methods of the same name/arity BOTH accept
# Point at the accumulator's position (differing only in the OTHER
# argument's type) - verify_safe_passthrough_arg filters candidate
# methods by arity and by type at the accumulator's own position only,
# not by every other argument, so this must resolve to two ambiguous
# candidates and decline rather than silently picking one.
ambiguous_probe(tag::Int, q::Point) = tag + q.x + q.y
ambiguous_probe(tag::String, q::Point) = length(tag) + q.x + q.y

# v1.6 regression case: a PARAMETRIC method (`where T`) has a UnionAll
# `Method.sig`, not a plain DataType with a `.parameters` field -
# verify_safe_passthrough_arg must unwrap it (same discipline as v1.4's
# struct-type handling) rather than crash. Found by the corpus study:
# TOML.jl's `point_to_line` calls a parametric IO-printing method and
# raised an uncaught `UnionAll has no field parameters` error before
# this fix.
parametric_probe(tag::Vector{T}, q::Point) where {T} = length(tag) + q.x + q.y

function decline_unchanged(ex, mod)
    new_ex = try
        AsrTransform.rewrite_function(ex, mod)
    catch e
        e isa AsrTransform.AsrDecline || rethrow()
        return true
    end
    return false
end

@testset "AsrTransform negative/abort-safe cases" begin
    @testset "short-form function" begin
        ex = :(f(n) = n + 1)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "zero while loops" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "two while loops" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            while i < 2n
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "mutable struct accumulator" begin
        ex = :(function f(n)
            p = MPoint(0.0, 0.0)
            i = 0
            while i < n
                p = MPoint(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end)
        @test decline_unchanged(ex, @__MODULE__)

        @asr function run_mutable_decline(n)
            p = MPoint(0.0, 0.0)
            i = 0
            while i < n
                p = MPoint(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        @test run_mutable_decline(10) == 30.0
    end

    @testset "parametric AND mutable struct accumulator" begin
        ex = :(function f(n)
            p = MParamed(0.0, 0.0)
            i = 0
            while i < n
                p = MParamed(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "parametric struct, explicit type application" begin
        # `Paramed{Float64}(...)` - the constructor callee is
        # `Expr(:curly, :Paramed, :Float64)`, not a bare Symbol, so
        # `try_accumulator_stmt` declines before type resolution even
        # runs. The bare-call form (`Paramed(...)`, letting Julia infer
        # T) is the one v1.4 supports - see "AsrTransform positive
        # cases"'s plain_paramed/asr_paramed pair above.
        ex = :(function f(n)
            p = Paramed{Float64}(0.0, 0.0)
            i = 0
            while i < n
                p = Paramed{Float64}(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "keyword-argument constructor call" begin
        ex = :(function f(n)
            p = Point(x = 0.0, y = 0.0)
            i = 0
            while i < n
                p = Point(x = p.x + 1.0, y = p.y)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "wrong-arity constructor call" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0, 0.0)
            i = 0
            while i < n
                i += 1
            end
            return n
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "bare accumulator reference outside field read" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                q = p
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "bare early return" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if p.x > 50.0
                    return p
                end
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "synthesized scalar name collision" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            p_x = 5
            i = 0
            while i < n
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            return p.x + p_x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "synthesized temp name collision" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            __asr_tmp_p_x = 5
            i = 0
            while i < n
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            return p.x + __asr_tmp_p_x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "colliding free read of outer name" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            return p.x + p_y
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "two reconstruction assignments in one loop body" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                p = Point(p.x + 1.0, p.y)
                p = Point(p.x + 2.0, p.y)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "while loop wrapped in @inbounds" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            @inbounds while i < n
                p = Point(p.x + 1.0, p.y)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "v1.7: for-loop variable shadows the accumulator's own name" begin
        # `for p in 1:n` rebinds `p` to the LOOP VARIABLE inside the
        # body - a real hazard `while` never has (it introduces no new
        # binding at all). Any bare reference to `p` inside the body
        # would then ambiguously mean the loop variable, not the outer
        # accumulator, so this candidate must decline rather than
        # silently misattribute references.
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            for p in 1:n
                p = Point(1.0, 2.0)
            end
            return p
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "v1.7: multi-iterator for-loop header declines" begin
        # `for i in a, j in b` parses its header as an `Expr(:block,
        # ...)` of multiple assignments, not the single `Expr(:(=),
        # var, iterexpr)` v1.7 supports - declines cleanly rather than
        # misreading the header shape.
        ex = :(function f(n, m)
            p = Point(0.0, 0.0)
            for i in 1:n, j in 1:m
                p = Point(p.x + 1.0, p.y + 1.0)
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "inline: multi-method helper" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                p = multi_method_step(p)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "inline: helper reconstructs a different type" begin
        ex = :(function f(n)
            q = OtherPoint(0.0, 0.0)
            i = 0
            while i < n
                q = wrong_type_step(q)
                i += 1
            end
            return q.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "inline: two-level (chained) inline attempt" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                p = chained_step(p)
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "inline: gensym'd temp name collision" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            p_inl_x1 = 0
            i = 0
            while i < n
                p = collide_step(p)
                i += 1 + p_inl_x1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "branch: missing terminal else" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if p.x > 100.0
                    p = Point(0.0, p.y)
                end
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "branch: elseif chain missing terminal else" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if p.x > 100.0
                    p = Point(0.0, p.y)
                elseif p.x < -100.0
                    p = Point(0.0, p.y)
                end
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "branch: a leaf's last statement is not a reconstruction" begin
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if p.x > 100.0
                    p = Point(0.0, p.y)
                else
                    i = i
                end
                i += 1
            end
            return p.x
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "unrelated if-statement (no else) does not block a later reconstruction" begin
        # v1.5 fix: classify_loop no longer dispatches EVERY top-level
        # `if` to classify_branch_tree unconditionally - an unrelated
        # guard clause (no else, doesn't touch p at all) must not block
        # the genuine reconstruction appearing later in the loop body.
        # Mirrors Sockets.jl's listenany exactly (corpus-study/README.md).
        @asr function guarded_recon_qualifies(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if i < 0
                    error("unreachable guard clause")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        function guarded_recon_plain(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if i < 0
                    error("unreachable guard clause")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        @test guarded_recon_plain(1000) == guarded_recon_qualifies(1000)
    end

    @testset "unrelated if-statement using the accumulator bare still declines" begin
        # The other half of the same fix's own safety boundary: an
        # unrelated guard clause that passes the accumulator BARE into
        # an opaque call (exactly `Sockets.listenany`'s own
        # `bind(sock, addr)`) still correctly declines - now for the
        # true reason ("bare accumulator reference outside a field
        # read"), not the previous false one ("requires a terminal
        # else"), but a decline either way, confirmed directly against
        # real code (corpus-study/README.md).
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if guard_use_bare(p)
                    error("nope")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "v1.6: opaque call passthrough, non-sole argument, long-form helper" begin
        # Mirrors Sockets.jl's listenany/bind shape directly: the
        # accumulator is passed bare as one of TWO arguments to
        # `pt_probe`, not the sole argument `try_inline_helper` requires.
        # `pt_probe`'s own body only reads `q.x`/`q.y`, so v1.6's
        # `verify_safe_passthrough_arg` must resolve the single
        # applicable method (dispatch-filtered by type at that
        # position) and prove the guard safe, letting the later genuine
        # reconstruction still qualify.
        @asr function probe_guard_qualifies(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if pt_probe(1, p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        function probe_guard_plain(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if pt_probe(1, p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        @test probe_guard_plain(1000) == probe_guard_qualifies(1000)
    end

    @testset "v1.6: opaque call passthrough, short-form helper" begin
        # Same shape, but the resolved helper is a short-form def
        # (`f(...) = expr`) - the exact AST shape of Sockets.jl's own
        # `bind(sock, addr) = bind(sock, addr.host, addr.port)`, which
        # find_function_def_by_arity must locate just as reliably as a
        # long-form def.
        @asr function probe_guard_short_qualifies(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if pt_probe_short(1, p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        function probe_guard_short_plain(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if pt_probe_short(1, p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        @test probe_guard_short_plain(1000) == probe_guard_short_qualifies(1000)
    end

    @testset "v1.6: ambiguous dispatch at the accumulator's position declines" begin
        # Two methods of `ambiguous_probe` share the same arity and BOTH
        # accept Point at position 2 (differing only in the OTHER
        # argument's type, which verify_safe_passthrough_arg does not
        # filter on) - this must resolve to two candidate methods and
        # decline rather than silently picking one, since which method
        # actually runs depends on a call-site argument type this
        # transform never inspects.
        ex = :(function f(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if ambiguous_probe(1, p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end

    @testset "v1.6: opaque call passthrough to a parametric method does not crash" begin
        # The regression itself: `parametric_probe` is called with the
        # accumulator at position 2, and the ONLY applicable method is
        # parametric (`where T`) - resolving it must not raise past
        # AsrDecline, and since its body only reads q.x/q.y, it should
        # actually qualify.
        @asr function parametric_guard_qualifies(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if parametric_probe(Int[], p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        function parametric_guard_plain(n)
            p = Point(0.0, 0.0)
            i = 0
            while i < n
                if parametric_probe(Int[], p) > 1.0e18
                    error("unreachable")
                end
                p = Point(p.x + 1.0, p.y + 2.0)
                i += 1
            end
            return p.x + p.y
        end
        @test parametric_guard_plain(1000) == parametric_guard_qualifies(1000)
    end

    @testset "multi: cross-accumulator scalar name collision" begin
        struct R1
            y
        end
        struct R2
            x_y
        end
        # scalar_name(:a_x, :y) and scalar_name(:a, :x_y) both synthesize
        # :a_x_y - a genuine cross-accumulator collision, distinct from
        # the existing same-accumulator collision check.
        ex = :(function f(n)
            a_x = R1(0.0)
            a = R2(0.0)
            i = 0
            while i < n
                a_x = R1(a_x.y + 1.0)
                a = R2(a.x_y + 1.0)
                i += 1
            end
            return a_x.y + a.x_y
        end)
        @test decline_unchanged(ex, @__MODULE__)
    end
end

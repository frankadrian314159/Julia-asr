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

@testset "AsrTransform positive cases" begin
    @test plain_full(1000) == asr_full(1000)
    @test plain_partial(500) == asr_partial(500)
    @test plain_guard(30) == asr_guard(30)
    @test plain_bare_return(1000) == asr_bare_return(1000)
    @test plain_early_return(1000) == asr_early_return(1000)
    @test plain_let_struct(500) == asr_let_struct(500)

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

struct Paramed{T}
    x::T
    y::T
end

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

    @testset "parametric struct accumulator" begin
        ex = :(function f(n)
            p = Paramed(0.0, 0.0)
            i = 0
            while i < n
                p = Paramed(p.x + 1.0, p.y + 2.0)
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
end

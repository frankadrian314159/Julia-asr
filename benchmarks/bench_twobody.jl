# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-twobody.fol. Multi-accumulator
# (v1.3): two accumulators of the SAME record type, each reading the
# other's value every step. Note: unlike FOL/BEAM's simultaneous
# `recur`/parallel-call update, this is two SEQUENTIAL Julia statements,
# so `b`'s update sees `a`'s already-updated value - a genuine, natural
# semantic difference for an imperative host language, not a porting bug
# (baseline and @asr'd versions are verified bit-identical either way).

struct Vec2
    x
    y
end

function twobody_plain(n)
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

@asr function twobody_asr(n)
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

function twobody_counted(n, counter::Counter)
    reset!(counter)
    a = Vec2(0.0, 0.0)
    bump!(counter)
    b = Vec2(1.0, 1.0)
    bump!(counter)
    i = 0
    while i < n
        a = Vec2(a.x + 0.01 * (b.x - a.x), a.y + 0.01 * (b.y - a.y))
        bump!(counter)
        b = Vec2(b.x + 0.01 * (a.x - b.x), b.y + 0.01 * (a.y - b.y))
        bump!(counter)
        i += 1
    end
    return a.x + a.y
end

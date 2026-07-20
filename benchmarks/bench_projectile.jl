# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-projectile.fol. `nvy` is
# bound once and reused in two field expressions, exercising ASR's
# peeling of a single-form intermediate-binding layer (v1.1).

struct State3
    x
    y
    vy
end

function advance(s)
    nvy = s.vy - 0.098
    State3(s.x + 1.0, s.y + nvy, nvy)
end

function projectile_plain(n)
    s = State3(0.0, 0.0, 20.0)
    i = 0
    while i < n
        s = advance(s)
        i += 1
    end
    return s.x + s.y + s.vy
end

@asr function projectile_asr(n)
    s = State3(0.0, 0.0, 20.0)
    i = 0
    while i < n
        s = advance(s)
        i += 1
    end
    return s.x + s.y + s.vy
end

function advance_counted(s, counter::Counter)
    bump!(counter)
    nvy = s.vy - 0.098
    State3(s.x + 1.0, s.y + nvy, nvy)
end

function projectile_counted(n, counter::Counter)
    reset!(counter)
    s = State3(0.0, 0.0, 20.0)
    bump!(counter)
    i = 0
    while i < n
        s = advance_counted(s, counter)
        i += 1
    end
    return s.x + s.y + s.vy
end

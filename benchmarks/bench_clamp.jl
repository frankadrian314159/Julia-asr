# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-clamp.fol. Branch-shaped
# reconstruction (v1.2): two-way if/else, position clamped to a boundary.

struct ClampPoint
    x
    y
end

function clamp_plain(n)
    p = ClampPoint(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 100.0
            p = ClampPoint(0.0, p.y)
        else
            p = ClampPoint(p.x + 1.0, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

@asr function clamp_asr(n)
    p = ClampPoint(0.0, 0.0)
    i = 0
    while i < n
        if p.x > 100.0
            p = ClampPoint(0.0, p.y)
        else
            p = ClampPoint(p.x + 1.0, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

function clamp_counted(n, counter::Counter)
    reset!(counter)
    p = ClampPoint(0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        if p.x > 100.0
            p = ClampPoint(0.0, p.y)
            bump!(counter)
        else
            p = ClampPoint(p.x + 1.0, p.y + 0.5)
            bump!(counter)
        end
        i += 1
    end
    return p.x + p.y
end

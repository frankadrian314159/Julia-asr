# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).

struct AssocParticle
    x
    y
    vx
    vy
end

function assoc_plain(n)
    p = AssocParticle(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        p = AssocParticle(p.x, p.y, p.vx + 0.1, p.vy)
        i += 1
    end
    return p.x + p.y + p.vx + p.vy
end

@asr function assoc_asr(n)
    p = AssocParticle(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        p = AssocParticle(p.x, p.y, p.vx + 0.1, p.vy)
        i += 1
    end
    return p.x + p.y + p.vx + p.vy
end

function assoc_counted(n, counter::Counter)
    reset!(counter)
    p = AssocParticle(0.0, 0.0, 0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        p = AssocParticle(p.x, p.y, p.vx + 0.1, p.vy)
        bump!(counter)
        i += 1
    end
    return p.x + p.y + p.vx + p.vy
end

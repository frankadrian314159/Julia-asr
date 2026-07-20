# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).

struct Particle
    x
    y
end

function particle_plain(n)
    p = Particle(0.0, 0.0)
    i = 0
    while i < n
        p = Particle(p.x + 0.1, p.y + 0.2)
        i += 1
    end
    return p.x + p.y
end

@asr function particle_asr(n)
    p = Particle(0.0, 0.0)
    i = 0
    while i < n
        p = Particle(p.x + 0.1, p.y + 0.2)
        i += 1
    end
    return p.x + p.y
end

function particle_counted(n, counter::Counter)
    reset!(counter)
    p = Particle(0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        p = Particle(p.x + 0.1, p.y + 0.2)
        bump!(counter)
        i += 1
    end
    return p.x + p.y
end

# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-bounce.fol. Branch-shaped
# reconstruction (v1.2): three-way if/elseif/else, bounce off two walls.

struct Bounce
    x
    y
end

function bounce_plain(n)
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

@asr function bounce_asr(n)
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

function bounce_counted(n, counter::Counter)
    reset!(counter)
    p = Bounce(0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        if p.x > 100.0
            p = Bounce(0.0, p.y)
            bump!(counter)
        elseif p.x < -100.0
            p = Bounce(0.0, p.y)
            bump!(counter)
        else
            p = Bounce(p.x + 1.0, p.y + 0.5)
            bump!(counter)
        end
        i += 1
    end
    return p.x + p.y
end

# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-phase.fol. Branch-shaped
# reconstruction (v1.2): three-way if/elseif/else on `i % 3`, one of
# three phase reconstructions per iteration.

struct Phase
    x
    y
end

function phase_plain(n)
    p = Phase(0.0, 0.0)
    i = 0
    while i < n
        if i % 3 == 0
            p = Phase(p.x + 1.0, p.y)
        elseif i % 3 == 1
            p = Phase(p.x, p.y + 2.0)
        else
            p = Phase(p.x + 0.5, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

@asr function phase_asr(n)
    p = Phase(0.0, 0.0)
    i = 0
    while i < n
        if i % 3 == 0
            p = Phase(p.x + 1.0, p.y)
        elseif i % 3 == 1
            p = Phase(p.x, p.y + 2.0)
        else
            p = Phase(p.x + 0.5, p.y + 0.5)
        end
        i += 1
    end
    return p.x + p.y
end

function phase_counted(n, counter::Counter)
    reset!(counter)
    p = Phase(0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        if i % 3 == 0
            p = Phase(p.x + 1.0, p.y)
            bump!(counter)
        elseif i % 3 == 1
            p = Phase(p.x, p.y + 2.0)
            bump!(counter)
        else
            p = Phase(p.x + 0.5, p.y + 0.5)
            bump!(counter)
        end
        i += 1
    end
    return p.x + p.y
end

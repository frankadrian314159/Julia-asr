# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-lorenz.fol. Chaotic ODE
# integrator, interprocedural inlining (v1.1) with intermediate
# bindings, three-field record.

struct Lvec3
    x
    y
    z
end

function lorenz_step(p)
    x = p.x
    y = p.y
    z = p.z
    dx = 10.0 * (y - x)
    dy = (x * (28.0 - z)) - y
    dz = (x * y) - (2.6666667 * z)
    Lvec3(x + (dx * 0.01), y + (dy * 0.01), z + (dz * 0.01))
end

function lorenz_plain(n)
    p = Lvec3(1.0, 1.0, 1.0)
    i = 0
    while i < n
        p = lorenz_step(p)
        i += 1
    end
    return p.x + p.y + p.z
end

@asr function lorenz_asr(n)
    p = Lvec3(1.0, 1.0, 1.0)
    i = 0
    while i < n
        p = lorenz_step(p)
        i += 1
    end
    return p.x + p.y + p.z
end

function lorenz_step_counted(p, counter::Counter)
    bump!(counter)
    x = p.x
    y = p.y
    z = p.z
    dx = 10.0 * (y - x)
    dy = (x * (28.0 - z)) - y
    dz = (x * y) - (2.6666667 * z)
    Lvec3(x + (dx * 0.01), y + (dy * 0.01), z + (dz * 0.01))
end

function lorenz_counted(n, counter::Counter)
    reset!(counter)
    p = Lvec3(1.0, 1.0, 1.0)
    bump!(counter)
    i = 0
    while i < n
        p = lorenz_step_counted(p, counter)
        i += 1
    end
    return p.x + p.y + p.z
end

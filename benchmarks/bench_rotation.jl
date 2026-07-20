# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-rotation.fol. Interprocedural
# inlining (v1.1): the reconstruction lives in a helper with no
# intermediate bindings, coupled multiplicative update.

struct Rot
    re
    im
end

function rotate(z)
    Rot(z.re * 0.9950041652780258 - z.im * 0.09983341664682815,
        z.re * 0.09983341664682815 + z.im * 0.9950041652780258)
end

function rotation_plain(n)
    z = Rot(1.0, 0.0)
    i = 0
    while i < n
        z = rotate(z)
        i += 1
    end
    return z.re + z.im
end

@asr function rotation_asr(n)
    z = Rot(1.0, 0.0)
    i = 0
    while i < n
        z = rotate(z)
        i += 1
    end
    return z.re + z.im
end

function rotate_counted(z, counter::Counter)
    bump!(counter)
    Rot(z.re * 0.9950041652780258 - z.im * 0.09983341664682815,
        z.re * 0.09983341664682815 + z.im * 0.9950041652780258)
end

function rotation_counted(n, counter::Counter)
    reset!(counter)
    z = Rot(1.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        z = rotate_counted(z, counter)
        i += 1
    end
    return z.re + z.im
end

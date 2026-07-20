# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-mandelbrot.fol. Coupled
# quadratic update, interprocedural inlining (v1.1) with intermediate
# bindings.

struct Cplx
    re
    im
end

function mandel_step(z)
    zr = z.re
    zi = z.im
    Cplx(((zr * zr) - (zi * zi)) + (-0.123), (2.0 * (zr * zi)) + 0.745)
end

function mandelbrot_plain(n)
    z = Cplx(0.0, 0.0)
    i = 0
    while i < n
        z = mandel_step(z)
        i += 1
    end
    return z.re + z.im
end

@asr function mandelbrot_asr(n)
    z = Cplx(0.0, 0.0)
    i = 0
    while i < n
        z = mandel_step(z)
        i += 1
    end
    return z.re + z.im
end

function mandel_step_counted(z, counter::Counter)
    bump!(counter)
    zr = z.re
    zi = z.im
    Cplx(((zr * zr) - (zi * zi)) + (-0.123), (2.0 * (zr * zi)) + 0.745)
end

function mandelbrot_counted(n, counter::Counter)
    reset!(counter)
    z = Cplx(0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        z = mandel_step_counted(z, counter)
        i += 1
    end
    return z.re + z.im
end

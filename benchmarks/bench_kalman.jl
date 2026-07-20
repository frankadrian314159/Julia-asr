# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-kalman.fol. Multi-accumulator
# (v1.3): two coupled record accumulators, asymmetric field counts.

struct Kstate
    x
    v
end
struct Kcov
    p00
    p01
    p11
end

function kalman_plain(n)
    s = Kstate(0.0, 0.0)
    c = Kcov(1.0, 0.0, 1.0)
    i = 0
    while i < n
        x = s.x
        v = s.v
        p00 = c.p00
        p01 = c.p01
        p11 = c.p11
        xp = x + v
        pp00 = (p00 + 2.0 * p01) + (p11 + 0.001)
        pp01 = p01 + p11
        pp11 = p11 + 0.001
        y = 10.0 - xp
        sden = pp00 + 0.1
        k0 = pp00 / sden
        k1 = pp01 / sden
        s = Kstate(xp + k0 * y, v + k1 * y)
        c = Kcov((1.0 - k0) * pp00, (1.0 - k0) * pp01, pp11 - k1 * pp01)
        i += 1
    end
    return s.x
end

@asr function kalman_asr(n)
    s = Kstate(0.0, 0.0)
    c = Kcov(1.0, 0.0, 1.0)
    i = 0
    while i < n
        x = s.x
        v = s.v
        p00 = c.p00
        p01 = c.p01
        p11 = c.p11
        xp = x + v
        pp00 = (p00 + 2.0 * p01) + (p11 + 0.001)
        pp01 = p01 + p11
        pp11 = p11 + 0.001
        y = 10.0 - xp
        sden = pp00 + 0.1
        k0 = pp00 / sden
        k1 = pp01 / sden
        s = Kstate(xp + k0 * y, v + k1 * y)
        c = Kcov((1.0 - k0) * pp00, (1.0 - k0) * pp01, pp11 - k1 * pp01)
        i += 1
    end
    return s.x
end

function kalman_counted(n, s_counter::Counter, c_counter::Counter)
    reset!(s_counter)
    reset!(c_counter)
    s = Kstate(0.0, 0.0)
    bump!(s_counter)
    c = Kcov(1.0, 0.0, 1.0)
    bump!(c_counter)
    i = 0
    while i < n
        x = s.x
        v = s.v
        p00 = c.p00
        p01 = c.p01
        p11 = c.p11
        xp = x + v
        pp00 = (p00 + 2.0 * p01) + (p11 + 0.001)
        pp01 = p01 + p11
        pp11 = p11 + 0.001
        y = 10.0 - xp
        sden = pp00 + 0.1
        k0 = pp00 / sden
        k1 = pp01 / sden
        s = Kstate(xp + k0 * y, v + k1 * y)
        bump!(s_counter)
        c = Kcov((1.0 - k0) * pp00, (1.0 - k0) * pp01, pp11 - k1 * pp01)
        bump!(c_counter)
        i += 1
    end
    return s.x
end

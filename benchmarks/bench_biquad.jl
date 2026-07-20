# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-biquad.fol. Interprocedural
# inlining (v1.1) with intermediate bindings, four-field record.

struct Biquad
    x1
    x2
    y1
    y2
end

function biquad_step(st)
    x1 = st.x1
    x2 = st.x2
    y1 = st.y1
    y2 = st.y2
    xin = 1.0
    y = (((0.1 * xin) + (0.2 * x1)) + (0.1 * x2) + (0.9 * y1)) - (0.2 * y2)
    Biquad(xin, x1, y, y1)
end

function biquad_plain(n)
    st = Biquad(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        st = biquad_step(st)
        i += 1
    end
    return st.y1
end

@asr function biquad_asr(n)
    st = Biquad(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        st = biquad_step(st)
        i += 1
    end
    return st.y1
end

function biquad_step_counted(st, counter::Counter)
    bump!(counter)
    x1 = st.x1
    x2 = st.x2
    y1 = st.y1
    y2 = st.y2
    xin = 1.0
    y = (((0.1 * xin) + (0.2 * x1)) + (0.1 * x2) + (0.9 * y1)) - (0.2 * y2)
    Biquad(xin, x1, y, y1)
end

function biquad_counted(n, counter::Counter)
    reset!(counter)
    st = Biquad(0.0, 0.0, 0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        st = biquad_step_counted(st, counter)
        i += 1
    end
    return st.y1
end

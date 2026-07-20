# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).
# Ported from FOL's benchmarks/fol-code/asr-comoments.fol. Welford-style
# streaming co-moments, interprocedural inlining (v1.1) with running
# divisions, four-field record.

struct Comoments
    n
    mx
    my
    cxy
end

function comoment_step(st)
    n = st.n
    mx = st.mx
    my = st.my
    cxy = st.cxy
    n1 = n + 1.0
    dx = 1.0 - mx
    mx1 = mx + (dx / n1)
    dy = 2.0 - my
    my1 = my + (dy / n1)
    dy2 = 2.0 - my1
    Comoments(n1, mx1, my1, cxy + (dx * dy2))
end

function comoments_plain(n)
    st = Comoments(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        st = comoment_step(st)
        i += 1
    end
    return st.cxy
end

@asr function comoments_asr(n)
    st = Comoments(0.0, 0.0, 0.0, 0.0)
    i = 0
    while i < n
        st = comoment_step(st)
        i += 1
    end
    return st.cxy
end

function comoment_step_counted(st, counter::Counter)
    bump!(counter)
    n = st.n
    mx = st.mx
    my = st.my
    cxy = st.cxy
    n1 = n + 1.0
    dx = 1.0 - mx
    mx1 = mx + (dx / n1)
    dy = 2.0 - my
    my1 = my + (dy / n1)
    dy2 = 2.0 - my1
    Comoments(n1, mx1, my1, cxy + (dx * dy2))
end

function comoments_counted(n, counter::Counter)
    reset!(counter)
    st = Comoments(0.0, 0.0, 0.0, 0.0)
    bump!(counter)
    i = 0
    while i < n
        st = comoment_step_counted(st, counter)
        i += 1
    end
    return st.cxy
end

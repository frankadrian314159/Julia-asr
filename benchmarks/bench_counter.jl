# Assumes AsrTransform and BenchUtil are already loaded (see run_all.jl).

struct Ctr
    n
end

function counter_plain(n)
    c = Ctr(0.0)
    i = 0
    while i < n
        c = Ctr(c.n + 1.0)
        i += 1
    end
    return c.n
end

@asr function counter_asr(n)
    c = Ctr(0.0)
    i = 0
    while i < n
        c = Ctr(c.n + 1.0)
        i += 1
    end
    return c.n
end

function counter_counted(n, counter::Counter)
    reset!(counter)
    c = Ctr(0.0)
    bump!(counter)
    i = 0
    while i < n
        c = Ctr(c.n + 1.0)
        bump!(counter)
        i += 1
    end
    return c.n
end

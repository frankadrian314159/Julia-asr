module BenchUtil

export Counter, reset!, bump!, mean_time_ms

mutable struct Counter
    n::Int
end
Counter() = Counter(0)

reset!(c::Counter) = (c.n = 0; c)
bump!(c::Counter) = (c.n += 1; c)

function mean_time_ms(f, trials::Int)
    # `sink[]` forces the result to escape the loop, so the JIT can't
    # prove f()'s return value is unused and dead-code-eliminate the
    # entire call (confirmed happening without this: a naive version
    # timed 500,000 iterations at ~77ns, i.e. the whole loop vanished).
    sink = Ref{Any}(f()) # warmup
    total = 0.0
    for _ in 1:trials
        t0 = time_ns()
        sink[] = f()
        total += (time_ns() - t0) / 1e6
    end
    isnan(sink[]) && error("unreachable: sink used only to block DCE")
    return total / trials
end

end # module

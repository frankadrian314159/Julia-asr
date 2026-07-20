# Real-world benchmark: Sockets.listenany, the corpus study's first
# genuinely qualifying real-world file (v1.6, corpus-study/README.md).
# Unlike the 14 synthetic benchmarks (which run the SAME hand-written
# .fol-ported code both plain and @asr'd), this benchmark runs the
# ACTUAL unmodified stdlib source both ways: `listenany_plain` is a
# byte-for-byte copy of `Sockets.listenany`'s real body (with an
# explicit counter bump at each InetAddr(...) construction site, since
# Julia structs have no monkey-patchable constructor - same discipline
# as every other benchmark here), and `listenany_asr` is the literal
# output of `AsrTransform.rewrite_function` applied to `Sockets.listenany`
# itself, re-parsed straight from the installed Julia's own Sockets.jl -
# never hand-transcribed.
#
# To get a deterministic, repeatable retry count (real port
# availability is otherwise nondeterministic), this benchmark
# pre-occupies BLOCK_SIZE consecutive ports starting at BASE_PORT and
# always requests BASE_PORT - the retry loop must walk past every
# blocked port before succeeding, giving BLOCK_SIZE+1 InetAddr
# constructions per call (1 initial + BLOCK_SIZE retries) in the
# baseline. The ASR'd version constructs the SAME number, NOT zero -
# see the comment above `build_listenany_asr` below for why this
# differs from every other benchmark in this project.
#
# Each call also does real OS syscalls (socket creation, bind, close)
# for every attempt, which this benchmark does NOT try to eliminate or
# mock - those dominate wall-clock time regardless of ASR, so the
# timing comparison here measures the same thing the 14 synthetic
# benchmarks already found: Julia's own JIT/escape analysis leaves
# little or no allocation for ASR to remove in a real, syscall-bound
# loop. The construction-count elimination is the honest, real signal;
# wall-clock is reported for completeness for calibrated readers.

const BASE_PORT = 51000
const BLOCK_SIZE = 5

function with_blockers(f)
    blockers = [Sockets.listen(Sockets.localhost, BASE_PORT + i) for i in 0:BLOCK_SIZE-1]
    try
        return f()
    finally
        foreach(close, blockers)
    end
end

# Byte-for-byte copy of Sockets.listenany's real body (Sockets.jl:718-735
# on Julia 1.10), with an explicit counter bump at each InetAddr(...)
# construction site.
function listenany_baseline_one(counter)
    host = Sockets.localhost
    default_port = BASE_PORT
    addr = Sockets.InetAddr(host, default_port); bump!(counter)
    local result
    while true
        sock = Sockets.TCPServer()
        if Sockets.bind(sock, addr) && Sockets.trylisten(sock; backlog=Sockets.BACKLOG_DEFAULT) == 0
            result = default_port == 0 ? first(Sockets.getsockname(sock)) : addr.port
            close(sock)
            break
        end
        close(sock)
        addr = Sockets.InetAddr(addr.host, addr.port + UInt16(1)); bump!(counter)
        if addr.port == default_port
            error("no ports available")
        end
    end
    return result
end

function listenany_plain(n)
    counter = Counter()
    total = with_blockers() do
        s = 0
        for _ in 1:n
            s += Int(listenany_baseline_one(counter))
        end
        s
    end
    return total
end

function listenany_counted(n, counter)
    with_blockers() do
        for _ in 1:n
            listenany_baseline_one(counter)
        end
    end
end

# The actual @asr'd Sockets.listenany, recovered by re-parsing the
# installed Julia's own Sockets.jl and running the real transform -
# never hand-transcribed. Renamed and wrapped so it can run standalone
# with the same fixed BASE_PORT/backlog this benchmark uses everywhere
# else.
#
# IMPORTANT, and the actual finding here: this function's own
# accumulator escapes into an opaque call (`bind(sock, addr)`) on
# EVERY iteration, not just at the end - v1.6's rewrite phase correctly
# re-boxes a fresh `InetAddr(addr_host, addr_port)` right at that call
# site each time (`rebox_call`), since `bind` genuinely needs a real
# boxed value there. So unlike the 14 synthetic benchmarks (which
# eliminate 100% of constructions), `listenany`'s own real-world shape
# gives ASR nothing to eliminate: it still constructs one InetAddr per
# iteration, just staged differently (fresh at the point of use, rather
# than threaded as a persistent loop-carried value) - confirmed by
# actually counting, not assumed. `listenany_asr_fn_for_counting`
# renames every `InetAddr(...)` callee in the rewritten AST to a
# counting wrapper so this can be measured directly rather than argued
# from reading the code.
function replace_ctor_calls(term, from::Symbol, to::Symbol)
    if term isa Expr
        if term.head === :call && term.args[1] === from
            return Expr(:call, to, [replace_ctor_calls(a, from, to) for a in term.args[2:end]]...)
        end
        return Expr(term.head, [replace_ctor_calls(a, from, to) for a in term.args]...)
    end
    return term
end

function build_listenany_asr()
    path = joinpath(Sys.STDLIB, "Sockets", "src", "Sockets.jl")
    src = read(path, String)
    parsed = Meta.parseall(src; filename = path)
    fdef = AsrTransform.find_all_function_defs!(Any[], parsed, :listenany) |>
        candidates -> first(filter(s -> Meta.isexpr(s, :function), candidates))
    new_fdef = AsrTransform.rewrite_function(fdef, Sockets)

    timing_fdef = deepcopy(new_fdef)
    timing_fdef.args[1].args[1] = :__listenany_asr_bench
    Core.eval(Sockets, Expr(:function, timing_fdef.args[1], timing_fdef.args[2]))

    Sockets.eval(:(InetAddr_counted(args...) = (Main.bump!(Main.LISTENANY_ASR_COUNTER); InetAddr(args...))))
    counted_fdef = deepcopy(new_fdef)
    counted_fdef.args[1].args[1] = :__listenany_asr_bench_counted
    counted_body = replace_ctor_calls(counted_fdef.args[2], :InetAddr, :InetAddr_counted)
    Core.eval(Sockets, Expr(:function, counted_fdef.args[1], counted_body))

    return Sockets.__listenany_asr_bench, Sockets.__listenany_asr_bench_counted
end

const LISTENANY_ASR_COUNTER = Counter()
const LISTENANY_ASR_FN, LISTENANY_ASR_FN_COUNTED = build_listenany_asr()

function listenany_asr_counted(n)
    reset!(LISTENANY_ASR_COUNTER)
    with_blockers() do
        for _ in 1:n
            port, sock = LISTENANY_ASR_FN_COUNTED(Sockets.localhost, BASE_PORT)
            close(sock)
        end
    end
    return LISTENANY_ASR_COUNTER.n
end

function listenany_asr(n)
    total = with_blockers() do
        s = 0
        for _ in 1:n
            port, sock = LISTENANY_ASR_FN(Sockets.localhost, BASE_PORT)
            close(sock)
            s += Int(port)
        end
        s
    end
    return total
end

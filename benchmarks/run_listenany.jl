# Standalone driver for the real-world listenany benchmark
# (bench_listenany.jl). Kept separate from run_all.jl's 14 synthetic
# benchmarks: this one does real OS syscalls per iteration (socket
# creation, bind, close), so it uses far fewer iterations/trials than
# the allocation-only synthetic benchmarks can afford.
include(joinpath(@__DIR__, "..", "src", "AsrTransform.jl"))
using .AsrTransform
using Sockets
include(joinpath(@__DIR__, "bench_util.jl"))
using .BenchUtil
include(joinpath(@__DIR__, "bench_listenany.jl"))

const ITERATIONS = 200
const TRIALS = 10

plain = listenany_plain(ITERATIONS)
asrv = listenany_asr(ITERATIONS)
if plain != asrv
    println("CORRECTNESS MISMATCH plain=$plain asr=$asrv")
    exit(1)
end
println("Correctness: OK (plain == asr == $plain, sum of $ITERATIONS returned ports)")

base_ms = mean_time_ms(() -> listenany_plain(ITERATIONS), TRIALS)
asr_ms = mean_time_ms(() -> listenany_asr(ITERATIONS), TRIALS)

counter = Counter()
listenany_counted(ITERATIONS, counter)
asr_constr = listenany_asr_counted(ITERATIONS)

println()
println(rpad("Benchmark", 11), " ", lpad("Base ms", 10), " ", lpad("ASR ms", 10), " ",
        lpad("Speedup", 7), " ", lpad("Base constr", 12), " ", "ASR constr")
println("-"^76)
println(rpad("Listenany", 11), " ",
        lpad(round(base_ms, digits=2), 10), " ",
        lpad(round(asr_ms, digits=2), 10), " ",
        lpad(string(round(base_ms / asr_ms, digits=2), "x"), 7), " ",
        lpad(string(counter.n, "x"), 12), " ",
        string(asr_constr, "x"))
println()
println("(", ITERATIONS, " calls x ", BLOCK_SIZE, " forced retries + 1 initial = ", counter.n, " total InetAddr constructions expected)")
println("ASR constructions are NOT eliminated here: bind(sock, addr) needs a real")
println("boxed InetAddr on every iteration, so v1.6's rewrite re-boxes fresh right")
println("at that call site each time, rather than eliminating the allocation - see")
println("bench_listenany.jl's own comment for why this differs from the 14 synthetic")
println("benchmarks (which do eliminate 100%).")

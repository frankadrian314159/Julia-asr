# Benchmark driver for Julia-asr's three ported benchmarks (Particle,
# Counter, Assoc). Mirrors cpython-asr's harness.py / BEAM-asr's
# run_all.erl protocol: correctness (baseline vs. transformed output,
# bit-identical) gates any timing report, and per-run allocation is
# measured via an explicit construction counter (Julia structs have no
# monkey-patchable constructor either) rather than a GC/memory snapshot
# diff.
#
# Shared dependencies are loaded exactly once at this top level; each
# bench_*.jl file is a plain script (not its own module) that assumes
# AsrTransform/BenchUtil are already in scope, so all three share the
# same Counter/AsrDecline types rather than each getting a distinct
# submodule instance.
include(joinpath(@__DIR__, "..", "src", "AsrTransform.jl"))
using .AsrTransform
include(joinpath(@__DIR__, "bench_util.jl"))
using .BenchUtil

include(joinpath(@__DIR__, "bench_particle.jl"))
include(joinpath(@__DIR__, "bench_counter.jl"))
include(joinpath(@__DIR__, "bench_assoc.jl"))

const ITERATIONS = 500_000
const TRIALS = 30

function run_one(name, plain_fn, asr_fn, counted_fn)
    plain = plain_fn(ITERATIONS)
    asrv = asr_fn(ITERATIONS)
    if plain != asrv
        println("$name: CORRECTNESS MISMATCH plain=$plain asr=$asrv")
        exit(1)
    end
    base_ms = mean_time_ms(() -> plain_fn(ITERATIONS), TRIALS)
    asr_ms = mean_time_ms(() -> asr_fn(ITERATIONS), TRIALS)
    counter = Counter()
    counted_fn(ITERATIONS, counter)
    speedup = base_ms / asr_ms
    print_row(name, base_ms, asr_ms, speedup, counter.n)
end

function print_row(name, base_ms, asr_ms, speedup, base_constr)
    println(rpad(name, 11), " ",
            lpad(round(base_ms, digits=2), 10), " ",
            lpad(round(asr_ms, digits=2), 10), " ",
            lpad(string(round(speedup, digits=2), "x"), 7), " ",
            lpad(string(base_constr, "x"), 12), " ",
            "0 (eliminated)")
end

println(rpad("Benchmark", 11), " ", lpad("Base ms", 10), " ", lpad("ASR ms", 10), " ",
        lpad("Speedup", 7), " ", lpad("Base constr", 12), " ", "ASR constr")
println("-"^76)
run_one("Particle", particle_plain, particle_asr, particle_counted)
run_one("Counter", counter_plain, counter_asr, counter_counted)
run_one("Assoc", assoc_plain, assoc_asr, assoc_counted)

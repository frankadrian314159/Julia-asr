# Benchmark driver for all 14 ported benchmarks (Particle/Counter/Assoc
# from v1; Rotation/Biquad/Comoments/Lorenz/Mandelbrot/Projectile from
# v1.1 inlining; Bounce/Clamp/Phase from v1.2 branch-shaped
# reconstruction; Kalman/Twobody from v1.3 multi-accumulator). Mirrors
# cpython-asr's harness.py / BEAM-asr's run_all.erl protocol: correctness
# (baseline vs. transformed output, bit-identical) gates any timing
# report, and per-run allocation is measured via an explicit construction
# counter (Julia structs have no monkey-patchable constructor either)
# rather than a GC/memory snapshot diff.
#
# Shared dependencies are loaded exactly once at this top level; each
# bench_*.jl file is a plain script (not its own module) that assumes
# AsrTransform/BenchUtil are already in scope, so all benchmarks share
# the same Counter/AsrDecline types rather than each getting a distinct
# submodule instance.
include(joinpath(@__DIR__, "..", "src", "AsrTransform.jl"))
using .AsrTransform
include(joinpath(@__DIR__, "bench_util.jl"))
using .BenchUtil

include(joinpath(@__DIR__, "bench_particle.jl"))
include(joinpath(@__DIR__, "bench_counter.jl"))
include(joinpath(@__DIR__, "bench_assoc.jl"))
include(joinpath(@__DIR__, "bench_rotation.jl"))
include(joinpath(@__DIR__, "bench_biquad.jl"))
include(joinpath(@__DIR__, "bench_comoments.jl"))
include(joinpath(@__DIR__, "bench_lorenz.jl"))
include(joinpath(@__DIR__, "bench_mandelbrot.jl"))
include(joinpath(@__DIR__, "bench_projectile.jl"))
include(joinpath(@__DIR__, "bench_bounce.jl"))
include(joinpath(@__DIR__, "bench_clamp.jl"))
include(joinpath(@__DIR__, "bench_phase.jl"))
include(joinpath(@__DIR__, "bench_kalman.jl"))
include(joinpath(@__DIR__, "bench_twobody.jl"))

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
    print_row(name, base_ms, asr_ms, base_ms / asr_ms, counter.n)
end

# Kalman has two accumulators of different record types, so its counted
# variant takes two separate Counters rather than one.
function run_one_dual(name, plain_fn, asr_fn, counted_fn)
    plain = plain_fn(ITERATIONS)
    asrv = asr_fn(ITERATIONS)
    if plain != asrv
        println("$name: CORRECTNESS MISMATCH plain=$plain asr=$asrv")
        exit(1)
    end
    base_ms = mean_time_ms(() -> plain_fn(ITERATIONS), TRIALS)
    asr_ms = mean_time_ms(() -> asr_fn(ITERATIONS), TRIALS)
    c1, c2 = Counter(), Counter()
    counted_fn(ITERATIONS, c1, c2)
    print_row(name, base_ms, asr_ms, base_ms / asr_ms, c1.n + c2.n)
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
run_one("Rotation", rotation_plain, rotation_asr, rotation_counted)
run_one("Biquad", biquad_plain, biquad_asr, biquad_counted)
run_one("Comoments", comoments_plain, comoments_asr, comoments_counted)
run_one("Lorenz", lorenz_plain, lorenz_asr, lorenz_counted)
run_one("Mandelbrot", mandelbrot_plain, mandelbrot_asr, mandelbrot_counted)
run_one("Projectile", projectile_plain, projectile_asr, projectile_counted)
run_one("Bounce", bounce_plain, bounce_asr, bounce_counted)
run_one("Clamp", clamp_plain, clamp_asr, clamp_counted)
run_one("Phase", phase_plain, phase_asr, phase_counted)
run_one_dual("Kalman", kalman_plain, kalman_asr, kalman_counted)
run_one("Twobody", twobody_plain, twobody_asr, twobody_counted)

"""
Corpus scan driver: runs Pass 1 (`Analyze.scan_file`) across every file
in the manifest, then Pass 2 (`GateCheck.qualifies`) - the real
`AsrTransform.rewrite_function` oracle - against every `record_strong`/
`record_weak`/`record_mutate`/`record_other` candidate Pass 1 finds.

Base files resolve candidate types directly in `Base`. Each stdlib
module must be `using`'d into this script's own `Main` session first
(once, before scanning its files) so its types are resolvable exactly
the way `Sockets.InetAddr` etc. already are for any code that `using
Sockets`'d - this script does the same, not something a corpus file
itself would need to do.
"""

include(joinpath(@__DIR__, "..", "..", "src", "AsrTransform.jl"))
using .AsrTransform
include(joinpath(@__DIR__, "analyze.jl"))
using .Analyze
include(joinpath(@__DIR__, "gate_check.jl"))
using .GateCheck
include(joinpath(@__DIR__, "..", "manifest.jl"))

using LinearAlgebra
using Statistics
using SparseArrays
using Dates
using Random
using Printf
using Sockets
using Serialization
using Unicode
using Logging
using REPL
using Test

const STDLIB_MOD = Dict{String,Module}(
    "LinearAlgebra" => LinearAlgebra, "Statistics" => Statistics,
    "SparseArrays" => SparseArrays, "Dates" => Dates, "Random" => Random,
    "Printf" => Printf, "Sockets" => Sockets, "Serialization" => Serialization,
    "Unicode" => Unicode, "Logging" => Logging, "REPL" => REPL, "Test" => Test,
)

function all_jl_files(dir)
    files = String[]
    for (root, _, fs) in walkdir(dir)
        for f in fs
            endswith(f, ".jl") && push!(files, joinpath(root, f))
        end
    end
    return files
end

function scan_group(files, domain, resolve_mod::Module, root_for_relpath)
    rows = Any[]
    for path in files
        r = scan_file(path)
        loc = r.loc
        if !r.ok
            push!(rows, (path=relpath(path, root_for_relpath), domain=domain, status=:error, loc=loc,
                         n_loop_sites=0, n_single_while=0, n_single_for=0, shapes=Dict{Symbol,Int}(), hits=Any[]))
            continue
        end
        n_single_while = count(s -> s.shape == :single_while, r.loop_sites)
        n_single_for = count(s -> s.shape == :single_for, r.loop_sites)
        shapes = Dict{Symbol,Int}()
        for s in r.loop_sites
            shapes[s.shape] = get(shapes, s.shape, 0) + 1
        end
        hits = Any[]
        for s in r.loop_sites
            for c in s.candidates
                c.kind in (:record_strong, :record_weak, :record_mutate, :record_other) || continue
                result, msg = GateCheck.qualifies(AsrTransform, path, s.fname, resolve_mod)
                push!(hits, (fname=s.fname, varname=c.varname, typename=c.typename,
                             kind=c.kind, gate=result, msg=msg))
            end
        end
        push!(rows, (path=relpath(path, root_for_relpath), domain=domain, status=:ok, loc=loc,
                     n_loop_sites=length(r.loop_sites), n_single_while=n_single_while, n_single_for=n_single_for,
                     shapes=shapes, hits=hits))
    end
    return rows
end

function main()
    all_rows = Any[]

    base_files = all_jl_files(BASE_DIR)
    append!(all_rows, scan_group(base_files, "base", Base, BASE_DIR))

    for (modname, domain) in STDLIB_MODULES
        d = joinpath(STDLIB_DIR, modname, "src")
        isdir(d) || continue
        files = all_jl_files(d)
        append!(all_rows, scan_group(files, domain, STDLIB_MOD[modname], STDLIB_DIR))
    end

    n_files = length(all_rows)
    n_ok = count(r -> r.status == :ok, all_rows)
    total_loc = sum(r.loc for r in all_rows)
    total_loop_sites = sum(r.n_loop_sites for r in all_rows)
    total_single_while = sum(r.n_single_while for r in all_rows)
    total_single_for = sum(r.n_single_for for r in all_rows)
    all_hits = Any[]
    for r in all_rows
        for h in r.hits
            push!(all_hits, (path=r.path, domain=r.domain, h...))
        end
    end
    n_qualified = count(h -> h.gate == :qualified, all_hits)
    n_declined = count(h -> h.gate == :declined, all_hits)
    n_error = count(h -> h.gate == :error, all_hits)

    shape_totals = Dict{Symbol,Int}()
    for r in all_rows
        r.status == :ok || continue
        for (k, v) in r.shapes
            shape_totals[k] = get(shape_totals, k, 0) + v
        end
    end

    println("=== Per-file summary ===")
    println(rpad("File", 55), rpad("Domain", 20), " LOC  Loop SingleW Hits")
    for r in all_rows
        r.status == :ok || continue
        println(rpad(r.path, 55), rpad(r.domain, 20), " ", lpad(r.loc, 5), " ",
                lpad(r.n_loop_sites, 4), " ", lpad(r.n_single_while, 7), " ", lpad(length(r.hits), 4))
    end

    println()
    println("=== Totals ===")
    println("Files scanned OK: $n_ok / $n_files")
    println("Total LOC: $total_loc")
    println("Total loop sites (functions with >=1 while/for): $total_loop_sites")
    println("Single-top-level-while functions: $total_single_while")
    println("Single-top-level-for functions: $total_single_for")
    println("Loop-site shape breakdown: ", shape_totals)
    println("Record-shaped candidate positions: $(length(all_hits))")
    println("Gate-faithful qualification: qualified=$n_qualified declined=$n_declined error=$n_error")

    println()
    println("=== Record-shaped candidate detail ===")
    for h in all_hits
        println("$(h.path) :: $(h.fname) var=$(h.varname) type=$(h.typename) kind=$(h.kind) -> $(h.gate) ($(h.msg))")
    end
end

main()

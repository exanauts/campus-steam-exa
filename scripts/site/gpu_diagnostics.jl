# Solver diagnostics behind docs/gpu-notes.md: inertia regularization, restoration and iterative
# refinement per solve, and the effect of variable scaling. All data is synthetic.
#
#   CUDA_VISIBLE_DEVICES=<gpu> julia --project=scripts scripts/site/gpu_diagnostics.jl
#
# Writes results/gpu_diagnostics.csv. This is a local study and is not part of the site build.

using CUDA
using CUDSS
using Dates
using MadNLP
using MadNLPGPU
using Printf

include(joinpath(@__DIR__, "bench_common.jl"))

const DIAG_ROOT = dirname(dirname(@__DIR__))
const DIAG_REPEATS = 3

# `si_units` removes the fixed references, so pressures are in Pa, powers in W and the objective in W.
const DIAG_VARIANTS = [
    (name = "default", options = CampusSteam.SteamModelOptions(), solver = (;)),
    (name = "no_gradient_scaling", options = CampusSteam.SteamModelOptions(), solver = (; nlp_scaling = false)),
    (
        name = "si_units",
        options = CampusSteam.SteamModelOptions(;
            pressure_ref_Pa = 1.0, temperature_ref_K = 1.0, flow_ref_kg_per_s = 1.0,
            power_ref_W = 1.0, objective_ref_W = 1.0,
        ),
        solver = (;),
    ),
]

function diag_model(id, options, backend)
    net = demo_campus()
    id == "demo" && return build_steam_model(net; options, backend)
    heat_W = generate_profiles(net; hours = parse(Int, id[9:end])).heat_W
    return build_multiperiod_model(net; heat_W, options, backend)
end

# Reads the iteration table of a MadNLP log.
function iteration_stats(path)
    regularized, restoration, iterations = 0, 0, 0
    largest = -Inf
    refinement = Int[]
    columns = String[]
    for line in eachline(path)
        fields = split(line)
        if "lg(rg)" in fields
            columns = String.(fields)
            continue
        end
        (isempty(columns) || length(fields) != length(columns)) && continue
        match(r"^\d+r?$", fields[1]) === nothing && continue
        iterations += 1
        endswith(fields[1], "r") && (restoration += 1)
        value = tryparse(Float64, fields[findfirst(==("lg(rg)"), columns)])
        if value !== nothing
            regularized += 1
            largest = max(largest, value)
        end
        index = findfirst(==("ir"), columns)
        index === nothing || push!(refinement, something(tryparse(Int, fields[index]), 0))
    end
    return (;
        iterations, regularized, restoration,
        largest_lg_rg = isfinite(largest) ? largest : nothing,
        mean_refinement = isempty(refinement) ? nothing : sum(refinement) / length(refinement),
        max_refinement = isempty(refinement) ? nothing : maximum(refinement),
    )
end

cell(::Nothing) = ""
cell(x::AbstractFloat) = isfinite(x) ? @sprintf("%.6g", x) : ""
cell(x) = string(x)

function main()
    commit = strip(read(`git -C $DIAG_ROOT rev-parse HEAD`, String))
    date = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
    header = [
        "commit", "run_date", "case", "device", "variant", "repeat", "status", "iterations", "total_s",
        "iterations_regularized", "largest_lg_rg", "restoration_iterations", "mean_refinement_steps",
        "max_refinement_steps", "objective_W_scaled", "kkt_residual",
    ]
    rows = [join(header, ",")]
    gpu_options = (; richardson_max_iter = 30, richardson_tol = 1.0e-12, cudss_asynchronous = false)
    for id in ("demo", "horizon-24"), variant in DIAG_VARIANTS, device in ("cpu", "gpu")
        host = diag_model(id, variant.options, nothing)
        backend = device == "gpu" ? CUDABackend() : nothing
        # The first solve of each combination compiles and is not recorded.
        for repeat in 0:DIAG_REPEATS
            log = tempname()
            model = diag_model(id, variant.options, backend)
            result = MadNLP.madnlp(
                model.nlp; tol = 1.0e-8, acceptable_tol = 1.0e-8, acceptable_iter = 100_000,
                bound_relax_factor = 1.0e-8, max_iter = 1000, max_wall_time = 120.0,
                print_level = MadNLP.ERROR, output_file = log, file_print_level = MadNLP.INFO,
                (device == "gpu" ? gpu_options : (;))..., variant.solver...,
            )
            stats = iteration_stats(log)
            rm(log; force = true)
            repeat == 0 && continue
            x = Array(result.solution)
            residual = kkt_residuals(
                host.nlp, x, Array(result.multipliers), Array(result.multipliers_L), Array(result.multipliers_U),
            )
            values = Any[
                commit, date, id, device, variant.name, repeat, string(result.status), result.iter,
                result.counters.total_time, stats.regularized, stats.largest_lg_rg, stats.restoration,
                stats.mean_refinement, stats.max_refinement, BenchNLP.obj(host.nlp, x), residual.kkt,
            ]
            push!(rows, join(cell.(values), ","))
            println(rows[end])
            flush(stdout)
        end
    end
    write(joinpath(DIAG_ROOT, "results", "gpu_diagnostics.csv"), join(rows, "\n") * "\n")
    return nothing
end

main()

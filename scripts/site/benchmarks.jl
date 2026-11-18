# CPU, Ipopt and GPU benchmarks of the synthetic campus steam model. See docs/site-data.md.
#
#   run_benchmarks(outdir)                                  CI sweep, called by scripts/run_site.jl
#   julia --project=scripts scripts/site/benchmarks.jl local   fuller sweep, writes results/
#   julia --project=scripts scripts/site/benchmarks.jl year    adds the optional T = 8760 attempt
#
# Compilation is excluded from timed solves by warm-up solves, and the compile time that remains is
# recorded per run. Time to first solve is measured separately in fresh processes.

using CUDA
using CUDSS
using Dates
using JSON
using MadNLP
using MadNLPGPU
using Pkg
using Printf
using Statistics: median

include(joinpath(@__DIR__, "bench_common.jl"))

const BENCH_ROOT = dirname(dirname(@__DIR__))
const SYNTHETIC_LABEL = "All networks and demand profiles are synthetic and describe no real campus."

const BENCH_PROFILES = Dict(
    :ci => (
        size_cases = ["demo", "scaled-200", "scaled-400"],
        horizon_cases = ["horizon-24"],
        repeats = 3, strict_tols = [1.0e-8], ttfs_repeats = 0, ipopt = false,
        budget_s = 270.0, wall_limit_s = 60.0,
    ),
    :local => (
        size_cases = ["demo", "scaled-200", "scaled-300", "scaled-400", "scaled-500", "scaled-600", "scaled-800"],
        horizon_cases = ["horizon-24", "horizon-168", "horizon-720"],
        repeats = 5, strict_tols = [1.0e-6, 1.0e-8], ttfs_repeats = 3, ipopt = true,
        budget_s = Inf, wall_limit_s = 1800.0,
    ),
    :year => (
        size_cases = String[], horizon_cases = ["horizon-8760"],
        repeats = 1, strict_tols = Float64[], ttfs_repeats = 0, ipopt = false,
        budget_s = Inf, wall_limit_s = 1800.0,
    ),
)

const CPU_SOLVER = "cpu_madnlp_mumps"
const GPU_SOLVER = "gpu_madnlp_cudss"
const GPU_ASYNC_SOLVER = "gpu_madnlp_cudss_async"
const IPOPT_SOLVER = "cpu_ipopt_mumps"

# Refinement settings of the multi-period measurements in docs/model-notes.md. The synchronous mode
# is what makes MadNLP report linear solver time; the asynchronous variant is the package default.
const GPU_REFINEMENT = (; richardson_max_iter = 30, richardson_tol = 1.0e-12)

const CSV_COLUMNS = [
    "run_profile", "commit", "run_date", "case", "family", "junctions", "periods", "solver", "mode",
    "tol_requested", "repeat", "nvar", "ncon", "nnzj", "nnzh", "status", "iterations", "build_s",
    "total_s", "linear_s", "eval_s", "other_s", "compile_s", "objective", "primal_residual",
    "dual_residual", "complementarity_residual", "kkt_residual", "objective_rel", "plant_output_rel",
    "steam_pressure_rel", "steam_temperature_rel", "steam_flow_rel", "nonunique_water_pressure_rel",
    "nonunique_return_temperature_rel", "nonunique_light_flow_rel", "gpu_peak_mib",
    "gpu_other_processes", "error",
]

# Environment -------------------------------------------------------------------------------------

function bench_command(cmd::Cmd)
    try
        return strip(read(pipeline(cmd; stderr = devnull), String))
    catch
        return nothing
    end
end

function bench_commit()
    sha = get(ENV, "GITHUB_SHA", "")
    isempty(sha) || return sha
    return something(bench_command(`git -C $BENCH_ROOT rev-parse HEAD`), "unknown")
end

function bench_cpu_model()
    isfile("/proc/cpuinfo") || return nothing
    for line in eachline("/proc/cpuinfo")
        startswith(line, "model name") && return String(strip(split(line, ':'; limit = 2)[2]))
    end
    return nothing
end

function bench_environment()
    names = ["CUDA", "CUDSS", "ExaModels", "MadNLP", "MadNLPGPU"]
    versions = Dict(
        info.name => string(info.version) for info in values(Pkg.dependencies())
            if info.name in names && info.version !== nothing
    )
    functional = CUDA.functional()
    driver = bench_command(`nvidia-smi --query-gpu=driver_version --format=csv,noheader`)
    return Dict{String, Any}(
        "commit" => bench_commit(),
        "run_date" => Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z",
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "blas_threads_in_madnlp" => 1,
        "cpu_model" => bench_cpu_model(),
        "package_versions" => versions,
        "cuda_functional" => functional,
        "gpu_device" => functional ? CUDA.name(CUDA.device()) : nothing,
        "gpu_driver" => driver === nothing ? nothing : String(first(split(driver, '\n'))),
        "cuda_runtime_version" => functional ? string(CUDA.runtime_version()) : nothing,
    )
end

"Remove machine-specific strings from text that may be published."
function bench_scrub(text::AbstractString)
    out = String(text)
    for (value, label) in (
            (BENCH_ROOT, "<repo>"), (homedir(), "<home>"), (gethostname(), "<host>"),
            (get(ENV, "USER", ""), "<user>"),
        )
        length(value) >= 3 && (out = replace(out, value => label))
    end
    return out
end

# GPU memory and occupancy ------------------------------------------------------------------------

"Sample per-process GPU memory with nvidia-smi for the duration of `f`."
function with_gpu_sampler(f)
    path = tempname()
    cmd = `nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits -lms 200`
    sampler = try
        run(pipeline(cmd; stdout = path, stderr = devnull); wait = false)
    catch
        nothing
    end
    value = try
        f()
    finally
        sampler === nothing || kill(sampler)
    end
    sampler === nothing && return value, (peak_mib = nothing, others = nothing)
    sampler_wait = timedwait(() -> process_exited(sampler), 5.0)
    sampler_wait === :ok || kill(sampler, Base.SIGKILL)
    uuid = lowercase(string(CUDA.uuid(CUDA.device())))
    peak, others = 0, Set{String}()
    for line in eachline(path)
        fields = strip.(split(line, ','))
        length(fields) == 3 && occursin(uuid, lowercase(fields[1])) || continue
        if fields[2] == string(getpid())
            peak = max(peak, something(tryparse(Int, fields[3]), 0))
        else
            push!(others, String(fields[2]))
        end
    end
    rm(path; force = true)
    return value, (peak_mib = peak == 0 ? nothing : peak, others = length(others))
end

# One solve ---------------------------------------------------------------------------------------

function solver_options(solver, mode, tol, wall_limit_s)
    common = (; tol, max_iter = 1000, max_wall_time = wall_limit_s, print_level = MadNLP.ERROR)
    # Strict runs must meet `tol` itself, and both devices keep the same bound relaxation. The GPU
    # default ties the relaxation to `tol`, which changes the problem being solved at loose `tol`.
    strict = mode == "strict" ?
        (; acceptable_tol = tol, acceptable_iter = 100_000, bound_relax_factor = 1.0e-8) : (;)
    solver == CPU_SOLVER && return (; common..., strict...)
    return (; common..., strict..., GPU_REFINEMENT...,
            cudss_asynchronous = solver == GPU_ASYNC_SOLVER)
end

function case_family(id)
    (id == "demo" || startswith(id, "scaled-")) && return "network_size"
    startswith(id, "horizon-") && return "horizon"
    return "other"
end

function base_record(profile, env, id, solver, mode, tol, repeat)
    size = bench_case_size(id)
    return Dict{String, Any}(
        "run_profile" => string(profile), "commit" => env["commit"], "run_date" => env["run_date"],
        "case" => id, "family" => case_family(id), "junctions" => size.junctions,
        "periods" => size.periods, "solver" => solver, "mode" => mode, "tol_requested" => tol,
        "repeat" => repeat,
    )
end

finite_or_nothing(x) = x isa Real && isfinite(x) ? x : nothing

function timed_solve(solver, id, options)
    backend = solver == CPU_SOLVER ? nothing : CUDABackend()
    GC.gc(true)
    solver == CPU_SOLVER || CUDA.reclaim()
    compile_start = Base.cumulative_compile_time_ns()[1]
    build_s = @elapsed model = bench_case(id; backend)
    result = MadNLP.madnlp(model.nlp; options...)
    compile_s = (Base.cumulative_compile_time_ns()[1] - compile_start) / 1.0e9
    return (; result, build_s, compile_s)
end

function run_one!(record, host, reference_x, solver, id, options)
    try
        run, gpu = solver == CPU_SOLVER ? (timed_solve(solver, id, options), nothing) :
            with_gpu_sampler(() -> timed_solve(solver, id, options))
        r, c = run.result, run.result.counters
        x, y = Array(r.solution), Array(r.multipliers)
        residuals = kkt_residuals(host.nlp, x, y, Array(r.multipliers_L), Array(r.multipliers_U))
        linear = finite_or_nothing(c.linear_solver_time)
        merge!(record, Dict{String, Any}(
            "nvar" => host.nlp.meta.nvar, "ncon" => host.nlp.meta.ncon,
            "nnzj" => host.nlp.meta.nnzj, "nnzh" => host.nlp.meta.nnzh,
            "status" => string(r.status), "iterations" => r.iter, "build_s" => run.build_s,
            "total_s" => c.total_time, "linear_s" => linear, "eval_s" => c.eval_function_time,
            "other_s" => linear === nothing ? nothing : c.total_time - linear - c.eval_function_time,
            "compile_s" => run.compile_s, "objective" => BenchNLP.obj(host.nlp, x),
            "primal_residual" => residuals.primal, "dual_residual" => residuals.dual,
            "complementarity_residual" => residuals.complementarity,
            "kkt_residual" => residuals.kkt,
            "gpu_peak_mib" => gpu === nothing ? nothing : gpu.peak_mib,
            "gpu_other_processes" => gpu === nothing ? nothing : gpu.others,
        ))
        reference = reference_x === nothing ? x : reference_x
        merge!(record, Dict{String, Any}(string(k) => v for (k, v) in
            pairs(solution_agreement(host, x, reference))))
        return x
    catch err
        err isa InterruptException && rethrow()
        message = first(split(sprint(showerror, err), '\n'))
        record["status"] = "ERROR"
        record["error"] = bench_scrub(first(message, 300))
        @warn "Benchmark run failed" record["case"] record["solver"] record["error"]
        return nothing
    end
end

# Sweeps ------------------------------------------------------------------------------------------

function warm_up()
    for solver in (CPU_SOLVER, GPU_SOLVER), id in ("demo", "horizon-2")
        timed_solve(solver, id, solver_options(solver, "default", 1.0e-6, 120.0))
    end
    return nothing
end

function run_sweep(profile, env, started; log = stdout)
    settings = BENCH_PROFILES[profile]
    records, not_run = Dict{String, Any}[], Dict{String, Any}[]
    references = Dict{String, Vector{Float64}}()
    plans = vcat(
        [("default", 1.0e-8, s) for s in (CPU_SOLVER, GPU_SOLVER, GPU_ASYNC_SOLVER)],
        [("strict", t, s) for t in settings.strict_tols for s in (CPU_SOLVER, GPU_SOLVER)],
    )
    for id in vcat(settings.size_cases, settings.horizon_cases)
        host = bench_case(id)
        reference_x = nothing
        for (mode, tol, solver) in plans, repeat in 1:settings.repeats
            if time() - started > settings.budget_s
                push!(not_run, Dict{String, Any}(
                    "case" => id, "solver" => solver, "mode" => mode, "tol_requested" => tol,
                    "repeat" => repeat, "reason" => "CI time budget reached",
                ))
                continue
            end
            record = base_record(profile, env, id, solver, mode, tol, repeat)
            options = solver_options(solver, mode, tol, settings.wall_limit_s)
            x = run_one!(record, host, reference_x, solver, id, options)
            if reference_x === nothing && solver == CPU_SOLVER && mode == "default" && x !== nothing
                reference_x = x
                references[id] = x
            end
            push!(records, record)
            println(log, join((id, solver, mode, tol, repeat, get(record, "status", "?"),
                               get(record, "iterations", "?"), get(record, "total_s", "?")), "  "))
            flush(log)
        end
    end
    return records, not_run, references
end

# Time to first solve -----------------------------------------------------------------------------

const TTFS_SCRIPT = raw"""
start = time()
device = ARGS[1]
device == "gpu" && (using CUDA, CUDSS, MadNLPGPU)
using CampusSteam, MadNLP
load_s = time() - start
net = demo_campus()
backend = device == "gpu" ? CUDABackend() : nothing
options = device == "gpu" ? (; richardson_max_iter = 30, richardson_tol = 1.0e-12) : (;)
solve() = MadNLP.madnlp(build_steam_model(net; backend).nlp; print_level = MadNLP.ERROR, options...)
first_s = @elapsed first_result = solve()
second_s = @elapsed solve()
println("TTFS ", load_s, " ", first_s, " ", second_s, " ", first_result.status)
"""

function time_to_first_solve(repeats)
    rows = Dict{String, Any}[]
    project = dirname(@__DIR__)
    for device in ("cpu", "gpu"), repeat in 1:repeats
        row = Dict{String, Any}("device" => device, "repeat" => repeat)
        try
            cmd = `$(Base.julia_cmd()) --project=$project --startup-file=no -e $TTFS_SCRIPT $device`
            process_s = @elapsed output = read(pipeline(cmd; stderr = devnull), String)
            line = only(filter(startswith("TTFS "), split(output, '\n')))
            fields = split(line)
            merge!(row, Dict{String, Any}(
                "process_s" => process_s, "package_load_s" => parse(Float64, fields[2]),
                "first_build_and_solve_s" => parse(Float64, fields[3]),
                "second_build_and_solve_s" => parse(Float64, fields[4]),
                "status" => String(fields[5]),
            ))
        catch err
            row["status"] = "ERROR"
            row["error"] = bench_scrub(first(first(split(sprint(showerror, err), '\n')), 300))
        end
        push!(rows, row)
    end
    return rows
end

# Ipopt reference ---------------------------------------------------------------------------------

function ipopt_records(profile, env, cases, repeats, references)
    dir = mktempdir()
    script = joinpath(BENCH_ROOT, "validation", "ipopt_benchmark.jl")
    load_path = join([joinpath(BENCH_ROOT, "validation"), joinpath(BENCH_ROOT, "scripts"), "@stdlib"], ":")
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no $script $dir $repeats $cases`,
                 "JULIA_LOAD_PATH" => load_path)
    run(cmd)
    records = Dict{String, Any}[]
    for raw in JSON.parsefile(joinpath(dir, "ipopt_records.json"))
        id = raw["case"]
        strict = raw["mode"] == "strict"
        record = base_record(profile, env, id, IPOPT_SOLVER, raw["mode"], raw["tol_requested"], raw["repeat"])
        merge!(record, Dict{String, Any}(string(k) => v for (k, v) in raw))
        linear = get(record, "linear_s", nothing)
        record["other_s"] = linear === nothing ? nothing : record["total_s"] - linear - record["eval_s"]
        path = joinpath(dir, "ipopt_$(id).x.bin")
        if !strict && isfile(path) && haskey(references, id)
            host = bench_case(id)
            x = reinterpret(Float64, read(path)) |> collect
            merge!(record, Dict{String, Any}(string(k) => v for (k, v) in
                pairs(solution_agreement(host, x, references[id]))))
        end
        push!(records, record)
    end
    return records
end

# Summaries ---------------------------------------------------------------------------------------

spread(values) = isempty(values) ? nothing : Dict(
    "median" => median(values), "min" => minimum(values), "max" => maximum(values),
    "n" => length(values),
)

numbers(rows, key) = Float64[r[key] for r in rows if get(r, key, nothing) isa Real]

"Median, minimum and maximum over the repeats of each case, solver, mode and tolerance."
function summarize(records)
    groups = Dict{Tuple, Vector{Dict{String, Any}}}()
    for r in records
        push!(get!(groups, (r["case"], r["solver"], r["mode"], r["tol_requested"]), Dict{String, Any}[]), r)
    end
    out = Dict{String, Any}[]
    for ((id, solver, mode, tol), rows) in groups
        first_row = first(rows)
        entry = Dict{String, Any}(
            "case" => id, "family" => first_row["family"], "junctions" => first_row["junctions"],
            "periods" => first_row["periods"], "solver" => solver, "mode" => mode,
            "tol_requested" => tol, "repeats" => length(rows),
            "statuses" => sort!(unique(String[string(get(r, "status", "?")) for r in rows])),
        )
        solved = filter(r -> get(r, "status", "") == "SOLVE_SUCCEEDED", rows)
        entry["solved_repeats"] = length(solved)
        entry["total_s_solved"] = spread(numbers(solved, "total_s"))
        entry["iterations_solved"] = spread(numbers(solved, "iterations"))
        for key in ("nvar", "ncon", "nnzj", "nnzh")
            entry[key] = get(first_row, key, nothing)
        end
        for key in ("total_s", "linear_s", "eval_s", "other_s", "build_s", "compile_s", "iterations",
                    "gpu_peak_mib", "kkt_residual", "primal_residual", "dual_residual",
                    "complementarity_residual")
            entry[key] = spread(numbers(rows, key))
        end
        for key in ("objective_rel", "plant_output_rel", "steam_pressure_rel", "steam_temperature_rel",
                    "steam_flow_rel", "nonunique_water_pressure_rel",
                    "nonunique_return_temperature_rel", "nonunique_light_flow_rel")
            values = numbers(rows, key)
            entry["max_" * key] = isempty(values) ? nothing : maximum(values)
        end
        others = numbers(rows, "gpu_other_processes")
        entry["gpu_other_processes_max"] = isempty(others) ? nothing : Int(maximum(others))
        push!(out, entry)
    end
    sort!(out; by = e -> (e["family"], something(e["nvar"], 0), e["solver"], e["mode"], e["tol_requested"]))
    return out
end

all_solved(entry) = entry["solved_repeats"] == entry["repeats"]

"CPU and GPU at the same requested tolerance, with acceptable termination switched off on both."
function like_for_like(summary)
    find(id, solver, tol) = findfirst(
        e -> e["case"] == id && e["solver"] == solver && e["mode"] == "strict" && e["tol_requested"] == tol,
        summary,
    )
    rows = Dict{String, Any}[]
    for cpu in summary
        (cpu["solver"] == CPU_SOLVER && cpu["mode"] == "strict") || continue
        index = find(cpu["case"], GPU_SOLVER, cpu["tol_requested"])
        index === nothing && continue
        gpu = summary[index]
        both = all_solved(cpu) && all_solved(gpu)
        comparable = cpu["total_s_solved"] !== nothing && gpu["total_s_solved"] !== nothing
        ratio = comparable ? gpu["total_s_solved"]["median"] / cpu["total_s_solved"]["median"] : nothing
        worst = comparable ? gpu["total_s_solved"]["max"] / cpu["total_s_solved"]["median"] : nothing
        push!(rows, Dict{String, Any}(
            "case" => cpu["case"], "family" => cpu["family"], "junctions" => cpu["junctions"],
            "periods" => cpu["periods"], "nvar" => cpu["nvar"], "tol_requested" => cpu["tol_requested"],
            "cpu_statuses" => cpu["statuses"], "gpu_statuses" => gpu["statuses"],
            "repeats" => cpu["repeats"], "cpu_solved_repeats" => cpu["solved_repeats"],
            "gpu_solved_repeats" => gpu["solved_repeats"], "both_solved_every_repeat" => both,
            "cpu_total_s" => cpu["total_s_solved"], "gpu_total_s" => gpu["total_s_solved"],
            "cpu_iterations" => cpu["iterations_solved"], "gpu_iterations" => gpu["iterations_solved"],
            "cpu_kkt_residual" => cpu["kkt_residual"], "gpu_kkt_residual" => gpu["kkt_residual"],
            "gpu_max_objective_rel" => gpu["max_objective_rel"],
            "gpu_over_cpu_time" => ratio, "gpu_slowest_over_cpu_median" => worst,
        ))
    end
    sort!(rows; by = r -> (r["family"], something(r["nvar"], 0), r["tol_requested"]))
    return rows
end

"The first size from which the GPU is faster at every larger size of a sweep, or `nothing`."
function crossover(rows, family, tol)
    selected = filter(r -> r["family"] == family && r["tol_requested"] == tol, rows)
    isempty(selected) && return nothing
    faster(r) = r["both_solved_every_repeat"] && r["gpu_over_cpu_time"] < 1
    all(!faster, selected) && return nothing
    for i in eachindex(selected)
        all(faster, selected[i:end]) && return selected[i]["case"]
    end
    return nothing
end

# Points drawn by the site: the median of the solved repeats at the tightest strict tolerance. The
# status is "solved" only when every repeat met that tolerance.
function site_runs(rows, tol)
    out = Dict{String, Any}[]
    for r in rows
        (r["tol_requested"] == tol && r["nvar"] !== nothing) || continue
        for (device, total, iterations, solved) in (
                ("cpu", r["cpu_total_s"], r["cpu_iterations"], r["cpu_solved_repeats"]),
                ("gpu", r["gpu_total_s"], r["gpu_iterations"], r["gpu_solved_repeats"]),
            )
            total === nothing && continue
            push!(out, Dict{String, Any}(
                "size" => r["nvar"], "case" => r["case"], "device" => device,
                "solve_s" => total["median"], "solve_s_min" => total["min"],
                "solve_s_max" => total["max"], "iterations" => iterations["median"],
                "status" => solved == r["repeats"] ? "solved" : "partial",
                "solved_repeats" => solved, "repeats" => r["repeats"],
            ))
        end
    end
    return out
end

site_notes(tol, source) = "Synthetic data. Median solve time of the repeats that met a tolerance of $tol on both CPU and GPU, from the $source sweep. Hollow points mark sizes where some repeats did not meet it."

# Output ------------------------------------------------------------------------------------------

csv_cell(::Nothing) = ""
csv_cell(x::AbstractFloat) = isfinite(x) ? @sprintf("%.6g", x) : ""
csv_cell(x) = (s = string(x); occursin(r"[\",\n]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s)

function records_csv(records)
    io = IOBuffer()
    println(io, join(CSV_COLUMNS, ","))
    for r in records
        println(io, join((csv_cell(get(r, c, nothing)) for c in CSV_COLUMNS), ","))
    end
    return String(take!(io))
end

function assert_bench_public_safe(text)
    for value in (BENCH_ROOT, homedir(), gethostname(), get(ENV, "USER", ""))
        length(value) >= 3 && occursin(value, text) &&
            error("benchmark output would expose a machine-specific value")
    end
    return nothing
end

function bench_document(profile, env, records, not_run, ttfs, extra_not_run)
    settings = BENCH_PROFILES[profile]
    summary = summarize(records)
    pairs_rows = like_for_like(summary)
    tightest = isempty(settings.strict_tols) ? nothing : minimum(settings.strict_tols)
    return Dict{String, Any}(
        "label" => SYNTHETIC_LABEL,
        "profile" => string(profile),
        "environment" => env,
        "sweep" => Dict{String, Any}(
            "network_size_cases" => settings.size_cases, "horizon_cases" => settings.horizon_cases,
            "repeats" => settings.repeats, "strict_tolerances" => settings.strict_tols,
            "ipopt_included" => settings.ipopt,
        ),
        "solver_settings" => Dict{String, Any}(
            CPU_SOLVER => "MadNLP defaults with MUMPS, one BLAS thread",
            GPU_SOLVER => "MadNLP GPU defaults (condensed KKT, cuDSS LDL), richardson_max_iter = 30, richardson_tol = 1e-12, synchronous cuDSS so that linear solver time is reported",
            GPU_ASYNC_SOLVER => "As $GPU_SOLVER with asynchronous cuDSS, the package default; MadNLP does not report linear solver time in this mode",
            IPOPT_SOLVER => "Ipopt with MUMPS on the same ExaModel, tol = 1e-8",
            "strict_mode" => "Acceptable termination is off, so SOLVE_SUCCEEDED means the requested tolerance was met. bound_relax_factor = 1e-8 on CPU and GPU.",
        ),
        "agreement_note" => "Agreement with the CPU uses objective, plant output and steam-side quantities. Water-side pressure, return-side temperature and flow in lightly loaded pipes are not unique at the optimum (docs/validation-notes.md) and are reported separately under nonunique_* fields.",
        "size_label" => "Variables",
        "runs" => tightest === nothing ? Dict{String, Any}[] : site_runs(pairs_rows, tightest),
        "notes" => tightest === nothing ? nothing : site_notes(tightest, string(profile)),
        "summary" => summary,
        "like_for_like" => pairs_rows,
        "crossover" => Dict{String, Any}(
            "network_size" => tightest === nothing ? nothing : crossover(pairs_rows, "network_size", tightest),
            "horizon" => tightest === nothing ? nothing : crossover(pairs_rows, "horizon", tightest),
            "tolerance" => tightest,
        ),
        "time_to_first_solve" => ttfs,
        "not_run" => vcat(not_run, extra_not_run),
        "records" => records,
    )
end

const STANDING_NOT_RUN = [
    Dict{String, Any}("item" => "Single precision", "reason" => "The model builders use Float64."),
]

function calibration_not_run()
    return Dict{String, Any}(
        "item" => "WP6 calibration problem",
        "reason" => "Not available on main when this benchmark was written.",
    )
end

"""
    run_benchmarks(outdir; profile = :ci)

Run a benchmark sweep and write `benchmarks.json` and `benchmarks.csv` to `outdir`. The committed
GPU notes in `results/gpu_notes.json` are copied there as `gpu_notes.json`.
"""
function run_benchmarks(outdir; profile::Symbol = :ci)
    settings = BENCH_PROFILES[profile]
    mkpath(outdir)
    env = bench_environment()
    env["other_processes_note"] = "gpu_other_processes counts other compute processes seen on this GPU during each run."
    started = time()
    warm_up()
    records, not_run, references = run_sweep(profile, env, started)
    if settings.ipopt
        append!(records, ipopt_records(
            profile, env, vcat(settings.size_cases, settings.horizon_cases), settings.repeats, references,
        ))
    end
    ttfs = time_to_first_solve(settings.ttfs_repeats)
    extra = vcat(STANDING_NOT_RUN, [calibration_not_run()])
    settings.ipopt || push!(extra, Dict{String, Any}(
        "item" => "Ipopt in this sweep", "reason" => "Ipopt runs only in the local sweep; see results/benchmarks.csv.",
    ))
    document = bench_document(profile, env, records, not_run, ttfs, extra)
    document["sweep_runtime_s"] = time() - started
    local_summary = joinpath(BENCH_ROOT, "results", "benchmarks_summary.json")
    if profile === :ci && isfile(local_summary)
        document["local_sweep"] = JSON.parsefile(local_summary)
        document["runs"] = document["local_sweep"]["runs"]
        document["notes"] = document["local_sweep"]["notes"]
    end
    text = JSON.json(document, 2)
    csv = records_csv(records)
    assert_bench_public_safe(text)
    assert_bench_public_safe(csv)
    write(joinpath(outdir, "benchmarks.json"), text)
    write(joinpath(outdir, "benchmarks.csv"), csv)
    notes = joinpath(BENCH_ROOT, "results", "gpu_notes.json")
    isfile(notes) && cp(notes, joinpath(outdir, "gpu_notes.json"); force = true)
    @info "Benchmarks finished" profile runtime_s = round(document["sweep_runtime_s"]; digits = 1)
    return document
end

if abspath(PROGRAM_FILE) == @__FILE__
    profile = isempty(ARGS) ? :local : Symbol(ARGS[1])
    outdir = mktempdir()
    document = run_benchmarks(outdir; profile)
    results = joinpath(BENCH_ROOT, "results")
    if profile === :local
        cp(joinpath(outdir, "benchmarks.csv"), joinpath(results, "benchmarks.csv"); force = true)
        delete!(document, "records")
        write(joinpath(results, "benchmarks_summary.json"), JSON.json(document, 2))
    else
        cp(joinpath(outdir, "benchmarks.csv"), joinpath(results, "benchmarks_$(profile).csv"); force = true)
    end
end

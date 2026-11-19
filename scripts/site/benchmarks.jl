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
        repeats = 3, strict_tols = [1.0e-8], ttfs_repeats = 0, ipopt = false, gpu_memory = false,
        budget_s = 270.0, wall_limit_s = 60.0,
    ),
    :local => (
        size_cases = ["demo", "scaled-200", "scaled-300", "scaled-400", "scaled-500", "scaled-600", "scaled-800"],
        horizon_cases = ["horizon-24", "horizon-168", "horizon-720"],
        repeats = 5, strict_tols = [1.0e-6, 1.0e-8], ttfs_repeats = 3, ipopt = true, gpu_memory = true,
        budget_s = Inf, wall_limit_s = 1800.0,
    ),
    :year => (
        size_cases = String[], horizon_cases = ["horizon-8760"],
        repeats = 1, strict_tols = [1.0e-8], ttfs_repeats = 0, ipopt = false, gpu_memory = false,
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
    "total_s", "linear_s", "eval_s", "other_s", "compile_s", "host_load_1min", "objective", "primal_residual",
    "dual_residual", "complementarity_residual", "kkt_residual", "objective_rel", "plant_output_rel",
    "steam_pressure_rel", "steam_temperature_rel", "steam_flow_rel",
    "nonunique_water_pressure_rel", "nonunique_return_temperature_rel", "nonunique_light_flow_rel",
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

function start_gpu_sampler()
    path = tempname()
    cmd = `nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits -lms 200`
    process = try
        run(pipeline(cmd; stdout = path, stderr = devnull); wait = false)
    catch
        nothing
    end
    return (; process, path)
end

# Peak memory of process `pid` on this GPU, and the number of other processes seen on it.
function stop_gpu_sampler(sampler, pid)
    sampler.process === nothing && return (peak_mib = nothing, others = nothing)
    kill(sampler.process)
    timedwait(() -> process_exited(sampler.process), 5.0) === :ok || kill(sampler.process, Base.SIGKILL)
    uuid = lowercase(string(CUDA.uuid(CUDA.device())))
    peak, others = 0, Set{String}()
    for line in eachline(sampler.path)
        fields = strip.(split(line, ','))
        length(fields) == 3 && occursin(uuid, lowercase(fields[1])) || continue
        if fields[2] == string(pid)
            peak = max(peak, something(tryparse(Int, fields[3]), 0))
        else
            push!(others, String(fields[2]))
        end
    end
    rm(sampler.path; force = true)
    return (peak_mib = peak == 0 ? nothing : peak, others = length(others))
end

"Run `f` and count the other compute processes seen on this GPU meanwhile."
function with_gpu_sampler(f)
    sampler = start_gpu_sampler()
    value = try
        f()
    catch
        stop_gpu_sampler(sampler, getpid())
        rethrow()
    end
    return value, stop_gpu_sampler(sampler, getpid())
end

const GPU_MEMORY_SCRIPT = raw"""
include(ARGS[1])
using CUDA, CUDSS, MadNLP, MadNLPGPU
model = bench_case(ARGS[2]; backend = CUDABackend())
result = MadNLP.madnlp(
    model.nlp; tol = 1.0e-8, acceptable_tol = 1.0e-8, acceptable_iter = 100_000,
    bound_relax_factor = 1.0e-8, max_iter = 1000, max_wall_time = 900.0, print_level = MadNLP.ERROR,
    richardson_max_iter = 30, richardson_tol = 1.0e-12, cudss_asynchronous = false,
)
println("GPUMEM ", result.status, " ", result.iter)
"""

"""
Peak GPU memory of one strict solve per case, each in a fresh process. A long-lived process keeps
freed memory in its pool, so its reading reflects the largest earlier case and not the current one.
"""
function gpu_memory_table(cases)
    project = dirname(@__DIR__)
    common = joinpath(@__DIR__, "bench_common.jl")
    rows = Dict{String, Any}[]
    for id in cases
        row = Dict{String, Any}("case" => id)
        path = tempname()
        sleep(5.0)    # lets the previous case's process leave the GPU before sampling starts
        cmd = `$(Base.julia_cmd()) --project=$project --startup-file=no -e $GPU_MEMORY_SCRIPT $common $id`
        sampler = start_gpu_sampler()
        process = run(pipeline(cmd; stdout = path, stderr = devnull); wait = false)
        pid = getpid(process)
        wait(process)
        memory = stop_gpu_sampler(sampler, pid)
        line = findfirst(startswith("GPUMEM "), readlines(path))
        fields = line === nothing ? String[] : split(readlines(path)[line])
        merge!(row, Dict{String, Any}(
            "peak_mib" => memory.peak_mib, "other_processes" => memory.others,
            "status" => length(fields) == 3 ? String(fields[2]) : "ERROR",
            "iterations" => length(fields) == 3 ? parse(Int, fields[3]) : nothing,
        ))
        rm(path; force = true)
        push!(rows, row)
        println("gpu memory  ", id, "  ", row["status"], "  ", row["peak_mib"], " MiB")
        flush(stdout)
    end
    return rows
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
        "repeat" => repeat, "host_load_1min" => Sys.loadavg()[1],
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
            "gpu_other_processes" => gpu === nothing ? nothing : gpu.others,
        ))
        reference_x === nothing || merge!(record, Dict{String, Any}(string(k) => v for (k, v) in
            pairs(solution_agreement(host, x, reference_x))))
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

bench_cases(settings) = vcat(settings.size_cases, settings.horizon_cases)

function run_sweep(profile, env, started; log = stdout)
    settings = BENCH_PROFILES[profile]
    records, not_run = Dict{String, Any}[], Dict{String, Any}[]
    references = Dict{String, Vector{Float64}}()
    strict_plans = [("strict", t, s) for t in reverse(settings.strict_tols) for s in (CPU_SOLVER, GPU_SOLVER)]
    plans = profile === :year ? strict_plans : vcat(
        [("default", 1.0e-8, s) for s in (CPU_SOLVER, GPU_SOLVER, GPU_ASYNC_SOLVER)], strict_plans,
    )
    for id in bench_cases(settings)
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
            # The reference is the first CPU solve that met 1e-8.
            if reference_x === nothing && solver == CPU_SOLVER && tol == 1.0e-8 && x !== nothing &&
                    get(record, "status", "") == "SOLVE_SUCCEEDED"
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
    # The scripts environment comes first because its manifest tracks the dependencies of CampusSteam.
    load_path = join([joinpath(BENCH_ROOT, "scripts"), joinpath(BENCH_ROOT, "validation"), "@stdlib"], ":")
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
        solved = filter(r -> get(r, "status", "") in ("SOLVE_SUCCEEDED", "Solve_Succeeded"), rows)
        entry["solved_repeats"] = length(solved)
        entry["total_s_solved"] = spread(numbers(solved, "total_s"))
        entry["iterations_solved"] = spread(numbers(solved, "iterations"))
        for key in ("nvar", "ncon", "nnzj", "nnzh")
            entry[key] = get(first_row, key, nothing)
        end
        for key in ("total_s", "linear_s", "eval_s", "other_s", "build_s", "compile_s", "iterations",
                    "host_load_1min", "kkt_residual", "primal_residual", "dual_residual",
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

# Like for like: the GPU's worst KKT residual is at most this multiple of the CPU's worst.
const ACHIEVED_TOLERANCE_FACTOR = 2.0

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
        # The requested tolerance applies to each solver's own scaled problem, so the residual both
        # returned points reach on the unscaled model is compared as well.
        kkt_ratio = comparable ? gpu["kkt_residual"]["max"] / cpu["kkt_residual"]["max"] : nothing
        matched = comparable && kkt_ratio <= ACHIEVED_TOLERANCE_FACTOR
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
            "gpu_over_cpu_kkt_residual" => kkt_ratio, "achieved_tolerance_matched" => matched,
        ))
    end
    sort!(rows; by = r -> (r["family"], something(r["nvar"], 0), r["tol_requested"]))
    return rows
end

"The first size from which the GPU is faster at every larger size of a sweep, or `nothing`."
function crossover(rows, family, tol)
    selected = filter(r -> r["family"] == family && r["tol_requested"] == tol, rows)
    isempty(selected) && return nothing
    faster(r) = r["both_solved_every_repeat"] && r["achieved_tolerance_matched"] && r["gpu_over_cpu_time"] < 1
    all(!faster, selected) && return nothing
    for i in eachindex(selected)
        all(faster, selected[i:end]) && return selected[i]["case"]
    end
    return nothing
end

# Points drawn by the site: the median of the solved repeats at the tightest strict tolerance. The
# status is "solved" only when every repeat met that tolerance and, for the GPU, when the residual it
# reached matches the CPU's.
function site_runs(rows, tol)
    out = Dict{String, Any}[]
    for r in rows
        (r["tol_requested"] == tol && r["nvar"] !== nothing) || continue
        for (device, total, iterations, solved, matched) in (
                ("cpu", r["cpu_total_s"], r["cpu_iterations"], r["cpu_solved_repeats"], true),
                ("gpu", r["gpu_total_s"], r["gpu_iterations"], r["gpu_solved_repeats"], r["achieved_tolerance_matched"]),
            )
            total === nothing && continue
            push!(out, Dict{String, Any}(
                "size" => r["nvar"], "case" => r["case"], "device" => device,
                "solve_s" => total["median"], "solve_s_min" => total["min"],
                "solve_s_max" => total["max"], "iterations" => iterations["median"],
                "status" => solved == r["repeats"] && matched ? "solved" : "partial",
                "solved_repeats" => solved, "repeats" => r["repeats"],
            ))
        end
    end
    return out
end

site_notes(tol, source) = "Synthetic data. Median solve time of the repeats that met a tolerance of $tol on both CPU and GPU, from the $source sweep. Hollow points mark sizes where some repeats did not meet it, or where the GPU's KKT residual was more than $(ACHIEVED_TOLERANCE_FACTOR) times the CPU's."

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

# A solve that stops early can return NaN, which JSON cannot represent. It is written as null.
json_safe(x) = x
json_safe(x::AbstractFloat) = isfinite(x) ? x : nothing
json_safe(x::AbstractDict) = Dict{String, Any}(string(k) => json_safe(v) for (k, v) in x)
json_safe(x::AbstractVector) = Any[json_safe(v) for v in x]

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
            "achieved_tolerance_matched" => "True when the GPU's largest KKT residual over the repeats, recomputed on the unscaled model, is at most $(ACHIEVED_TOLERANCE_FACTOR) times the CPU's.",
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
    Dict{String, Any}(
        "item" => "Demo campus at T = 8760",
        "reason" => "Attempted once locally and neither solver finished; see results/logs/benchmarks_year_attempt.txt.",
    ),
]


"""
The CPU and GPU outcomes that `run_calibration` wrote to `calibration.json` in `outdir`, at 25 tags.
Calibration is not solved again here, so it adds no runtime to the benchmarks.
"""
function calibration_outcome(outdir)
    path = joinpath(outdir, "calibration.json")
    isfile(path) || return nothing
    data = JSON.parsefile(path)
    keys_kept = ("tags", "months", "hours", "run", "solver_status", "converged", "iterations",
                 "variables", "constraints", "jacobian_nonzeros", "solve_s", "reason")
    keep(cell) = Dict{String, Any}(k => cell[k] for k in keys_kept if haskey(cell, k))
    gpu = data["gpu"]
    return Dict{String, Any}(
        "source" => "calibration.json",
        "network_junctions" => data["network"]["junctions"],
        "cpu" => [keep(c) for c in data["grid"]["cells"] if c["tags"] == 25 && get(c, "run", false)],
        "gpu" => merge(keep(gpu), Dict{String, Any}("attempted" => get(gpu, "attempted", false))),
        "note" => "Read from the calibration step of this build. The site build attempts the GPU at one grid point.",
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
    ipopt_failure = nothing
    if settings.ipopt
        try
            append!(records, ipopt_records(profile, env, bench_cases(settings), settings.repeats, references))
        catch err
            err isa InterruptException && rethrow()
            ipopt_failure = bench_scrub(first(first(split(sprint(showerror, err), '\n')), 300))
            @warn "The Ipopt reference runs failed" ipopt_failure
        end
    end
    ttfs = time_to_first_solve(settings.ttfs_repeats)
    extra = copy(STANDING_NOT_RUN)
    ipopt_failure === nothing || push!(extra, Dict{String, Any}(
        "item" => "Ipopt reference runs", "reason" => "The Ipopt process failed: $ipopt_failure",
    ))
    calibration = calibration_outcome(outdir)
    calibration === nothing && push!(extra, Dict{String, Any}(
        "item" => "Calibration CPU and GPU outcome",
        "reason" => "calibration.json was not found next to this file when the benchmarks were written.",
    ))
    settings.ipopt || push!(extra, Dict{String, Any}(
        "item" => "Ipopt in this sweep", "reason" => "Ipopt runs only in the local sweep; see results/benchmarks.csv.",
    ))
    document = bench_document(profile, env, records, not_run, ttfs, extra)
    document["calibration"] = calibration
    settings.gpu_memory && (document["gpu_memory"] = gpu_memory_table(bench_cases(settings)))
    document["sweep_runtime_s"] = time() - started
    local_summary = joinpath(BENCH_ROOT, "results", "benchmarks_summary.json")
    if profile === :ci && isfile(local_summary)
        document["local_sweep"] = JSON.parsefile(local_summary)
        # The local sweep has no calibration step to read; this build's outcome is in `calibration`.
        filter!(x -> get(x, "item", "") != "Calibration CPU and GPU outcome", document["local_sweep"]["not_run"])
        document["runs"] = document["local_sweep"]["runs"]
        document["notes"] = document["local_sweep"]["notes"]
    end
    text = JSON.json(json_safe(document), 2)
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
        write(joinpath(results, "benchmarks_summary.json"), JSON.json(json_safe(document), 2))
    else
        cp(joinpath(outdir, "benchmarks.csv"), joinpath(results, "benchmarks_$(profile).csv"); force = true)
        delete!(document, "records")
        write(joinpath(results, "benchmarks_$(profile)_summary.json"), JSON.json(json_safe(document), 2))
    end
end

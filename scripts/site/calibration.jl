# "What the data buys": recovers pipe coefficients from synthetic historian-style CSV and writes
# site/data/calibration.json and site/data/tag_template.csv. All data is synthetic. Every number written
# here is computed by this run. Grid points that do not run are recorded as not run, with the reason.
# The schema is documented in docs/site-data.md under "Calibration".

using CampusSteam
using CUDA
using CUDSS
using Dates
using JSON
using MadNLP
using MadNLPGPU

const CAL_TAG_COUNTS = [5, 10, 15, 25]
const CAL_MONTHS = [1, 3, 6, 12, 24]
# Grid points of the site build, in the order they are attempted.
const CAL_CI_POINTS = [(25, 1), (5, 1), (25, 3), (10, 1), (15, 1)]
# Wall-clock budget of the whole calibration step in the site build, and the time kept for the GPU
# attempt and for writing results.
const CAL_BUDGET_S = 345.0
const CAL_GPU_RESERVE_S = 55.0
const CAL_HISTORIAN_HOURS = 17520
const CAL_MAX_ITER = 500

_cal_round(x; digits = 5) = x === nothing ? nothing : round(Float64(x); digits)

function _cal_series(series::HistorianSeries, hours::Integer)
    return HistorianSeries(
        series.tags, series.start, series.values[1:hours, :], series.status[1:hours, :],
        series.duplicates, series.off_grid, series.unknown_tags,
    )
end

# A short window of one tag around a sample flagged Bad, as written and after the quality policy.
function _cal_bad_example(table, series::HistorianSeries; tag = "FAR-1.STM.TEMP", halfwidth = 2)
    column = findfirst(==(tag), series.tags)
    rows = Dict(table.time[i] => i for i in eachindex(table.time) if table.tag[i] == tag)
    hours = size(series.values, 1)
    is_spike(h) = begin
        i = get(rows, series.start + Hour(h - 1), 0)
        i != 0 && series.status[h, column] == SAMPLE_BAD && isfinite(table.value[i]) &&
            abs(table.value[i] - series.values[h - 1, column]) > 20.0
    end
    center = findfirst(
        h -> all(k -> k == h || series.status[k, column] == SAMPLE_GOOD, (h - halfwidth):(h + halfwidth)) && is_spike(h),
        (halfwidth + 1):(hours - halfwidth),
    )
    center === nothing && error("no isolated bad sample found for $tag")
    center += halfwidth
    window = (center - halfwidth):(center + halfwidth)
    samples = map(window) do h
        i = rows[series.start + Hour(h - 1)]
        Dict(
            "time" => Dates.format(table.time[i], dateformat"yyyy-mm-dd HH:MM:SS"),
            "value" => table.value[i],
            "quality" => table.quality[i],
            "used" => series.status[h, column] == SAMPLE_GOOD,
        )
    end
    raw = [s["value"] for s in samples]
    kept = [s["value"] for s in samples if s["used"]]
    return Dict(
        "tag" => tag,
        "unit" => "K",
        "samples" => samples,
        "mean_with_bad_sample" => _cal_round(sum(raw) / length(raw); digits = 3),
        "mean_after_exclusion" => _cal_round(sum(kept) / length(kept); digits = 3),
        "samples_excluded" => count(s -> !s["used"], samples),
    )
end

function _cal_point(hist, net, series, nominal_state, n_tags, months; backend = nothing, solver...)
    hours = months * CampusSteam.HOURS_PER_MONTH
    problem = CalibrationProblem(
        net, _cal_series(series, hours), select_tags(hist.tags, n_tags), hist.nominal_heat_W, nominal_state,
    )
    build_s = @elapsed model = build_calibration_model(problem; backend)
    wall_s = @elapsed result = solve_calibration(model; max_iter = CAL_MAX_ITER, solver...)
    errors = recovery_errors(result, hist.truth)
    estimated = findall(hist.groups.estimated)
    cell = Dict{String, Any}(
        "tags" => n_tags,
        "months" => months,
        "hours" => hours,
        "run" => true,
        "solver_status" => result.status,
        "converged" => result.converged,
        "iterations" => result.iterations,
        "variables" => result.nvar,
        "constraints" => result.ncon,
        "jacobian_nonzeros" => result.nnzj,
        "measurements" => result.nmeasure,
        "build_s" => _cal_round(build_s; digits = 2),
        "solve_s" => _cal_round(wall_s; digits = 2),
    )
    if result.converged
        cell["estimate"] = Dict("loss" => _cal_round.(result.loss), "friction" => _cal_round.(result.friction))
        cell["error_percent"] = Dict(
            "loss" => Dict(hist.groups.names[g] => _cal_round(100 * errors.loss[g]; digits = 3) for g in estimated),
            "friction" => Dict(hist.groups.names[g] => _cal_round(100 * errors.friction[g]; digits = 3) for g in estimated),
        )
        cell["max_error_percent"] = _cal_round(
            100 * maximum(vcat(errors.loss[estimated], errors.friction[estimated])); digits = 3,
        )
    else
        cell["reason"] = "The solver stopped with status $(result.status), so no recovery error is reported."
    end
    return cell
end

_cal_not_run(n_tags, months, reason) = Dict{String, Any}(
    "tags" => n_tags, "months" => months, "hours" => months * CampusSteam.HOURS_PER_MONTH,
    "run" => false, "reason" => reason,
)

# One attempt on the GPU. Any failure is recorded rather than raised.
function _cal_gpu_attempt(hist, net, series, nominal_state, n_tags, months, wall_limit_s)
    outcome = Dict{String, Any}("tags" => n_tags, "months" => months, "wall_limit_s" => _cal_round(wall_limit_s; digits = 1))
    if !CUDA.functional()
        outcome["attempted"] = false
        outcome["reason"] = "CUDA is not functional in this environment."
        return outcome
    end
    outcome["attempted"] = true
    outcome["device"] = CUDA.name(CUDA.device())
    try
        cell = _cal_point(
            hist, net, series, nominal_state, n_tags, months; backend = CUDA.CUDABackend(),
            linear_solver = MadNLPGPU.CUDSSSolver, max_wall_time = wall_limit_s,
            richardson_max_iter = 30, richardson_tol = 1.0e-12,
        )
        merge!(outcome, cell)
    catch err
        outcome["run"] = false
        outcome["converged"] = false
        outcome["reason"] = "The GPU solve raised $(nameof(typeof(err)))."
        outcome["error_message"] = first(sprint(showerror, err), 300)
    end
    return outcome
end

function _cal_identifiability(net, hist)
    sim = ForwardSimulator(net)
    report = identifiability_analysis(
        sim, hist.tags, hist.true_heat_W; truth = hist.truth, groups = hist.groups,
        sample_hours = round.(Int, range(1, 8760; length = 24)),
    )
    names = hist.groups.names
    entry(values) = Dict(names[g] => _cal_round(values[g]; digits = 4) for g in eachindex(names))
    return map(report) do r
        Dict(
            "tags" => r.tag_count,
            "predicted_std_1_month" => Dict("loss" => entry(r.group_std_1_month.loss), "friction" => entry(r.group_std_1_month.friction)),
            "predicted_std_12_months" => Dict("loss" => entry(r.group_std_12_months.loss), "friction" => entry(r.group_std_12_months.friction)),
            "pipe_directions_resolved_12_months" => r.pipe_directions_resolved,
            "pipe_coefficients" => r.pipe_coefficients,
            "sample_hours" => r.sample_hours,
        )
    end
end

# Worst recovery error against the number of tags, one series per length of history. Only converged
# grid points appear.
function _cal_chart(grid)
    converged = filter(c -> get(c, "converged", false), grid)
    series = Dict{String, Any}[]
    for months in CAL_MONTHS
        cells = sort(filter(c -> c["months"] == months, converged); by = c -> c["tags"])
        isempty(cells) && continue
        push!(series, Dict(
            "name" => months == 1 ? "1 month of data" : "$months months of data",
            "x" => [c["tags"] for c in cells],
            "y" => [c["max_error_percent"] for c in cells],
        ))
    end
    isempty(series) && return nothing
    return Dict(
        "title" => "Coefficient recovery error against number of tags",
        "subtitle" => "Synthetic data. Largest relative error over the estimated steam-side coefficient groups.",
        "x_label" => "Tags used",
        "y_label" => "Largest recovery error (%)",
        "x_scale" => "linear",
        "y_scale" => "log",
        "series" => series,
    )
end

# One sentence built from the grid points that converged in this run.
function _cal_finding(grid)
    point(n, m) = findfirst(c -> c["tags"] == n && c["months"] == m && get(c, "converged", false), grid)
    most, least = point(25, 1), point(5, 1)
    most === nothing && return nothing
    text = "On synthetic data, one month of 25 hourly tags recovered every estimated steam-side coefficient " *
        "group to within $(grid[most]["max_error_percent"])%."
    least === nothing && return text
    return text * " With 5 tags the largest error was $(grid[least]["max_error_percent"])%."
end

function _cal_size_label(bytes)
    return "$(round(bytes / 1024^2; digits = 1)) MiB"
end

function _cal_write_template(path, tags)
    open(path, "w") do io
        println(io, "tag_name,category,unit,description")
        for tag in tags
            println(io, join((tag.name, tag.category, tag.unit, tag.description), ','))
        end
    end
    return path
end

"""
    run_calibration(outdir; points = CAL_CI_POINTS, budget_s = CAL_BUDGET_S, gpu = true)

Generate the synthetic historian file, run the calibration grid and write `calibration.json` and
`tag_template.csv` to `outdir`. A point is skipped, and recorded as not run, when the time left in
`budget_s` is less than 1.2 times its solve time predicted from the first point.
"""
function run_calibration(outdir; points = CAL_CI_POINTS, budget_s = CAL_BUDGET_S, gpu = true)
    started = time()
    elapsed() = time() - started
    mkpath(outdir)
    workdir = mktempdir()
    csv = joinpath(workdir, "synthetic_historian.csv")

    generate_s = @elapsed hist = generate_synthetic_historian(csv; hours = CAL_HISTORIAN_HOURS)
    net = CampusSteam.calibration_network()
    read_s = @elapsed table = read_historian(csv)
    length(table) == hist.rows || error("the historian file has $(length(table)) rows, expected $(hist.rows)")
    names = [t.name for t in hist.tags]
    series = align_historian(table; tags = names, start = CampusSteam.HISTORIAN_START, hours = CAL_HISTORIAN_HOURS)
    counts = historian_counts(series)
    example = _cal_bad_example(table, series)

    planned_hours = maximum(m for (_, m) in points) * CampusSteam.HOURS_PER_MONTH
    nominal_s = @elapsed nominal_state = simulate_hours(ForwardSimulator(net), hist.nominal_heat_W[1:planned_hours, :])
    identifiability_s = @elapsed identifiability = _cal_identifiability(net, hist)

    cells = Dict{Tuple{Int, Int}, Dict{String, Any}}()
    seconds_per_hour = 0.0
    reserve = gpu ? CAL_GPU_RESERVE_S : 10.0
    for (n_tags, months) in points
        hours = months * CampusSteam.HOURS_PER_MONTH
        left = budget_s - reserve - elapsed()
        if left < 1.2 * seconds_per_hour * hours || left <= 0
            cells[(n_tags, months)] = _cal_not_run(n_tags, months, "Skipped: the predicted solve time does not fit the time budget of this build.")
            continue
        end
        cell = _cal_point(hist, net, series, nominal_state, n_tags, months; max_wall_time = left)
        seconds_per_hour == 0.0 && (seconds_per_hour = cell["solve_s"] / hours)
        cells[(n_tags, months)] = cell
        println("calibration: $n_tags tags, $months months: $(cell["solver_status"]) in $(cell["solve_s"]) s")
        flush(stdout)
    end
    grid = [
        get(() -> _cal_not_run(n, m, "Not part of this build's grid, to stay within its time budget."), cells, (n, m))
        for n in CAL_TAG_COUNTS for m in CAL_MONTHS
    ]

    gpu_outcome = Dict{String, Any}("attempted" => false, "reason" => "Disabled for this run.")
    if gpu
        limit = max(budget_s - elapsed() - 10.0, 15.0)
        gpu_outcome = _cal_gpu_attempt(hist, net, series, nominal_state, 25, 1, limit)
    end

    categories = unique(t.category for t in hist.tags)
    group_names = hist.groups.names
    output = Dict{String, Any}(
        "synthetic" => true,
        "data_note" => "All data is synthetic: historian-style CSV generated at build time from a simulated network whose true coefficients are known.",
        "network" => Dict(
            "junctions" => length(net.junctions), "pipes" => length(net.pipes), "loads" => length(net.loads),
            "description" => "Synthetic 40-junction campus from the repository's generator.",
        ),
        "historian" => Dict(
            "format" => split(HISTORIAN_HEADER, ','),
            "hours" => hist.hours,
            "tags" => length(hist.tags),
            "rows" => hist.rows,
            "file_bytes" => hist.bytes,
            "tag_hours" => counts.total,
            "good" => counts.good,
            "excluded_bad" => counts.bad,
            "excluded_uncertain" => counts.uncertain,
            "excluded_blank" => counts.blank,
            "absent" => counts.absent,
            "good_percent" => _cal_round(100 * counts.good / counts.total; digits = 2),
        ),
        "true_coefficients" => Dict(
            "groups" => group_names,
            "estimated" => hist.groups.estimated,
            "loss_multiplier" => _cal_round.(hist.truth.group_loss; digits = 4),
            "friction_multiplier" => _cal_round.(hist.truth.group_friction; digits = 4),
            "pipe_spread_percent" => 100 * CampusSteam.TRUE_PIPE_SPREAD,
        ),
        "tags_by_category" => Dict(
            c => [Dict("name" => t.name, "unit" => t.unit, "description" => t.description) for t in hist.tags if t.category == c]
            for c in categories
        ),
        "tag_sets" => Dict(string(n) => names[1:n] for n in CAL_TAG_COUNTS),
        "bad_quality_example" => example,
        "finding" => _cal_finding(grid),
        "chart" => _cal_chart(grid),
        "ask" => Dict(
            "tag_count" => length(hist.tags),
            "years" => hist.hours / 8760,
            "rows" => hist.rows,
            "size_label" => _cal_size_label(hist.bytes),
        ),
        "sample_rows" => [
            Dict("DateTime" => s["time"], "TagName" => example["tag"], "Value" => s["value"], "Quality" => s["quality"])
            for s in example["samples"]
        ],
        "identifiability" => identifiability,
        "grid" => Dict("tag_counts" => CAL_TAG_COUNTS, "months" => CAL_MONTHS, "cells" => grid),
        "gpu" => gpu_outcome,
        "timing_s" => Dict(
            "generate_historian" => _cal_round(generate_s; digits = 1),
            "read_historian" => _cal_round(read_s; digits = 2),
            "nominal_simulation" => _cal_round(nominal_s; digits = 1),
            "identifiability" => _cal_round(identifiability_s; digits = 1),
            "total" => _cal_round(elapsed(); digits = 1),
            "budget" => budget_s,
        ),
    )
    open(joinpath(outdir, "calibration.json"), "w") do io
        JSON.print(io, output, 2)
    end
    _cal_write_template(joinpath(outdir, "tag_template.csv"), hist.tags)
    rm(workdir; recursive = true, force = true)
    println("calibration: wrote results in $(round(elapsed(); digits = 1)) s")
    return output
end

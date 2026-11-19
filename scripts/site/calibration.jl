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

include("pool.jl")

const CAL_TAG_COUNTS = [5, 10, 15, 25]
const CAL_MONTHS = [1, 3, 6, 12, 24]
# Grid points of the site build, in the order they are attempted.
const CAL_CI_POINTS = [(25, 1), (5, 1), (25, 3), (10, 1), (15, 1), (25, 6)]
# Wall-clock budget of the calibration part of the site build, which runs as its own CI job, and the
# time kept for the GPU attempt, the seasonal check and writing results. Local runs of the whole part took
# 644 to 656 s with one process and 295 s with a pool of 8, so a normal build finishes every point well
# inside the budget.
const CAL_BUDGET_S = 960.0
const CAL_GPU_RESERVE_S = 120.0
# Upper limit of the GPU attempt's wall time. The attempt took 71 s in a local run.
const CAL_GPU_MAX_WALL_S = 180.0
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

# Relative error of each estimated group against the true group mean, in percent.
function _cal_error_percent(hist, result)
    errors = recovery_errors(result, hist.truth)
    estimated = findall(hist.groups.estimated)
    return Dict(
        "loss" => Dict(hist.groups.names[g] => _cal_round(100 * errors.loss[g]; digits = 3) for g in estimated),
        "friction" => Dict(hist.groups.names[g] => _cal_round(100 * errors.friction[g]; digits = 3) for g in estimated),
    )
end

# The largest entry of `_cal_error_percent`, and the group and coefficient it belongs to.
function _cal_largest_error(error_percent)
    entries = [(value, group, coefficient) for (coefficient, groups) in error_percent for (group, value) in groups]
    value, group, coefficient = argmax(first, sort(entries; by = e -> (e[2], e[3])))
    return Dict{String, Any}("max_error_percent" => value, "max_error_group" => group, "max_error_coefficient" => coefficient)
end

# A solve cut off by `max_wall_time` says nothing about convergence. It is reported as not run, for
# time, never as "did not converge". The solver status and the time it ran stay in the record.
_cal_stopped_for_time(result) = result.status == string(MadNLP.MAXIMUM_WALLTIME_EXCEEDED)
_cal_time_limit_fields(wall_s) = Dict{String, Any}(
    "run" => false,
    "converged" => false,
    "stopped_for_time" => true,
    "reason" => "Not run: the solve was stopped at the time limit of this build after $(round(wall_s; digits = 1)) s, so no result is reported.",
)

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
    if _cal_stopped_for_time(result)
        merge!(cell, _cal_time_limit_fields(wall_s))
    elseif result.converged
        cell["estimate"] = Dict("loss" => _cal_round.(result.loss), "friction" => _cal_round.(result.friction))
        cell["error_percent"] = _cal_error_percent(hist, result)
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

const CAL_SEASON_OFFSET = 6 * CampusSteam.HOURS_PER_MONTH

# The 25-tag, one-month fit of month 7, for the seasonal check. Returns nothing when there is too little
# time left.
function _cal_month7_solve(hist, net, series, wall_limit_s)
    wall_limit_s < 20 && return nothing
    hours = CampusSteam.HOURS_PER_MONTH
    offset = CAL_SEASON_OFFSET
    range = (offset + 1):(offset + hours)
    window = HistorianSeries(
        series.tags, series.start + Hour(offset), series.values[range, :], series.status[range, :], 0, 0, 0,
    )
    heat = hist.nominal_heat_W[range, :]
    # Each hour warm starts from the one before, so the simulation runs from the first hour.
    state = simulate_hours(ForwardSimulator(net), hist.nominal_heat_W[1:last(range), :])[:, range]
    problem = CalibrationProblem(net, window, hist.tags, heat, state)
    return solve_calibration(build_calibration_model(problem); max_iter = CAL_MAX_ITER, max_wall_time = wall_limit_s)
end

# The same 25-tag, one-month fit in a cold month and in a mild month. A group multiplier is an effective
# average over pipes that differ from each other, so its estimate moves with the flow pattern. `result`
# is the month-7 solve of `_cal_month7_solve`.
function _cal_seasonal_check(hist, january, result)
    months = 1
    offset = CAL_SEASON_OFFSET
    check = Dict{String, Any}(
        "tags" => 25, "months" => months, "groups" => hist.groups.names,
        "true_loss_multiplier" => _cal_round.(hist.truth.group_loss; digits = 4),
        "true_friction_multiplier" => _cal_round.(hist.truth.group_friction; digits = 4),
    )
    if !get(january, "converged", false) || result === nothing
        check["run"] = false
        check["reason"] = "Skipped: the first-month fit did not converge or the time budget of this build was used up."
        return check
    end
    check["run"] = true
    check["windows"] = Any[
        merge(Dict{String, Any}(
            "label" => "month 1", "first_hour" => 1, "solver_status" => january["solver_status"],
            "converged" => true, "solve_s" => january["solve_s"], "estimate" => january["estimate"],
            "error_percent" => january["error_percent"],
        ), _cal_largest_error(january["error_percent"])),
        Dict{String, Any}(
            "label" => "month 7", "first_hour" => offset + 1, "solver_status" => result.status,
            "converged" => result.converged, "solve_s" => _cal_round(result.solve_time_s; digits = 2),
        ),
    ]
    if _cal_stopped_for_time(result)
        merge!(check["windows"][2], _cal_time_limit_fields(result.solve_time_s))
    elseif result.converged
        check["windows"][2]["estimate"] = Dict("loss" => _cal_round.(result.loss), "friction" => _cal_round.(result.friction))
        check["windows"][2]["error_percent"] = _cal_error_percent(hist, result)
        merge!(check["windows"][2], _cal_largest_error(check["windows"][2]["error_percent"]))
    end
    return check
end

# What the converged 25-tag cells of this run show about the length of record, and nothing more.
function _cal_months_finding(grid)
    cells = sort(filter(c -> c["tags"] == 25 && get(c, "converged", false), grid); by = c -> c["months"])
    isempty(cells) && return nothing
    length_of(m) = m == 1 ? "1 month" : "$m months"
    parts = ["$(c["max_error_percent"])% with $(length_of(c["months"]))" for c in cells]
    text = "With 25 tags, the largest recovery error in this build was " * join(parts, ", ", " and ") * " of data."
    length(cells) < 2 && return text
    errors = [c["max_error_percent"] for c in cells]
    falling = all(errors[i] < errors[i - 1] for i in 2:length(errors))
    return text * (falling ? " The error fell each time more months were used." :
        " The error did not fall each time more months were used.")
end

function _cal_findings(net, hist, identifiability, seasonal, grid)
    finest = identifiability[end]
    fitted = join(hist.groups.names[hist.groups.estimated], " and ")
    findings = String[
        "All data is simulated. This test uses a separate $(length(net.junctions))-junction simulated campus, not the $(length(demo_campus().junctions))-junction campus drawn on the map at the top of this page.",
        "One heat-loss value and one friction value are fitted for each group of pipes ($fitted), not for each pipe. " *
        (finest["pipe_directions_resolved_12_months"] < finest["pipe_coefficients"] ?
            "A calculation of what the readings can reveal predicts that $(finest["tags"]) tags over 12 months are not enough to fit a separate value for every pipe to within about 10%." :
            "A calculation of what the readings can reveal predicts that $(finest["tags"]) tags over 12 months could fit a separate value for every pipe to within about 10%."),
        "Heat-loss and friction values for the condensate return pipes are not fitted. They stay at their starting values, and fitting them would need tags on the condensate side.",
        "The simulated pipes in a group are not identical: each pipe's true value varies from the group's value by about $(100 * CampusSteam.TRUE_PIPE_SPREAD)% (one standard deviation). Each fitted value is therefore compared with the average true value of its group, with longer pipes counting for more.",
    ]
    months = _cal_months_finding(grid)
    months === nothing || push!(findings, months)
    if get(seasonal, "run", false) && haskey(seasonal["windows"][2], "estimate")
        first_month, seventh = seasonal["windows"][1]["estimate"], seasonal["windows"][2]["estimate"]
        value(x) = round(x; digits = 3)
        push!(findings, "The friction value of the $(seasonal["groups"][1]) was estimated at $(value(first_month["friction"][1])) from month 1 and $(value(seventh["friction"][1])) from month 7. Its true group average is $(value(seasonal["true_friction_multiplier"][1])).")
    end
    return findings
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
        "subtitle" => "Simulated data. The largest error, in percent, among the fitted steam-side heat-loss and friction values.",
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

# Inputs shared by every solve of the grid, set once in each process of the pool.
const CAL_INPUTS = Ref{Any}(nothing)
_cal_set_inputs!(inputs) = (CAL_INPUTS[] = inputs; nothing)

"""
One independent item of the calibration part, in whichever process runs it: a CPU grid point
`(:point, tags, months)`, the GPU attempt `(:gpu, tags, months)` or the month-7 solve `(:seasonal,)`.
Wall-clock limits are taken from the deadlines in the inputs at the moment the item starts, so they
mean the same in every process of the machine.
"""
function _cal_item(item)
    (; hist, net, series, nominal_state, points_deadline, gpu_deadline, seasonal_deadline) = CAL_INPUTS[]
    kind = first(item)
    if kind === :point
        _, n_tags, months = item
        return _cal_point(hist, net, series, nominal_state, n_tags, months; max_wall_time = points_deadline - time())
    elseif kind === :gpu
        _, n_tags, months = item
        limit = clamp(gpu_deadline - time(), 15.0, CAL_GPU_MAX_WALL_S)
        return _cal_gpu_attempt(hist, net, series, nominal_state, n_tags, months, limit)
    else
        return _cal_month7_solve(hist, net, series, seasonal_deadline - time())
    end
end

# Order of the items. One process keeps the order of `points`, so that the first point predicts the time
# of the others, then the GPU attempt and the seasonal check. A pool starts the longest items first.
function _cal_items(points, gpu, pooled)
    items = Any[(:point, n, m) for (n, m) in points]
    if pooled
        sort!(items; by = it -> (-it[3], it[2]))
        gpu && insert!(items, 2, (:gpu, 25, 1))
        push!(items, (:seasonal,))
    else
        gpu && push!(items, (:gpu, 25, 1))
        push!(items, (:seasonal,))
    end
    return items
end

"""
    run_calibration(outdir; points = CAL_CI_POINTS, budget_s = CAL_BUDGET_S, gpu = true, workers)

Generate the synthetic historian file, run the calibration grid and write `calibration.json` and
`tag_template.csv` to `outdir`. A point is skipped, and recorded as not run, when the time left in
`budget_s` is less than 1.2 times its solve time predicted from the first point that finished.

The grid points, the GPU attempt and the month-7 solve of the seasonal check are independent once the
historian file and the nominal simulation exist. They run on a pool of `workers` processes
(`scripts/site/pool.jl`), so the part takes about as long as its longest point.
"""
function run_calibration(outdir; points = CAL_CI_POINTS, budget_s = CAL_BUDGET_S, gpu = true,
                         workers = site_workers(length(points) + 1 + gpu))
    started = time()
    elapsed() = time() - started
    mkpath(outdir)
    # The workers start while the historian file is generated.
    pool = @async start_pool(workers, [joinpath(@__DIR__, "calibration.jl")])
    yield()
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

    pids = fetch(pool)
    reserve = gpu ? CAL_GPU_RESERVE_S : 10.0
    inputs = (;
        hist, net, series, nominal_state,
        points_deadline = started + budget_s - reserve,
        gpu_deadline = started + budget_s - 10.0,
        seasonal_deadline = started + budget_s - 5.0,
    )
    _cal_set_inputs!(inputs)
    foreach(pid -> remotecall_fetch(_cal_set_inputs!, pid, inputs), pids)
    println("calibration: $(length(points)) grid points, GPU attempt $(gpu), seasonal check, on $(max(length(pids), 1)) process(es)")

    seconds_per_hour = Ref(0.0)
    function before(item)
        first(item) === :point || return nothing
        _, n_tags, months = item
        hours = months * CampusSteam.HOURS_PER_MONTH
        left = inputs.points_deadline - time()
        if left < 1.2 * seconds_per_hour[] * hours || left <= 0
            return _cal_not_run(n_tags, months, "Skipped: the predicted solve time does not fit the time budget of this build.")
        end
        return nothing
    end
    function after(item, outcome)
        kind = first(item)
        if kind === :point && haskey(outcome, "solve_s") && seconds_per_hour[] == 0.0
            seconds_per_hour[] = outcome["solve_s"] / outcome["hours"]
        end
        if kind === :point
            println("calibration: $(item[2]) tags, $(item[3]) months: ", get(outcome, "solver_status", "not run"),
                    get(outcome, "run", false) || haskey(outcome, "solve_s") ? " in $(outcome["solve_s"]) s" : "")
        elseif kind === :gpu
            println("calibration: GPU attempt: ", get(outcome, "solver_status", get(outcome, "reason", "")))
        else
            println("calibration: month-7 solve: ", outcome === nothing ? "not run" : outcome.status)
        end
        flush(stdout)
    end
    items = _cal_items(points, gpu, !isempty(pids))
    outcomes = try
        pool_map(_cal_item, items, pids; before, after)
    finally
        stop_pool(pids)
    end
    outcome_of = Dict(zip(items, outcomes))

    cells = Dict{Tuple{Int, Int}, Dict{String, Any}}(
        (it[2], it[3]) => outcome_of[it] for it in items if first(it) === :point
    )
    grid = [
        get(() -> _cal_not_run(n, m, "Not part of this build's grid, to stay within its time budget."), cells, (n, m))
        for n in CAL_TAG_COUNTS for m in CAL_MONTHS
    ]
    gpu_outcome = gpu ? outcome_of[(:gpu, 25, 1)] : Dict{String, Any}("attempted" => false, "reason" => "Disabled for this run.")
    january = get(cells, (25, 1), Dict{String, Any}())
    seasonal = _cal_seasonal_check(hist, january, outcome_of[(:seasonal,)])
    println("calibration: seasonal check run = $(seasonal["run"])")

    categories = unique(t.category for t in hist.tags)
    group_names = hist.groups.names
    output = Dict{String, Any}(
        "synthetic" => true,
        "data_note" => "All data is synthetic: historian-style CSV generated at build time from a simulated network whose true coefficients are known.",
        "network" => Dict(
            "junctions" => length(net.junctions), "pipes" => length(net.pipes), "loads" => length(net.loads),
            "description" => "Synthetic 40-junction campus from the repository's generator.",
        ),
        "network_used" => Dict(
            "name" => "Synthetic $(length(net.junctions))-junction campus",
            "generator_call" => "scaled_campus($(length(net.junctions)))",
            "is_demo_campus" => false,
            "note" => "The calibration study does not use the $(length(demo_campus().junctions))-junction demo campus.",
        ),
        "findings" => _cal_findings(net, hist, identifiability, seasonal, grid),
        "seasonal_check" => seasonal,
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

# Operational scenarios of the demo campus: definitions, solves and the data written for the site.
# This file needs only CampusSteam, so the test suite can include it. `scenarios.jl` adds the JSON
# output. All data is synthetic and describes the fictional Example University.

using CampusSteam

const SCENARIO_TOL = 1.0e-8
const SCENARIO_MAX_ITER = 1000
const SCHEMA_VERSION = 1

# Hours of the synthetic year. The normal week is well clear of the generated cold snap.
const NORMAL_WEEK = 1177:1344
const SURGE_PERIODS = 49:96
const SURGE_FACTOR = 1.5
# Hours over which the surge builds and fades. A step of 50 percent exceeds the plant ramp limit.
const SURGE_SHOULDER = 3
const DERATE_PERIODS = 25:72
const OUTAGE_PIPE = 20
const OUTAGE_PERIODS = 49:96
const UNIFORM_PRIORITY_WEIGHT = 10.0
# Peak hours of the cold-snap week for the deeper derate, with one boiler left running.
const STRESS_PERIODS = 51:59

# A flow below this size is marked as not unique. See "Scenarios" in docs/site-data.md.
const FLOW_NOT_UNIQUE_BELOW_KG_S = 0.5
# Smaller totals are solver residue, not a building that was shed.
const SHED_REPORT_MIN_MWH = 0.01

const DATA_LABEL = "Synthetic data for the fictional Example University."
const MODEL_LABEL = "Steady-state physics per hour with plant ramp coupling between hours. " *
    "No pipe transients and no valves."

"""
    scenario_case(name, title, description, hours, heat_W, rating_W; outage = nothing, events = [])

One scenario: `hours` of the synthetic year, demand `heat_W` indexed `(period, load)`, the plant rating
of each period, and `outage = (pipe, periods)` for a pipe out of service.
"""
scenario_case(name, title, description, hours, heat_W, rating_W; outage = nothing, events = Any[]) =
    (; name, title, description, hours, heat_W, rating_W, outage, events)

full_rating(net, n) = fill(net.plant.rating_W, n)
one_boiler_out_W(net) = net.plant.rating_W * (net.plant.n_boilers - 1) / net.plant.n_boilers
cold_snap_week(profiles) = findfirst(profiles.is_cold_snap):findlast(profiles.is_cold_snap)

function baseline_case(net, profiles; hours = NORMAL_WEEK)
    return scenario_case(
        "baseline", "Normal winter week", "A normal winter week with every boiler and pipe in service.",
        hours, profiles.heat_W[hours, :], full_rating(net, length(hours)),
    )
end

"Demand multiplier of each period: `SURGE_FACTOR` during `surge`, with linear shoulders on both sides."
function surge_factors(T, surge; shoulder = SURGE_SHOULDER)
    return map(1:T) do k
        distance = k < first(surge) ? first(surge) - k : k > last(surge) ? k - last(surge) : 0
        return 1 + (SURGE_FACTOR - 1) * max(0, 1 - distance / (shoulder + 1))
    end
end

function cold_snap_case(net, profiles; hours = NORMAL_WEEK, surge = SURGE_PERIODS, shoulder = SURGE_SHOULDER)
    heat = profiles.heat_W[hours, :] .* surge_factors(length(hours), surge; shoulder)
    return scenario_case(
        "cold_snap", "Cold snap",
        "The normal winter week with every load 50 percent higher for $(length(surge)) hours, building and fading over $shoulder hours on each side.",
        hours, heat, full_rating(net, length(hours));
        events = Any[Dict("kind" => "load_surge", "first_hour" => first(surge), "last_hour" => last(surge),
            "factor" => SURGE_FACTOR, "shoulder_hours" => shoulder)],
    )
end

function plant_derate_case(net, profiles; hours = cold_snap_week(profiles), outage = DERATE_PERIODS)
    rating = full_rating(net, length(hours))
    rating[outage] .= one_boiler_out_W(net)
    return scenario_case(
        "plant_derate", "One boiler out",
        "The generated cold-snap week with one of four boilers out for 48 hours, so the plant cannot meet the peak.",
        hours, profiles.heat_W[hours, :], rating;
        events = Any[Dict("kind" => "boiler_out", "first_hour" => first(outage), "last_hour" => last(outage),
            "rating_MW" => one_boiler_out_W(net) / 1.0e6)],
    )
end

"""
    deeper_derate_case(net, profiles)

Only one boiler running through the peak hours of the cold-snap week. One boiler out never reaches the
critical load, so this harsher case is what shows the effect of the priority weights on it.
"""
function deeper_derate_case(net, profiles)
    hours = cold_snap_week(profiles)[STRESS_PERIODS]
    rating = net.plant.rating_W / net.plant.n_boilers
    return scenario_case(
        "deeper_derate", "One boiler running",
        "Stress case: only one of four boilers running through $(length(hours)) peak hours of the cold-snap week.",
        hours, profiles.heat_W[hours, :], fill(rating, length(hours)),
    )
end

function pipe_out_case(net, profiles; hours = NORMAL_WEEK, pipe = OUTAGE_PIPE, outage = OUTAGE_PERIODS)
    return scenario_case(
        "pipe_out", "Steam main out of service",
        "The normal winter week with one looped steam main segment out of service for 48 hours.",
        hours, profiles.heat_W[hours, :], full_rating(net, length(hours));
        outage = (pipe, outage),
        events = Any[Dict("kind" => "pipe_out", "pipe" => pipe, "first_hour" => first(outage),
            "last_hour" => last(outage))],
    )
end

"""
    solve_case(net, case; priority_weight = nothing)

Solve one scenario. Outage cases use `solve_multiperiod_oriented` from all three starting orientations.
Returns the solution, the orientation method, the number of NLP solves and the wall-clock time.
"""
function solve_case(net, case; priority_weight = nothing)
    method, rounds = "input network orientation", 1
    local solution
    elapsed = @elapsed if case.outage === nothing
        solution = solve_multiperiod(
            net; heat_W = case.heat_W, plant_rating_W = case.rating_W, priority_weight,
            tol = SCENARIO_TOL, max_iter = SCENARIO_MAX_ITER,
        )
    else
        pipe, periods = case.outage
        result = solve_multiperiod_oriented(
            net; heat_W = case.heat_W, plant_rating_W = case.rating_W, priority_weight,
            out_of_service = [pipe => periods], methods = (:search, :demand, :design),
            tol = SCENARIO_TOL, max_iter = SCENARIO_MAX_ITER,
        )
        solution, rounds = result.solution, result.rounds
        method = "solve_multiperiod_oriented, best start: $(result.method)"
    end
    return (; solution, method, rounds, elapsed_s = elapsed)
end

"Only a full solve at the stated tolerance is presented; MadNLP's acceptable level is not enough."
solved_at_tolerance(solution) = solution.status === :SOLVE_SUCCEEDED

# Summaries ---------------------------------------------------------------------------------------

load_ids_of_type(net, type) = [l.id for l in net.loads if l.type == type]

function buildings_shed(net, solution)
    shed = vec(sum(solution.load_shed_W; dims = 1)) ./ 1.0e6
    ids = sort!(findall(>=(SHED_REPORT_MIN_MWH), shed); by = id -> -shed[id])
    return [
        Dict(
            "load" => id, "name" => net.loads[id].name, "type" => net.loads[id].type,
            "shed_MWh" => round(shed[id]; digits = 3),
            "peak_shed_MW" => round(maximum(solution.load_shed_W[:, id]) / 1.0e6; digits = 3),
        ) for id in ids
    ]
end

function scenario_summary(net, solution)
    audit = energy_audit(solution)
    critical = load_ids_of_type(net, "critical")
    return Dict(
        "peak_output_MW" => round(maximum(solution.plant_output_W) / 1.0e6; digits = 3),
        "total_demand_MWh" => round(sum(solution.load_demand_W) / 1.0e6; digits = 2),
        "total_shed_MWh" => round(sum(audit.shed_W) / 1.0e6; digits = 3),
        "critical_shed_MWh" => round(sum(solution.load_shed_W[:, critical]) / 1.0e6; digits = 3),
        "total_losses_MWh" => round(sum(audit.pipe_loss_W) / 1.0e6; digits = 2),
        "total_excess_MWh" => round(sum(audit.excess_W) / 1.0e6; digits = 3),
        "buildings_shed" => buildings_shed(net, solution),
    )
end

shed_by_type(net, solution) = Dict(
    type => round(sum(solution.load_shed_W[:, load_ids_of_type(net, type)]) / 1.0e6; digits = 3)
    for type in unique(l.type for l in net.loads)
)

function priority_comparison(net, weighted, uniform, stress_case, stress_weighted, stress_uniform)
    entry(label, weights, run) = Dict(
        "label" => label, "weights" => weights,
        "status" => string(run.solution.status),
        "presented" => solved_at_tolerance(run.solution),
        "iterations" => run.solution.iterations,
        "solve_time_s" => round(run.elapsed_s; digits = 1),
        "summary" => solved_at_tolerance(run.solution) ?
            delete!(scenario_summary(net, run.solution), "buildings_shed") : nothing,
        "shed_by_type_MWh" => solved_at_tolerance(run.solution) ? shed_by_type(net, run.solution) : nothing,
    )
    uniform_weights = Dict("all" => UNIFORM_PRIORITY_WEIGHT)
    type_weights = Dict(t => first(l.priority_weight for l in net.loads if l.type == t) for t in unique(l.type for l in net.loads))
    return Dict(
        "note" => "Each pair of cases solves the same hours. Buildings with equal weights can trade " *
            "shed load almost freely, so read the totals by type rather than the split between buildings.",
        "cases" => [
            entry("Priority weights by building type", type_weights, weighted),
            entry("Uniform priority weight", uniform_weights, uniform),
        ],
        "deeper_derate" => Dict(
            "title" => stress_case.title, "description" => stress_case.description,
            "rating_MW" => first(stress_case.rating_W) / 1.0e6, "hours" => length(stress_case.hours),
            "first_hour_of_synthetic_year" => first(stress_case.hours),
            "cases" => [
                entry("Priority weights by building type", type_weights, stress_weighted),
                entry("Uniform priority weight", uniform_weights, stress_uniform),
            ],
        ),
    )
end

# Compares flows with the same hours of the reference week, on steam pipes only.
function reroute_summary(net, case, solution, reference)
    pipe, periods = case.outage
    steam = [p.id for p in net.pipes if p.side == "steam" && p.id != pipe]
    limit = FLOW_NOT_UNIQUE_BELOW_KG_S
    mean_over(a, id) = sum(a[k, id] for k in periods) / length(periods)
    changes = sort!(steam; by = id -> -abs(mean_over(solution.pipe_flow_kg_per_s, id) - mean_over(reference.pipe_flow_kg_per_s, id)))
    reversed = Dict{String, Any}[]
    for id in sort(steam)
        hours = count(periods) do k
            a, b = solution.pipe_flow_kg_per_s[k, id], reference.pipe_flow_kg_per_s[k, id]
            a * b < 0 && abs(a) >= limit && abs(b) >= limit
        end
        hours > 0 && push!(reversed, Dict("pipe" => id, "hours" => hours))
    end
    return Dict(
        "pipe_out" => pipe, "first_hour" => first(periods), "last_hour" => last(periods),
        "reference_scenario" => "baseline",
        "reversed_steam_pipes" => reversed,
        "largest_flow_changes" => [
            Dict(
                "pipe" => id,
                "reference_mean_kg_s" => round(mean_over(reference.pipe_flow_kg_per_s, id); digits = 2),
                "outage_mean_kg_s" => round(mean_over(solution.pipe_flow_kg_per_s, id); digits = 2),
            ) for id in changes[1:min(8, end)]
        ],
    )
end

# Compact arrays ----------------------------------------------------------------------------------

# Whole numbers are written without a decimal point to keep the files small.
function compact(x, digits)
    v = round(x; digits)
    return v == round(v) ? round(Int, v) : v
end
hourly(f, T) = [f(k) for k in 1:T]

# Runs of consecutive true entries as [first, last] pairs.
function runs(mask)
    out = Vector{Vector{Int}}()
    for (k, flag) in enumerate(mask)
        flag || continue
        if !isempty(out) && out[end][2] == k - 1
            out[end][2] = k
        else
            push!(out, [k, k])
        end
    end
    return out
end

"Hours in which a steam pipe is in service and carries too little flow for that flow to be unique."
function flow_not_unique_hours(net, solution)
    marks = Dict{String, Any}()
    for id in (p.id for p in net.pipes if p.side == "steam")
        mask = solution.pipe_in_service[:, id] .&
            (abs.(solution.pipe_flow_kg_per_s[:, id]) .< FLOW_NOT_UNIQUE_BELOW_KG_S)
        any(mask) && (marks[string(id)] = runs(mask))
    end
    return marks
end

"""
Hours in which a steam node carries too little flow for its state to be unique: every in-service steam
pipe at the node is below the flow limit. A building whose load is shed is the usual case.
"""
function node_not_unique_hours(net, solution)
    incident = Dict(j.id => Int[] for j in net.junctions if j.side == "steam")
    for p in net.pipes
        p.side == "steam" || continue
        push!(incident[p.from], p.id)
        push!(incident[p.to], p.id)
    end
    marks = Dict{String, Any}()
    for (node, pipes) in incident
        mask = [
            all(abs(solution.pipe_flow_kg_per_s[k, p]) < FLOW_NOT_UNIQUE_BELOW_KG_S for p in pipes)
            for k in 1:solution.nperiod
        ]
        any(mask) && (marks[string(node)] = runs(mask))
    end
    return marks
end

# How far each exported quantity can be trusted. The values are explained in docs/site-data.md.
const UNIQUENESS_NOTES = Dict(
    "plant_output" => "unique",
    "total_shed" => "unique",
    "shed_by_type" => "unique",
    "shed_by_building" => "not_unique_within_equal_weights",
    "total_losses" => "indicative",
    "steam_temperature" => "unique_except_marked_hours",
    "steam_pressure" => "indicative_except_marked_hours",
    "steam_pipe_flow" => "unique_except_marked_hours",
    "steam_pipe_loss" => "unique_except_marked_hours",
    "water_pipe_flow" => "not_unique",
    "water_pipe_loss" => "not_unique",
    "water_pressure" => "not_exported",
    "water_temperature" => "not_exported",
)

"The JSON document of one scenario, as nested dictionaries."
function scenario_payload(net, case, run; extras = Dict{String, Any}())
    s = run.solution
    presented = solved_at_tolerance(s)
    doc = Dict{String, Any}(
        "schema_version" => SCHEMA_VERSION,
        "scenario" => case.name, "title" => case.title, "description" => case.description,
        "data_label" => DATA_LABEL, "model_label" => MODEL_LABEL, "synthetic" => true,
        "hours" => length(case.hours), "first_hour_of_synthetic_year" => first(case.hours),
        "events" => case.events,
        "solver" => Dict(
            "status" => string(s.status), "converged_at_tolerance" => presented,
            "tolerance" => SCENARIO_TOL, "iterations" => s.iterations,
            "solve_time_s" => round(run.elapsed_s; digits = 1), "nlp_solves" => run.rounds,
            "orientation_method" => run.method,
        ),
        "presented" => presented,
    )
    presented || return doc

    T = s.nperiod
    steam_nodes = [j.id for j in net.junctions if j.side == "steam"]
    pipes = [p.id for p in net.pipes]
    audit = energy_audit(s)
    doc["summary"] = scenario_summary(net, s)
    doc["uniqueness"] = UNIQUENESS_NOTES
    doc["flow_not_unique_below_kg_s"] = FLOW_NOT_UNIQUE_BELOW_KG_S
    doc["plant"] = Dict(
        "output_MW" => [compact(x / 1.0e6, 3) for x in s.plant_output_W],
        "rating_MW" => [compact(x / 1.0e6, 3) for x in s.plant_rating_W],
        "demand_MW" => [compact(sum(s.load_demand_W[k, :]) / 1.0e6, 3) for k in 1:T],
        "shed_MW" => [compact(x / 1.0e6, 3) for x in audit.shed_W],
        "excess_MW" => [compact(x / 1.0e6, 3) for x in audit.excess_W],
        "losses_MW" => [compact(x / 1.0e6, 3) for x in audit.pipe_loss_W],
    )
    doc["nodes"] = Dict(
        "ids" => steam_nodes,
        "pressure_kPa" => hourly(k -> [compact(s.junction_pressure_Pa[k, j] / 1.0e3, 1) for j in steam_nodes], T),
        "temperature_C" => hourly(k -> [compact(s.junction_temperature_K[k, j] - 273.15, 2) for j in steam_nodes], T),
        "not_unique_hours" => node_not_unique_hours(net, s),
    )
    doc["pipes"] = Dict(
        "ids" => pipes,
        "flow_kg_s" => hourly(k -> [s.pipe_in_service[k, p] ? compact(s.pipe_flow_kg_per_s[k, p], 2) : nothing for p in pipes], T),
        "loss_kW" => hourly(k -> [s.pipe_in_service[k, p] ? compact(s.pipe_heat_loss_W[k, p] / 1.0e3, 1) : nothing for p in pipes], T),
        "flow_not_unique_hours" => flow_not_unique_hours(net, s),
    )
    doc["loads"] = Dict(
        "ids" => [l.id for l in net.loads],
        "shed_MW" => hourly(k -> [compact(s.load_shed_W[k, l.id] / 1.0e6, 3) for l in net.loads], T),
        "excess_MW" => hourly(k -> [compact(s.load_excess_W[k, l.id] / 1.0e6, 3) for l in net.loads], T),
    )
    return merge!(doc, extras)
end

"The JSON document that describes the network, as nested dictionaries."
function network_payload(net)
    return Dict{String, Any}(
        "schema_version" => SCHEMA_VERSION, "campus" => "Example University (fictional)",
        "data_label" => DATA_LABEL, "model_label" => MODEL_LABEL, "synthetic" => true,
        "junctions" => Dict(
            "id" => [j.id for j in net.junctions], "side" => [j.side for j in net.junctions],
            "kind" => [j.kind for j in net.junctions], "x_m" => [j.x_m for j in net.junctions],
            "y_m" => [j.y_m for j in net.junctions],
        ),
        "pipes" => Dict(
            "id" => [p.id for p in net.pipes], "side" => [p.side for p in net.pipes],
            "from" => [p.from for p in net.pipes], "to" => [p.to for p in net.pipes],
            "length_m" => [p.length_m for p in net.pipes], "diameter_m" => [p.diameter_m for p in net.pipes],
            "is_loop" => [p.is_loop for p in net.pipes],
        ),
        "loads" => Dict(
            "id" => [l.id for l in net.loads], "name" => [l.name for l in net.loads],
            "type" => [l.type for l in net.loads], "steam_junction" => [l.steam_junction for l in net.loads],
            "design_heat_MW" => [round(l.design_heat_W / 1.0e6; digits = 3) for l in net.loads],
            "priority_weight" => [l.priority_weight for l in net.loads],
        ),
        "plant" => Dict(
            "steam_junction" => net.plant.steam_junction, "rating_MW" => net.plant.rating_W / 1.0e6,
            "n_boilers" => net.plant.n_boilers, "one_boiler_out_MW" => one_boiler_out_W(net) / 1.0e6,
            "ramp_limit_MW_per_h" => net.plant.ramp_limit_W_per_h / 1.0e6,
        ),
    )
end

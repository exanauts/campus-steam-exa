# Capacity-planning study of the demo campus: today's network, the same network with one new
# building ("tomorrow"), and upgrade options applied to tomorrow's network, each solved over the
# cold-snap week of the synthetic year. Needs `scenario_cases.jl`, which defines the solve and the
# summaries, so the test suite can include both. `scenarios.jl` writes the JSON. All data is
# synthetic and describes the fictional Example University.

using CampusSteam

const EXPANSION_SCHEMA_VERSION = 1
# The new building: a large lab at the corner of the north-east lab branch, east of its tap.
const NEW_BUILDING_TAP = 37
const NEW_BUILDING_POSITION_M = (600.0, 780.3)
const NEW_BUILDING_TYPE = "lab"
const NEW_BUILDING_HEAT_W = 22.0e6
# Upgrade options. The branch main is every steam pipe on the route from the plant to the tap that
# is not part of a loop; it goes up from 0.30 m to this diameter.
const BRANCH_MAIN_DIAMETER_M = 0.45
# A new steam and return main from this junction on the lab-district ring to the tap closes a loop.
const TIE_FROM = 16
const TIE_DIAMETER_M = 0.30
# Better insulation halves the heat-loss coefficient of the steam trunk: the feeders and every steam
# main of at least this diameter.
const TRUNK_MIN_DIAMETER_M = 0.40
const INSULATION_FACTOR = 0.5
# A plant hour counts as at its rating within this margin.
const AT_RATING_MW = 0.01
# Steam velocity the generator sizes pipes for. The model itself has no velocity limit.
const DESIGN_STEAM_VELOCITY_M_S = 35.0
const GAS_CONSTANT_STEAM = SteamModelOptions().gas_constant_J_per_kgK

steam_ids(net, ids) = [id for id in ids if net.pipes[id].side == "steam"]
branch_main(net) = [id for id in steam_path(net, NEW_BUILDING_TAP) if !net.pipes[id].is_loop]
trunk_pipes(net) = [p.id for p in net.pipes if p.side == "steam" && p.diameter_m >= TRUNK_MIN_DIAMETER_M &&
    net.junctions[p.from].kind != "load" && net.junctions[p.to].kind != "load"]

junction_entry(net, id) = Dict("id" => id, "x_m" => net.junctions[id].x_m, "y_m" => net.junctions[id].y_m)
pipe_entry(net, id) = Dict("id" => id, "from" => net.pipes[id].from, "to" => net.pipes[id].to,
    "diameter_m" => net.pipes[id].diameter_m, "length_m" => net.pipes[id].length_m)

"""
    expansion_cases(today) -> Vector

The cases of the study, in display order. Each has `name`, `label`, `description`, the network `net`,
the plant `rating_W`, and `changes`: what differs from today's network, steam side only, with ids in
that case's network. Existing junction, pipe and load ids are the same in every case.
"""
function expansion_cases(today::CampusNetwork)
    tomorrow, ids = add_building(today; tap = NEW_BUILDING_TAP, x_m = NEW_BUILDING_POSITION_M[1],
        y_m = NEW_BUILDING_POSITION_M[2], type = NEW_BUILDING_TYPE, design_heat_W = NEW_BUILDING_HEAT_W)
    load = tomorrow.loads[ids.load]
    building = Dict(
        "load" => load.id, "name" => load.name, "type" => load.type,
        "design_heat_MW" => round(load.design_heat_W / 1.0e6; digits = 3),
        "steam_junction" => junction_entry(tomorrow, ids.steam_junction), "tap" => NEW_BUILDING_TAP,
        "lateral" => pipe_entry(tomorrow, ids.steam_pipe),
    )
    base_changes() = Dict{String, Any}("new_building" => building, "added_pipes" => Any[],
        "resized_pipes" => Any[], "insulated_pipes" => Int[], "plant_rating_MW" => nothing)

    main = branch_main(tomorrow)
    upsized = resize_pipe(tomorrow, main; diameter_m = BRANCH_MAIN_DIAMETER_M)
    tied, tie = add_pipe_pair(tomorrow, TIE_FROM, NEW_BUILDING_TAP; diameter_m = TIE_DIAMETER_M)
    trunk = trunk_pipes(tomorrow)
    insulated = scale_heat_loss(tomorrow, trunk, INSULATION_FACTOR)
    boiler = add_boiler(tomorrow)

    case(name, label, description, net; changes = base_changes()) =
        (; name, label, description, net, rating_W = net.plant.rating_W, changes)

    upsized_changes = base_changes()
    upsized_changes["resized_pipes"] = [Dict("id" => id, "from" => tomorrow.pipes[id].from, "to" => tomorrow.pipes[id].to,
        "diameter_before_m" => tomorrow.pipes[id].diameter_m, "diameter_after_m" => upsized.pipes[id].diameter_m) for id in main]
    tie_changes = base_changes()
    tie_changes["added_pipes"] = [pipe_entry(tied, tie.steam_pipe)]
    insulation_changes = base_changes()
    insulation_changes["insulated_pipes"] = trunk
    insulation_changes["insulation_factor"] = INSULATION_FACTOR
    boiler_changes = base_changes()
    boiler_changes["plant_rating_MW"] = boiler.plant.rating_W / 1.0e6
    boiler_changes["n_boilers"] = boiler.plant.n_boilers

    today_changes = Dict{String, Any}("new_building" => nothing, "added_pipes" => Any[], "resized_pipes" => Any[],
        "insulated_pipes" => Int[], "plant_rating_MW" => nothing)
    mw(x) = round(x / 1.0e6; digits = 1)
    return [
        case("today", "Today", "Today's campus and plant.", today; changes = today_changes),
        case("tomorrow", "Tomorrow",
            "The same campus and plant with one new $(mw(load.design_heat_W)) MW lab ($(load.name)) at the end of the north-east lab branch.",
            tomorrow),
        case("larger_main", "Larger branch main",
            "Tomorrow, with the branch main toward the new building enlarged from $(join(unique(tomorrow.pipes[id].diameter_m for id in main), ", ")) m to $(BRANCH_MAIN_DIAMETER_M) m.",
            upsized; changes = upsized_changes),
        case("cross_tie", "New cross-tie",
            "Tomorrow, with a new $(TIE_DIAMETER_M) m steam main and its return from the lab-district ring to the new building's tap, closing a loop.",
            tied; changes = tie_changes),
        case("insulation", "Better trunk insulation",
            "Tomorrow, with the heat-loss coefficient of the steam trunk halved.",
            insulated; changes = insulation_changes),
        case("extra_boiler", "Fifth boiler",
            "Tomorrow, with a fifth boiler of the same size, raising the plant rating from $(mw(tomorrow.plant.rating_W)) MW to $(mw(boiler.plant.rating_W)) MW.",
            boiler; changes = boiler_changes),
    ]
end

"The study's hours: the cold-snap week of the synthetic year, as in the boiler-out scenario."
expansion_hours(profiles) = cold_snap_week(profiles)

const EXPANSION_ORIENTATION = "pipe directions of each hour from the hydraulic flow at that hour's demand (orient_for_demand)"

"""
    expansion_solve(net, heat_W, rating_W)

Solve a run of hours with the pipe directions of each hour taken from the hydraulic flow at that
hour's demand. The edited networks were not drawn by the generator, which keeps every loop's flow
direction fixed over a year, so a loop may change direction between hours; a fixed orientation would
then pin a pipe at its minimum flow and force excess heat. Returns the same fields as `solve_case`.
"""
function expansion_solve(net, heat_W, rating_W)
    networks = [orient_for_demand(net; heat_W = heat_W[k, :]) for k in axes(heat_W, 1)]
    local solution
    elapsed = @elapsed solution = solve_multiperiod(
        net; heat_W, plant_rating_W = rating_W, networks, tol = SCENARIO_TOL, max_iter = SCENARIO_MAX_ITER,
    )
    return (; solution, method = EXPANSION_ORIENTATION, rounds = 1, elapsed_s = elapsed,
        orientations = length(unique(n.pipes for n in networks)))
end

"""
    expansion_solve_case(c, profiles)

Solve one case over the cold-snap week with every boiler in service. `profiles` must be generated for
the case's network, so the new building has its own hourly demand.
"""
function expansion_solve_case(c, profiles)
    hours = expansion_hours(profiles)
    return expansion_solve(c.net, profiles.heat_W[hours, :], fill(c.rating_W, length(hours)))
end

# Steam velocity in each hour, from the flow and the mean of the end pressures and temperatures.
function steam_velocity(net, s, id, k)
    p = net.pipes[id]
    pressure = (s.junction_pressure_Pa[k, p.from] + s.junction_pressure_Pa[k, p.to]) / 2
    temperature = (s.junction_temperature_K[k, p.from] + s.junction_temperature_K[k, p.to]) / 2
    density = pressure / (GAS_CONSTANT_STEAM * temperature)
    return abs(s.pipe_flow_kg_per_s[k, id]) / (density * pi * p.diameter_m^2 / 4)
end

# A steam junction whose every steam pipe carries at least the flow limit, in hour k. Pressures at
# such junctions are not among the quantities marked as not unique.
function loaded_junctions(net, s, k)
    flows = Dict{Int, Float64}()
    for p in net.pipes
        p.side == "steam" || continue
        f = abs(s.pipe_flow_kg_per_s[k, p.id])
        for j in (p.from, p.to)
            flows[j] = min(get(flows, j, Inf), f)
        end
    end
    return [j for (j, f) in flows if f >= FLOW_NOT_UNIQUE_BELOW_KG_S]
end

"""
    expansion_outcome(c, run, profiles)

The results of one case for the site: solver status, and, when the solve reached the tolerance,
undelivered heat by building type, delivered heat, pipe losses, the plant against its rating, and
the steam-side checks that say whether the plant or a pipe limits the network.
"""
function expansion_outcome(c, run, profiles)
    s = run.solution
    presented = solved_at_tolerance(s)
    entry = Dict{String, Any}(
        "case" => c.name, "label" => c.label, "description" => c.description,
        "status" => string(s.status), "converged" => presented, "iterations" => s.iterations,
        "solve_time_s" => round(run.elapsed_s; digits = 1),
        "orientation" => run.method, "orientation_patterns" => get(run, :orientations, nothing),
        "plant_rating_MW" => c.rating_W / 1.0e6, "changes" => c.changes,
    )
    presented || return entry
    net = c.net
    audit = energy_audit(s)
    T = s.nperiod
    shed_hours = [k for k in 1:T if audit.shed_W[k] / 1.0e6 >= SHED_REPORT_MIN_MWH]
    at_rating = [k for k in 1:T if s.plant_output_W[k] >= s.plant_rating_W[k] - AT_RATING_MW * 1.0e6]
    pressure_min = SteamModelOptions().pressure_min_Pa
    # Lowest steam pressure at loaded junctions, over the hours with undelivered heat, or over the
    # whole week when there are none.
    check_hours = isempty(shed_hours) ? collect(1:T) : shed_hours
    lowest = Inf
    for k in check_hours, j in loaded_junctions(net, s, k)
        lowest = min(lowest, s.junction_pressure_Pa[k, j])
    end
    route = [id for id in steam_path(net, NEW_BUILDING_TAP)]
    velocity = maximum(steam_velocity(net, s, id, k) for id in route for k in 1:T)
    fastest = route[argmax([maximum(steam_velocity(net, s, id, k) for k in 1:T) for id in route])]
    steam = [p.id for p in net.pipes if p.side == "steam"]
    entry["shed_by_type_MWh"] = shed_by_type(net, s)
    entry["summary"] = Dict(
        "total_demand_MWh" => round(sum(s.load_demand_W) / 1.0e6; digits = 2),
        "total_delivered_MWh" => round(sum(audit.delivered_W) / 1.0e6; digits = 2),
        "total_shed_MWh" => round(sum(audit.shed_W) / 1.0e6; digits = 3),
        "total_losses_MWh" => round(sum(audit.pipe_loss_W) / 1.0e6; digits = 2),
        "steam_losses_MWh" => round(sum(s.pipe_heat_loss_W[:, steam]) / 1.0e6; digits = 2),
        "total_excess_MWh" => round(sum(audit.excess_W) / 1.0e6; digits = 3),
        "peak_demand_MW" => round(maximum(sum(s.load_demand_W; dims = 2)) / 1.0e6; digits = 3),
        "peak_output_MW" => round(maximum(s.plant_output_W) / 1.0e6; digits = 3),
        "hours" => T, "hours_with_shed" => length(shed_hours),
        "hours_at_rating" => length(at_rating),
        "shed_hours_at_rating" => count(in(at_rating), shed_hours),
    )
    entry["steam_checks"] = Dict(
        "lowest_loaded_pressure_kPa" => isfinite(lowest) ? round(lowest / 1.0e3; digits = 1) : nothing,
        "pressure_min_kPa" => round(pressure_min / 1.0e3; digits = 1),
        "hours_checked" => isempty(shed_hours) ? "all" : "hours_with_shed",
        "route_to_new_building" => route,
        "max_velocity_on_route_m_s" => round(velocity; digits = 1),
        "fastest_pipe_on_route" => fastest,
        "design_velocity_m_s" => DESIGN_STEAM_VELOCITY_M_S,
    )
    if c.changes["new_building"] !== nothing
        id = c.changes["new_building"]["load"]
        entry["new_building"] = Dict(
            "demand_MWh" => round(sum(s.load_demand_W[:, id]) / 1.0e6; digits = 2),
            "peak_demand_MW" => round(maximum(s.load_demand_W[:, id]) / 1.0e6; digits = 3),
        )
    end
    return entry
end

"""
    limiting_factor(outcomes)

What limits tomorrow's network, from the plant output and steam-side pressures of tomorrow's solve and
the outcomes of the options. Uses only quantities that are unique at the optimum (plant output, total
and by-type undelivered heat) and steam pressures at loaded junctions.
"""
function limiting_factor(outcomes)
    by = Dict(o["case"] => o for o in outcomes)
    t = get(by, "tomorrow", nothing)
    (t === nothing || !t["converged"]) && return Dict("kind" => "not_available",
        "statement" => "Tomorrow's case did not converge, so no limit is stated.")
    sm, ck = t["summary"], t["steam_checks"]
    if sm["hours_with_shed"] == 0
        return Dict("kind" => "none", "statement" => "Tomorrow's network delivers all heat in the week.")
    end
    plant_bound = sm["shed_hours_at_rating"] == sm["hours_with_shed"]
    margin = ck["lowest_loaded_pressure_kPa"] === nothing ? nothing : ck["lowest_loaded_pressure_kPa"] - ck["pressure_min_kPa"]
    pressure_slack = margin !== nothing && margin > 50
    kind = plant_bound && pressure_slack ? "plant_capacity" : !plant_bound ? "network" : "plant_and_network"
    statement = kind == "plant_capacity" ?
        "In every one of the $(sm["hours_with_shed"]) hours with undelivered heat the plant runs at its rating of $(t["plant_rating_MW"]) MW, while the lowest steam pressure at a loaded junction stays at $(ck["lowest_loaded_pressure_kPa"]) kPa, far above the $(ck["pressure_min_kPa"]) kPa minimum. The plant's capacity limits tomorrow's network, not the pipes." :
        kind == "network" ?
        "Heat goes undelivered in $(sm["hours_with_shed"] - sm["shed_hours_at_rating"]) hours in which the plant is below its rating, so the pipes limit tomorrow's network." :
        "The plant runs at its rating in every hour with undelivered heat, and steam pressure comes within 50 kPa of its minimum, so both limit tomorrow's network."
    return Dict("kind" => kind, "statement" => statement, "plant_at_rating_in_every_shed_hour" => plant_bound,
        "pressure_margin_kPa" => margin === nothing ? nothing : round(margin; digits = 1))
end

"The JSON document of the study, as nested dictionaries. `hours` are the hours of the synthetic year."
function expansion_payload(hours, outcomes)
    return Dict{String, Any}(
        "schema_version" => EXPANSION_SCHEMA_VERSION,
        "study" => "new_building",
        "question" => "Can today's plant and pipes carry one more building in the coldest week, and what do the upgrade options change?",
        "data_label" => DATA_LABEL, "model_label" => MODEL_LABEL, "synthetic" => true,
        "constructed" => "The new building's size and place were chosen by hand to show the method.",
        "hours" => length(hours), "first_hour_of_synthetic_year" => first(hours),
        "week" => "The cold-snap week of the synthetic year, the coldest week, with every boiler in service.",
        "tolerance" => SCENARIO_TOL,
        "shed_report_min_MWh" => SHED_REPORT_MIN_MWH,
        "flow_not_unique_below_kg_s" => FLOW_NOT_UNIQUE_BELOW_KG_S,
        "cases" => outcomes,
        "limit" => limiting_factor(outcomes),
    )
end

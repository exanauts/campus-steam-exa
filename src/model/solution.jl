"""
    SteamSolution

Result of [`solve_steam`](@ref) in SI units.

Solver: `status`, `converged`, `objective_W`, `iterations`, `solve_time_s`,
`primal_infeasibility` and `dual_infeasibility` (scaled, as reported by MadNLP).

Junctions: `junction_pressure_Pa`, `junction_temperature_K`.

Pipes: `pipe_flow_kg_per_s`, `pipe_inlet_temp_K`, `pipe_outlet_temp_K`, `pipe_heat_loss_W`,
`pipe_pressure_drop_Pa` (inlet minus outlet, before any pump boost), `pump_boost_Pa`.

Loads: `load_flow_kg_per_s`, `load_inlet_temp_K`, `load_outlet_temp_K`, `load_demand_W`,
`load_delivered_W`, `load_shed_W`, `load_excess_W`.

Plant: `plant_output_W`, `plant_flow_kg_per_s`, `plant_inlet_temp_K`, `plant_outlet_temp_K`.
"""
struct SteamSolution
    status::Symbol
    converged::Bool
    objective_W::Float64
    iterations::Int
    solve_time_s::Float64
    primal_infeasibility::Float64
    dual_infeasibility::Float64
    junction_pressure_Pa::Vector{Float64}
    junction_temperature_K::Vector{Float64}
    pipe_flow_kg_per_s::Vector{Float64}
    pipe_inlet_temp_K::Vector{Float64}
    pipe_outlet_temp_K::Vector{Float64}
    pipe_heat_loss_W::Vector{Float64}
    pipe_pressure_drop_Pa::Vector{Float64}
    pump_boost_Pa::Vector{Float64}
    load_flow_kg_per_s::Vector{Float64}
    load_inlet_temp_K::Vector{Float64}
    load_outlet_temp_K::Vector{Float64}
    load_demand_W::Vector{Float64}
    load_delivered_W::Vector{Float64}
    load_shed_W::Vector{Float64}
    load_excess_W::Vector{Float64}
    plant_output_W::Float64
    plant_flow_kg_per_s::Float64
    plant_inlet_temp_K::Float64
    plant_outlet_temp_K::Float64
end

"""
    set_demand!(model::SteamModel, heat_W)

Update the load heat demand in place, in W per load, without rebuilding the model.
"""
function set_demand!(model::SteamModel, heat_W)
    length(heat_W) == model.data.nload || throw(ArgumentError("heat_W must have one entry per load"))
    values = Float64.(collect(heat_W)) ./ model.data.options.power_ref_W
    copyto!(model.data.demand, values)
    ExaModels.set_value!(model.nlp, model.demand, values)
    return model
end

"""
    solve_steam(model::SteamModel; print_level = MadNLP.ERROR, kwargs...) -> SteamSolution
    solve_steam(net; heat_W, plant_rating_W, options, backend, solver options...) -> SteamSolution

Solve with MadNLP. Keyword arguments other than the model-building ones go to `madnlp`.
"""
function solve_steam(model::SteamModel; print_level = MadNLP.ERROR, kwargs...)
    result = MadNLP.madnlp(model.nlp; print_level, kwargs...)
    return extract_solution(model, result)
end

function solve_steam(
        net;
        heat_W = nothing,
        plant_rating_W = nothing,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
        kwargs...,
    )
    model = build_steam_model(net; heat_W, plant_rating_W, options, backend)
    return solve_steam(model; kwargs...)
end

"""
    extract_solution(model::SteamModel, result) -> SteamSolution

Convert a MadNLP result for `model.nlp` into SI units. Arrays are copied to the host.
"""
function extract_solution(model::SteamModel, result)
    data, opt = model.data, model.data.options
    pref, tref, fref, qref = opt.pressure_ref_Pa, opt.temperature_ref_K,
        opt.flow_ref_kg_per_s, opt.power_ref_W
    value(v) = Array(ExaModels.solution(result, v))

    pressure = value(model.vars.pressure) .* pref
    temperature = value(model.vars.temperature) .* tref
    flow = value(model.vars.flow) .* fref
    temp_in = value(model.vars.temp_in) .* tref
    temp_out = value(model.vars.temp_out) .* tref
    boost = value(model.vars.boost) .* pref
    # MadNLP relaxes bounds by a small factor, so slacks can end slightly below zero.
    shed = max.(value(model.vars.shed) .* qref, 0.0)
    excess = max.(value(model.vars.excess) .* qref, 0.0)

    np, nl, ne = data.npipe, data.nload, data.nedge
    pipes, loads = 1:np, np .+ (1:nl)
    cs, cw, cl = opt.cp_steam_J_per_kgK, opt.cp_water_J_per_kgK, opt.latent_heat_J_per_kg
    tsat = opt.saturation_temp_K

    heat_loss = [
        flow[e] * (data.pipe_is_steam[e] ? cs : cw) * (temp_in[e] - temp_out[e]) for e in pipes
    ]
    drop = [pressure[data.pipe_from[e]] - pressure[data.pipe_to[e]] for e in pipes]
    pump_boost = zeros(np)
    pump_boost[data.pump_pipe] .= boost
    delivered = [
        flow[e] * (cs * (temp_in[e] - tsat) + cl + cw * (tsat - temp_out[e])) for e in loads
    ]
    plant_output = flow[ne] * (cw * (tsat - temp_in[ne]) + cl + cs * (temp_out[ne] - tsat))

    # Recomputed from the clamped SI values, so relaxed slack bounds do not leak into the result.
    weights = data.objective_loads
    objective = sum(weights[l].shed * shed[l] + weights[l].excess * excess[l] for l in 1:nl; init = 0.0) +
        opt.pressure_weight * (pressure[data.plant_steam] + pressure[data.plant_water]) +
        opt.flow_weight * flow[ne] + opt.temperature_weight * temp_out[ne] +
        opt.plant_power_weight * plant_output

    counters = result.counters
    return SteamSolution(
        Symbol(result.status),
        result.status in (MadNLP.SOLVE_SUCCEEDED, MadNLP.SOLVED_TO_ACCEPTABLE_LEVEL),
        objective,
        result.iter,
        counters.total_time,
        result.primal_feas,
        result.dual_feas,
        pressure,
        temperature,
        flow[pipes],
        temp_in[pipes],
        temp_out[pipes],
        heat_loss,
        drop,
        pump_boost,
        flow[loads],
        temp_in[loads],
        temp_out[loads],
        data.demand .* qref,
        delivered,
        shed,
        excess,
        plant_output,
        flow[ne],
        temp_in[ne],
        temp_out[ne],
    )
end

"""
    physical_residuals(model::SteamModel, sol::SteamSolution) -> NamedTuple

Recompute every constraint family from the SI solution, independently of the ExaModels
expressions. Fields hold one vector per family: `mass_kg_per_s`, `energy_W`, `mixing_K`,
`decay_K`, `steam_pressure_Pa2`, `water_pressure_Pa`, `load_heat_W`, `load_pressure_Pa` (violation
of steam pressure at or above water pressure) and `plant_cap_W` (violation of the rating).
"""
physical_residuals(model::SteamModel, sol::SteamSolution) =
    _physical_residuals(model.data, sol, model.data.plant_rating_W)

function _physical_residuals(data::SteamData, sol::SteamSolution, rating_W)
    opt = data.options
    np, nl, nj = data.npipe, data.nload, data.njunction
    cs, cw, cl = opt.cp_steam_J_per_kgK, opt.cp_water_J_per_kgK, opt.latent_heat_J_per_kg
    tsat, tamb = opt.saturation_temp_K, opt.ambient_temp_K
    p, t = sol.junction_pressure_Pa, sol.junction_temperature_K
    cp_pipe(e) = data.pipe_is_steam[e] ? cs : cw

    mass = zeros(nj)
    energy = zeros(nj)
    function connect!(from, to, f, c_from, c_to, t_from, t_to)
        mass[from] -= f
        mass[to] += f
        energy[from] -= f * c_from * t_from
        energy[to] += f * c_to * t_to
        return nothing
    end
    for e in 1:np
        c = cp_pipe(e)
        connect!(
            data.pipe_from[e], data.pipe_to[e], sol.pipe_flow_kg_per_s[e], c, c,
            sol.pipe_inlet_temp_K[e], sol.pipe_outlet_temp_K[e],
        )
    end
    for l in 1:nl
        connect!(
            data.load_steam[l], data.load_water[l], sol.load_flow_kg_per_s[l], cs, cw,
            sol.load_inlet_temp_K[l], sol.load_outlet_temp_K[l],
        )
    end
    connect!(
        data.plant_water, data.plant_steam, sol.plant_flow_kg_per_s, cw, cs,
        sol.plant_inlet_temp_K, sol.plant_outlet_temp_K,
    )

    mixing = vcat(
        [sol.pipe_inlet_temp_K[e] - t[data.pipe_from[e]] for e in 1:np],
        [sol.load_inlet_temp_K[l] - t[data.load_steam[l]] for l in 1:nl],
        sol.plant_inlet_temp_K - t[data.plant_water],
    )

    decay = map(1:np) do e
        x = data.pipe_length_m[e] * data.pipe_gamma_W_per_mK[e] / (cp_pipe(e) * sol.pipe_flow_kg_per_s[e])
        sol.pipe_outlet_temp_K[e] - tamb - (sol.pipe_inlet_temp_K[e] - tamb) * exp(-x)
    end

    area(e) = pi * data.pipe_diameter_m[e]^2 / 4
    steam_ids = [e for e in 1:np if data.pipe_is_steam[e]]
    water_ids = [e for e in 1:np if !data.pipe_is_steam[e]]
    steam_pressure = map(steam_ids) do e
        f = sol.pipe_flow_kg_per_s[e]
        integral = tamb * data.pipe_length_m[e] +
            cs * f / data.pipe_gamma_W_per_mK[e] * (sol.pipe_inlet_temp_K[e] - sol.pipe_outlet_temp_K[e])
        p[data.pipe_to[e]]^2 - p[data.pipe_from[e]]^2 +
            data.pipe_friction[e] * opt.gas_constant_J_per_kgK / (area(e)^2 * data.pipe_diameter_m[e]) * f^2 * integral
    end
    water_pressure = map(water_ids) do e
        f = sol.pipe_flow_kg_per_s[e]
        p[data.pipe_from[e]] + sol.pump_boost_Pa[e] - p[data.pipe_to[e]] -
            data.pipe_friction[e] * data.pipe_length_m[e] * f^2 /
            (2 * area(e)^2 * data.pipe_diameter_m[e] * opt.water_density_kg_per_m3)
    end

    load_heat = map(1:nl) do l
        f = sol.load_flow_kg_per_s[l]
        f * (cs * (sol.load_inlet_temp_K[l] - tsat) + cl + cw * (tsat - sol.load_outlet_temp_K[l])) -
            (sol.load_demand_W[l] + sol.load_excess_W[l] - sol.load_shed_W[l])
    end
    load_pressure = [max(0.0, p[data.load_water[l]] - p[data.load_steam[l]]) for l in 1:nl]

    return (
        mass_kg_per_s = mass,
        energy_W = energy,
        mixing_K = mixing,
        decay_K = decay,
        steam_pressure_Pa2 = steam_pressure,
        water_pressure_Pa = water_pressure,
        load_heat_W = load_heat,
        load_pressure_Pa = load_pressure,
        plant_cap_W = [max(0.0, sol.plant_output_W - rating_W)],
    )
end

"""
    energy_audit(sol::SteamSolution) -> NamedTuple

Network heat balance in W: `plant_output_W`, `delivered_W`, `pipe_loss_W`, `shed_W`, `excess_W`,
and `closure_W = plant_output_W - delivered_W - pipe_loss_W`, which is zero at a feasible point.
"""
function energy_audit(sol::SteamSolution)
    delivered = sum(sol.load_delivered_W; init = 0.0)
    loss = sum(sol.pipe_heat_loss_W; init = 0.0)
    return (
        plant_output_W = sol.plant_output_W,
        delivered_W = delivered,
        pipe_loss_W = loss,
        shed_W = sum(sol.load_shed_W; init = 0.0),
        excess_W = sum(sol.load_excess_W; init = 0.0),
        closure_W = sol.plant_output_W - delivered - loss,
    )
end

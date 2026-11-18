# Multi-period model: T hourly steady states in one NLP, coupled by plant ramp limits.
#
# Every period is compiled by `compile_steam_data` and the per-period arrays are concatenated, with
# each index shifted by the offset of its period. The result is again a `SteamData`, so
# `add_steam_variables`, `add_steam_constraints` and `add_steam_objective` build the whole horizon
# with one generator per constraint family. The period index is carried by the flat indices rather
# than by a second array dimension, because the number of pipes can differ between periods when a
# pipe is out of service for part of the horizon. See docs/model-notes.md.

"""
    PeriodTemplate

One compiled network orientation shared by all periods that use it: the oriented network `net`, its
`SteamData`, and for each of its pipes the id in the input network (`source_pipe`) and the direction
relative to the input network (`direction`, `+1` or `-1`).
"""
struct PeriodTemplate{D <: SteamData}
    net::CampusNetwork
    data::D
    source_pipe::Vector{Int}
    direction::Vector{Int}
end

"""
    MultiPeriodData

Compiled multi-period inputs. `stacked` is the flat `SteamData` that drives the generators.
`templates[template_of[k]]` describes period `k`, and `edge_offset[k]` and `pump_offset[k]` locate
that period in the flat edge and pump variables. Junction and load variables have a fixed block
size, so period `k` starts at `(k - 1) * njunction` and `(k - 1) * nload`.

`heat_W` and `priority_weight` are indexed `(period, load)`. `ramp_up_W_per_h` and
`ramp_down_W_per_h` have one entry per transition `k -> k + 1`.
"""
struct MultiPeriodData{D <: SteamData, S <: SteamData, R}
    net::CampusNetwork
    nperiod::Int
    options::SteamModelOptions
    templates::Vector{PeriodTemplate{D}}
    template_of::Vector{Int}
    edge_offset::Vector{Int}
    pump_offset::Vector{Int}
    heat_W::Matrix{Float64}
    plant_rating_W::Vector{Float64}
    priority_weight::Matrix{Float64}
    ramp_up_W_per_h::Vector{Float64}
    ramp_down_W_per_h::Vector{Float64}
    ramps::R
    out_of_service::Vector{Vector{Int}}
    stacked::S
end

"""
    MultiPeriodModel

A built multi-period model: the `ExaModel` in `nlp`, the compiled `data`, the flat variable handles
`vars`, the constraint handles `cons` (including `ramp`, or `nothing` without a finite ramp limit)
and the demand parameter `demand`.
"""
struct MultiPeriodModel{N, D <: MultiPeriodData, V, C, P}
    nlp::N
    data::D
    vars::V
    cons::C
    demand::P
end

"""
    MultiPeriodSolution

Result of [`solve_multiperiod`](@ref) in SI units. All matrices are indexed `(period, id)`, where
pipe ids refer to the input network whatever the orientation of a period.

Solver: `status`, `converged`, `objective_Wh` (sum of the single-period objectives over one-hour
periods), `iterations`, `solve_time_s`, `primal_infeasibility`, `dual_infeasibility`, `nperiod`.

Junctions: `junction_pressure_Pa`, `junction_temperature_K`.

Pipes: `pipe_in_service`, `pipe_flow_kg_per_s` (signed: negative against the direction of the input
network), `pipe_inlet_temp_K` and `pipe_outlet_temp_K` (at the upstream and downstream end of the
flow in that period), `pipe_heat_loss_W`, `pump_boost_Pa`. Every pipe quantity is zero in a period
where `pipe_in_service` is false.

Loads: `load_flow_kg_per_s`, `load_inlet_temp_K`, `load_outlet_temp_K`, `load_demand_W`,
`load_delivered_W`, `load_shed_W`, `load_excess_W`.

Plant, one vector entry per period: `plant_output_W`, `plant_flow_kg_per_s`, `plant_inlet_temp_K`,
`plant_outlet_temp_K`, `plant_rating_W`. `ramp_up_W_per_h` and `ramp_down_W_per_h` hold the limit of
each transition `k -> k + 1`.
"""
struct MultiPeriodSolution
    status::Symbol
    converged::Bool
    objective_Wh::Float64
    iterations::Int
    solve_time_s::Float64
    primal_infeasibility::Float64
    dual_infeasibility::Float64
    nperiod::Int
    junction_pressure_Pa::Matrix{Float64}
    junction_temperature_K::Matrix{Float64}
    pipe_in_service::Matrix{Bool}
    pipe_flow_kg_per_s::Matrix{Float64}
    pipe_inlet_temp_K::Matrix{Float64}
    pipe_outlet_temp_K::Matrix{Float64}
    pipe_heat_loss_W::Matrix{Float64}
    pump_boost_Pa::Matrix{Float64}
    load_flow_kg_per_s::Matrix{Float64}
    load_inlet_temp_K::Matrix{Float64}
    load_outlet_temp_K::Matrix{Float64}
    load_demand_W::Matrix{Float64}
    load_delivered_W::Matrix{Float64}
    load_shed_W::Matrix{Float64}
    load_excess_W::Matrix{Float64}
    plant_output_W::Vector{Float64}
    plant_flow_kg_per_s::Vector{Float64}
    plant_inlet_temp_K::Vector{Float64}
    plant_outlet_temp_K::Vector{Float64}
    plant_rating_W::Vector{Float64}
    ramp_up_W_per_h::Vector{Float64}
    ramp_down_W_per_h::Vector{Float64}
end

# Inputs ------------------------------------------------------------------------------------------

function _period_vector(value, default, T, name)
    value === nothing && return fill(Float64(default), T)
    value isa Number && return fill(Float64(value), T)
    length(value) == T || throw(ArgumentError("$name must be a number or have $T entries"))
    return Float64.(collect(value))
end

function _priority_matrix(priority_weight, net, T)
    nl = length(net.loads)
    priority_weight === nothing &&
        return repeat(Float64[l.priority_weight for l in net.loads]', T, 1)
    if priority_weight isa AbstractMatrix
        size(priority_weight) == (T, nl) ||
            throw(ArgumentError("priority_weight must have size (periods, loads)"))
        return Matrix{Float64}(priority_weight)
    end
    length(priority_weight) == nl ||
        throw(ArgumentError("priority_weight must have one entry per load, or size (periods, loads)"))
    return repeat(Float64.(collect(priority_weight))', T, 1)
end

# Accepts pipe ids (out for the whole horizon), `pipe => periods` pairs, or one id list per period.
function _outage_schedule(out_of_service, T, npipe)
    schedule = [Int[] for _ in 1:T]
    if out_of_service === nothing || isempty(out_of_service)
        return schedule
    elseif eltype(out_of_service) <: Integer
        schedule = [sort!(unique(Int.(out_of_service))) for _ in 1:T]
    elseif eltype(out_of_service) <: Pair
        for (pipe, periods) in out_of_service, k in periods
            1 <= k <= T || throw(ArgumentError("outage period $k is outside 1:$T"))
            push!(schedule[k], pipe)
        end
        schedule = [sort!(unique(s)) for s in schedule]
    else
        length(out_of_service) == T ||
            throw(ArgumentError("out_of_service must list the pipes of each of the $T periods"))
        schedule = [sort!(unique(Int.(s))) for s in out_of_service]
    end
    for s in schedule, pipe in s
        1 <= pipe <= npipe || throw(ArgumentError("unknown pipe id $pipe in out_of_service"))
    end
    return schedule
end

function _heat_matrix(heat_W, net)
    heat_W isa AbstractMatrix ||
        throw(ArgumentError("heat_W must be a matrix indexed (period, load)"))
    size(heat_W, 2) == length(net.loads) ||
        throw(ArgumentError("heat_W must have one column per load"))
    size(heat_W, 1) >= 1 || throw(ArgumentError("heat_W must have at least one period"))
    all(>=(0), heat_W) || throw(ArgumentError("heat_W must be non-negative"))
    return Matrix{Float64}(heat_W)
end

# Orientation -------------------------------------------------------------------------------------

"""
    orient_periods(net; heat_W, out_of_service = Int[], plant_rating_W = nothing, method = :search,
                   options = SteamModelOptions(), backend = nothing, solver options...)
        -> Vector{CampusNetwork}

Choose the pipe directions of each period. Periods with no pipe out of service use `net` unchanged.
For each outage period, `method` selects:

- `:search`: the direction pattern of [`solve_oriented`](@ref) for that hour. It solves single-period
  NLPs, so it costs a few solves per outage hour.
- `:demand`: the hydraulic flow direction at that hour's demand ([`orient_for_demand`](@ref)), with
  no NLP solve.
- `:design`: the design-load direction (`orient_network`), with no NLP solve.

`out_of_service` takes pipe ids (out for the whole horizon), `pipe => periods` pairs, or one list of
pipe ids per period. Ids refer to `net`.
"""
function orient_periods(
        net::CampusNetwork;
        heat_W,
        out_of_service = Int[],
        plant_rating_W = nothing,
        method::Symbol = :search,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
        kwargs...,
    )
    method in (:search, :demand, :design) ||
        throw(ArgumentError("method must be :search, :demand or :design"))
    heat = _heat_matrix(heat_W, net)
    T = size(heat, 1)
    schedule = _outage_schedule(out_of_service, T, length(net.pipes))
    rating = _period_vector(plant_rating_W, net.plant.rating_W, T, "plant_rating_W")
    return map(1:T) do k
        isempty(schedule[k]) && return net
        method === :design && return orient_network(net; out_of_service = schedule[k])
        method === :demand &&
            return orient_for_demand(net; heat_W = heat[k, :], out_of_service = schedule[k])
        return solve_oriented(
            net; heat_W = heat[k, :], out_of_service = schedule[k], plant_rating_W = rating[k],
            options, backend, kwargs...,
        ).net
    end
end

# Compilation -------------------------------------------------------------------------------------

function _period_template(net, oriented, rating_W, options)
    data = compile_steam_data(oriented; plant_rating_W = rating_W, options)
    oriented === net && return PeriodTemplate(oriented, data, collect(1:length(net.pipes)), ones(Int, length(net.pipes)))
    source_pipe, direction = _match_source_pipes(net, oriented)
    return PeriodTemplate(oriented, data, source_pipe, direction)
end

# Concatenates one generator array over the periods, shifting each entry by its period's offsets.
function _stack(shift::F, items, template_of) where {F}
    n = sum(k -> length(items[template_of[k]]), eachindex(template_of); init = 0)
    out = Vector{Base.promote_op(shift, eltype(eltype(items)), Int)}(undef, n)
    i = 0
    for k in eachindex(template_of), t in items[template_of[k]]
        out[i += 1] = shift(t, k)
    end
    return out
end

# Concatenates one per-period block of numbers, such as a bound or start vector.
function _blocks(block::F, T) where {F}
    n = sum(k -> length(block(k)), 1:T; init = 0)
    out = Vector{Float64}(undef, n)
    i = 0
    for k in 1:T
        b = block(k)
        copyto!(out, i + 1, b, 1, length(b))
        i += length(b)
    end
    return out
end

function _period_start(template::PeriodTemplate, heat_W, rating_W)
    d, opt = template.data, template.data.options
    bounds = merge(d.bounds, (; plant_power = (0.0, rating_W / opt.power_ref_W)))
    flow_min = d.bounds.flow[1][1:d.npipe] .* opt.flow_ref_kg_per_s
    steam_tmax = max(opt.steam_temp_max_K, template.net.plant.supply_temp_K)
    return _starting_point(
        template.net, opt, heat_W, flow_min, d.pipe_gamma_W_per_mK, d.pipe_is_steam,
        d.junction_is_steam, steam_tmax, bounds,
    )
end

"""
    compile_multiperiod_data(net; heat_W, plant_rating_W = nothing, priority_weight = nothing,
                             ramp_limit_W_per_h = net.plant.ramp_limit_W_per_h,
                             out_of_service = Int[], networks = nothing,
                             options = SteamModelOptions()) -> MultiPeriodData

Compile the inputs of a multi-period model. See [`build_multiperiod_model`](@ref).
"""
function compile_multiperiod_data(
        net::CampusNetwork;
        heat_W,
        plant_rating_W = nothing,
        priority_weight = nothing,
        ramp_limit_W_per_h = net.plant.ramp_limit_W_per_h,
        out_of_service = Int[],
        networks = nothing,
        options::SteamModelOptions = SteamModelOptions(),
    )
    opt = options
    heat = _heat_matrix(heat_W, net)
    T, nl = size(heat)
    rating = _period_vector(plant_rating_W, net.plant.rating_W, T, "plant_rating_W")
    all(>=(0), rating) || throw(ArgumentError("plant_rating_W must be non-negative"))
    priority = _priority_matrix(priority_weight, net, T)
    all(>=(0), priority) || throw(ArgumentError("priority_weight must be non-negative"))
    schedule = _outage_schedule(out_of_service, T, length(net.pipes))

    ramp_up = ramp_limit_W_per_h isa Number ? fill(Float64(ramp_limit_W_per_h), T - 1) :
        Float64.(collect(ramp_limit_W_per_h))
    length(ramp_up) == T - 1 ||
        throw(ArgumentError("ramp_limit_W_per_h must be a number or have $(T - 1) entries"))
    all(>=(0), ramp_up) || throw(ArgumentError("ramp_limit_W_per_h must be non-negative"))
    # A forced derate takes effect at once: the output may fall by the size of the rating drop even
    # when that exceeds the ramp limit, so the plant does not shed load ahead of the outage.
    ramp_down = [max(ramp_up[k], rating[k] - rating[k + 1]) for k in 1:(T - 1)]

    oriented = networks === nothing ?
        orient_periods(net; heat_W = heat, out_of_service = schedule, method = :demand, options) :
        collect(networks)
    length(oriented) == T || throw(ArgumentError("networks must have one network per period"))

    # Periods with the same pipes share one compiled template.
    index = Dict{Vector{Pipe}, Int}()
    template_of = Vector{Int}(undef, T)
    first_net = CampusNetwork[]
    for k in 1:T
        template_of[k] = get!(index, oriented[k].pipes) do
            push!(first_net, oriented[k])
            length(first_net)
        end
    end
    rating_ref = maximum(rating)
    templates = [_period_template(net, candidate, rating_ref, opt) for candidate in first_net]
    datas = [t.data for t in templates]

    nj, nmass = datas[1].njunction, datas[1].nmass
    edge_offset = zeros(Int, T)
    pump_offset = zeros(Int, T)
    water_offset = zeros(Int, T)
    for k in 2:T
        d = datas[template_of[k - 1]]
        edge_offset[k] = edge_offset[k - 1] + d.nedge
        pump_offset[k] = pump_offset[k - 1] + d.npump
        water_offset[k] = water_offset[k - 1] + length(d.water_pipes)
    end
    jo(k) = (k - 1) * nj
    lo(k) = (k - 1) * nl
    eo(k) = edge_offset[k]

    mass_terms = _stack((t, k) -> (row = t.row + (k - 1) * nmass, edge = t.edge + eo(k), sign = t.sign), [d.mass_terms for d in datas], template_of)
    energy_in = _stack((t, k) -> (row = t.row + jo(k), edge = t.edge + eo(k)), [d.energy_in for d in datas], template_of)
    energy_out = _stack((t, k) -> (row = t.row + jo(k), edge = t.edge + eo(k)), [d.energy_out for d in datas], template_of)
    mixing = _stack((t, k) -> (edge = t.edge + eo(k), node = t.node + jo(k)), [d.mixing for d in datas], template_of)
    decay = _stack((t, k) -> merge(t, (; edge = t.edge + eo(k))), [d.decay for d in datas], template_of)
    steam_pipes = _stack(
        (t, k) -> merge(t, (; edge = t.edge + eo(k), from = t.from + jo(k), to = t.to + jo(k))),
        [d.steam_pipes for d in datas], template_of,
    )
    water_pipes = _stack(
        (t, k) -> merge(t, (; edge = t.edge + eo(k), from = t.from + jo(k), to = t.to + jo(k))),
        [d.water_pipes for d in datas], template_of,
    )
    pumps = _stack((t, k) -> (row = t.row + water_offset[k], pump = t.pump + pump_offset[k]), [d.pumps for d in datas], template_of)
    loads = _stack(
        (t, k) -> merge(t, (; load = t.load + lo(k), edge = t.edge + eo(k))),
        [d.loads for d in datas], template_of,
    )
    load_pressure = _stack((t, k) -> (steam = t.steam + jo(k), water = t.water + jo(k)), [d.load_pressure for d in datas], template_of)
    plant = _stack(
        (t, k) -> merge(t, (; edge = t.edge + eo(k), power = k)),
        [d.plant for d in datas], template_of,
    )
    objective_loads = _stack(
        (t, k) -> merge(t, (; load = t.load + lo(k), shed = opt.shed_weight * priority[k, t.load])),
        [d.objective_loads for d in datas], template_of,
    )
    plant_objective = _stack(
        (t, k) -> (steam = t.steam + jo(k), water = t.water + jo(k), edge = t.edge + eo(k), power = k),
        [d.plant_objective for d in datas], template_of,
    )

    bound(pick) = (
        _blocks(k -> pick(datas[template_of[k]].bounds)[1], T),
        _blocks(k -> pick(datas[template_of[k]].bounds)[2], T),
    )
    bounds = (
        pressure = bound(b -> b.pressure),
        temperature = bound(b -> b.temperature),
        flow = bound(b -> b.flow),
        temp_in = bound(b -> b.temp_in),
        temp_out = bound(b -> b.temp_out),
        boost = bound(b -> b.boost),
        plant_power = (zeros(T), rating ./ opt.power_ref_W),
    )

    starts = [_period_start(templates[template_of[k]], heat[k, :], rating[k]) for k in 1:T]
    start = (
        pressure = _blocks(k -> starts[k].pressure, T),
        temperature = _blocks(k -> starts[k].temperature, T),
        flow = _blocks(k -> starts[k].flow, T),
        temp_in = _blocks(k -> starts[k].temp_in, T),
        temp_out = _blocks(k -> starts[k].temp_out, T),
        boost = _blocks(k -> starts[k].boost, T),
        plant_power = [starts[k].plant_power for k in 1:T],
    )

    d1 = datas[1]
    nedge = sum(k -> datas[template_of[k]].nedge, 1:T)
    npipe = sum(k -> datas[template_of[k]].npipe, 1:T)
    npump = sum(k -> datas[template_of[k]].npump, 1:T)
    # Only the fields the generators read are stacked; per-network details stay in the templates.
    stacked = SteamData(
        opt, T * nj, npipe, T * nl, nedge, T * nmass, npump,
        Bool[], Int[], Int[], Int[], Float64[], Float64[], Float64[], Float64[], Int[], Int[],
        d1.plant_steam, d1.plant_water, rating_ref, Bool[], Int[],
        vec(permutedims(heat)) ./ opt.power_ref_W,
        mass_terms, energy_in, energy_out, mixing, decay, steam_pipes, water_pipes, pumps, loads,
        load_pressure, plant, objective_loads, plant_objective, bounds, start,
    )

    ramps = [
        (prev = k, next = k + 1, up = ramp_up[k] / opt.power_ref_W, down = ramp_down[k] / opt.power_ref_W)
        for k in 1:(T - 1) if isfinite(ramp_up[k])
    ]
    return MultiPeriodData(
        net, T, opt, templates, template_of, edge_offset, pump_offset, heat, rating, priority,
        ramp_up, ramp_down, ramps, schedule, stacked,
    )
end

# Model -------------------------------------------------------------------------------------------

"""
    build_multiperiod_model(net; heat_W, plant_rating_W = nothing, priority_weight = nothing,
                            ramp_limit_W_per_h = net.plant.ramp_limit_W_per_h,
                            out_of_service = Int[], networks = nothing,
                            options = SteamModelOptions(), backend = nothing) -> MultiPeriodModel

Build one NLP over `size(heat_W, 1)` hourly steady states.

- `heat_W`: demand in W, indexed `(period, load)`.
- `plant_rating_W`: a number or one value per period.
- `priority_weight`: one value per load, or a matrix indexed `(period, load)`.
- `ramp_limit_W_per_h`: a number or one value per transition; `Inf` removes the limit.
- `out_of_service`: see [`orient_periods`](@ref). Outage periods are oriented with `:demand` unless
  `networks` gives one oriented network per period, as returned by `orient_periods`.
- `backend`: a KernelAbstractions backend such as `CUDABackend()`, or `nothing` for the CPU.

The physics of each hour is the steady-state model, with no pipe transients and no valves. The
periods are coupled only through the plant ramp limit.
"""
function build_multiperiod_model(
        net::CampusNetwork;
        heat_W,
        plant_rating_W = nothing,
        priority_weight = nothing,
        ramp_limit_W_per_h = net.plant.ramp_limit_W_per_h,
        out_of_service = Int[],
        networks = nothing,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
    )
    data = compile_multiperiod_data(
        net; heat_W, plant_rating_W, priority_weight, ramp_limit_W_per_h, out_of_service, networks,
        options,
    )
    stacked = data.stacked
    core = ExaCore(Float64; backend)
    core, demand = add_par(core, stacked.demand)
    core, vars = add_steam_variables(core, stacked)
    core, cons = add_steam_constraints(core, stacked, vars, demand)
    ramp = nothing
    if !isempty(data.ramps)
        plant_power = vars.plant_power
        core, ramp = add_con(
            core,
            plant_power[t.next] - plant_power[t.prev] for t in data.ramps;
            lcon = [-t.down for t in data.ramps],
            ucon = [t.up for t in data.ramps],
        )
    end
    core = add_steam_objective(core, stacked, vars)
    return MultiPeriodModel(ExaModel(core), data, vars, (; cons..., ramp), demand)
end

# Solution ----------------------------------------------------------------------------------------

"""
    solve_multiperiod(model::MultiPeriodModel; print_level = MadNLP.ERROR, kwargs...)
    solve_multiperiod(net; heat_W, model-building keywords..., solver options...)

Solve with MadNLP and return a [`MultiPeriodSolution`](@ref). Keyword arguments other than the
model-building ones go to `madnlp`.
"""
function solve_multiperiod(model::MultiPeriodModel; print_level = MadNLP.ERROR, kwargs...)
    result = MadNLP.madnlp(model.nlp; print_level, kwargs...)
    return extract_multiperiod_solution(model, result)
end

function solve_multiperiod(
        net::CampusNetwork;
        heat_W,
        plant_rating_W = nothing,
        priority_weight = nothing,
        ramp_limit_W_per_h = net.plant.ramp_limit_W_per_h,
        out_of_service = Int[],
        networks = nothing,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
        kwargs...,
    )
    model = build_multiperiod_model(
        net; heat_W, plant_rating_W, priority_weight, ramp_limit_W_per_h, out_of_service, networks,
        options, backend,
    )
    return solve_multiperiod(model; kwargs...)
end

"""
    extract_multiperiod_solution(model::MultiPeriodModel, result) -> MultiPeriodSolution

Convert a MadNLP result for `model.nlp` into SI units. Arrays are copied to the host.
"""
function extract_multiperiod_solution(model::MultiPeriodModel, result)
    data, opt = model.data, model.data.options
    T = data.nperiod
    pref, tref, fref, qref = opt.pressure_ref_Pa, opt.temperature_ref_K,
        opt.flow_ref_kg_per_s, opt.power_ref_W
    cs, cw, cl = opt.cp_steam_J_per_kgK, opt.cp_water_J_per_kgK, opt.latent_heat_J_per_kg
    tsat = opt.saturation_temp_K
    value(v) = Array(ExaModels.solution(result, v))

    nj, nl, np = length(data.net.junctions), length(data.net.loads), length(data.net.pipes)
    pressure = permutedims(reshape(value(model.vars.pressure) .* pref, nj, T))
    temperature = permutedims(reshape(value(model.vars.temperature) .* tref, nj, T))
    # MadNLP relaxes bounds by a small factor, so slacks can end slightly below zero.
    shed = permutedims(reshape(max.(value(model.vars.shed) .* qref, 0.0), nl, T))
    excess = permutedims(reshape(max.(value(model.vars.excess) .* qref, 0.0), nl, T))
    flow = value(model.vars.flow) .* fref
    temp_in = value(model.vars.temp_in) .* tref
    temp_out = value(model.vars.temp_out) .* tref
    boost = value(model.vars.boost) .* pref

    in_service = falses(T, np)
    pipe_flow, pipe_in, pipe_out, pipe_loss, pump = (zeros(T, np) for _ in 1:5)
    load_flow, load_in, load_out, delivered = (zeros(T, nl) for _ in 1:4)
    plant_output, plant_flow, plant_in, plant_out = (zeros(T) for _ in 1:4)

    objective = 0.0
    for k in 1:T
        template = data.templates[data.template_of[k]]
        d, eo = template.data, data.edge_offset[k]
        for e in 1:d.npipe
            s, f = template.source_pipe[e], flow[eo + e]
            in_service[k, s] = true
            pipe_flow[k, s] = template.direction[e] * f
            pipe_in[k, s] = temp_in[eo + e]
            pipe_out[k, s] = temp_out[eo + e]
            pipe_loss[k, s] = f * (d.pipe_is_steam[e] ? cs : cw) * (temp_in[eo + e] - temp_out[eo + e])
        end
        for (i, e) in enumerate(d.pump_pipe)
            pump[k, template.source_pipe[e]] = boost[data.pump_offset[k] + i]
        end
        for l in 1:nl
            e = eo + d.npipe + l
            load_flow[k, l], load_in[k, l], load_out[k, l] = flow[e], temp_in[e], temp_out[e]
            delivered[k, l] = flow[e] * (cs * (temp_in[e] - tsat) + cl + cw * (tsat - temp_out[e]))
            objective += opt.shed_weight * data.priority_weight[k, l] * shed[k, l] +
                opt.excess_weight * excess[k, l]
        end
        e = eo + d.nedge
        plant_flow[k], plant_in[k], plant_out[k] = flow[e], temp_in[e], temp_out[e]
        plant_output[k] = flow[e] * (cw * (tsat - temp_in[e]) + cl + cs * (temp_out[e] - tsat))
        objective += opt.pressure_weight * (pressure[k, d.plant_steam] + pressure[k, d.plant_water]) +
            opt.flow_weight * flow[e] + opt.temperature_weight * temp_out[e] +
            opt.plant_power_weight * plant_output[k]
    end

    return MultiPeriodSolution(
        Symbol(result.status),
        result.status in (MadNLP.SOLVE_SUCCEEDED, MadNLP.SOLVED_TO_ACCEPTABLE_LEVEL),
        objective, result.iter, result.counters.total_time, result.primal_feas, result.dual_feas, T,
        pressure, temperature, Matrix{Bool}(in_service), pipe_flow, pipe_in, pipe_out, pipe_loss, pump,
        load_flow, load_in, load_out, copy(data.heat_W), delivered, shed, excess,
        plant_output, plant_flow, plant_in, plant_out, copy(data.plant_rating_W),
        copy(data.ramp_up_W_per_h), copy(data.ramp_down_W_per_h),
    )
end

"""
    period_solution(model::MultiPeriodModel, sol::MultiPeriodSolution, k) -> SteamSolution

The state of period `k` as a [`SteamSolution`](@ref). Pipe arrays follow the oriented network of
that period, `model.data.templates[model.data.template_of[k]].net`, so flows are non-negative.
"""
function period_solution(model::MultiPeriodModel, sol::MultiPeriodSolution, k::Integer)
    template = model.data.templates[model.data.template_of[k]]
    d, s = template.data, template.source_pipe
    p = sol.junction_pressure_Pa[k, :]
    drop = [p[d.pipe_from[e]] - p[d.pipe_to[e]] for e in 1:d.npipe]
    return SteamSolution(
        sol.status, sol.converged, NaN, sol.iterations, sol.solve_time_s, sol.primal_infeasibility,
        sol.dual_infeasibility, p, sol.junction_temperature_K[k, :],
        template.direction .* sol.pipe_flow_kg_per_s[k, s], sol.pipe_inlet_temp_K[k, s],
        sol.pipe_outlet_temp_K[k, s], sol.pipe_heat_loss_W[k, s], drop, sol.pump_boost_Pa[k, s],
        sol.load_flow_kg_per_s[k, :], sol.load_inlet_temp_K[k, :], sol.load_outlet_temp_K[k, :],
        sol.load_demand_W[k, :], sol.load_delivered_W[k, :], sol.load_shed_W[k, :],
        sol.load_excess_W[k, :], sol.plant_output_W[k], sol.plant_flow_kg_per_s[k],
        sol.plant_inlet_temp_K[k], sol.plant_outlet_temp_K[k],
    )
end

"""
    physical_residuals(model::MultiPeriodModel, sol::MultiPeriodSolution, k) -> NamedTuple

Residuals of period `k`, recomputed from the SI solution as for a single period.
"""
physical_residuals(model::MultiPeriodModel, sol::MultiPeriodSolution, k::Integer) = _physical_residuals(
    model.data.templates[model.data.template_of[k]].data, period_solution(model, sol, k),
    sol.plant_rating_W[k],
)

"""
    energy_audit(sol::MultiPeriodSolution) -> NamedTuple

Network heat balance of each period in W, with the same fields as the single-period audit, each a
vector with one entry per period.
"""
function energy_audit(sol::MultiPeriodSolution)
    total(a) = vec(sum(a; dims = 2))
    delivered, loss = total(sol.load_delivered_W), total(sol.pipe_heat_loss_W)
    return (
        plant_output_W = copy(sol.plant_output_W),
        delivered_W = delivered,
        pipe_loss_W = loss,
        shed_W = total(sol.load_shed_W),
        excess_W = total(sol.load_excess_W),
        closure_W = sol.plant_output_W .- delivered .- loss,
    )
end

# Outage search -----------------------------------------------------------------------------------

"""
    OrientedMultiPeriodSolve

Result of [`solve_multiperiod_oriented`](@ref): the `model` and `solution`, the oriented `networks`
of each period, `reversed_pipes` (for each period, the ids in the input network of the pipes that
run against their input direction), `method`, the starting orientation that produced the result,
and `rounds`, the number of multi-period NLP solves across all starting orientations.
"""
struct OrientedMultiPeriodSolve{M <: MultiPeriodModel}
    model::M
    solution::MultiPeriodSolution
    networks::Vector{CampusNetwork}
    reversed_pipes::Vector{Vector{Int}}
    method::Symbol
    rounds::Int
end

# Flips the loop pipes pinned at their minimum flow in each outage period. Returns the new networks
# and whether anything changed. A flip that strands a junction is skipped for that period.
function _flip_pinned(model::MultiPeriodModel, sol::MultiPeriodSolution, networks)
    data = model.data
    updated = copy(networks)
    changed = false
    for k in 1:data.nperiod
        isempty(data.out_of_service[k]) && continue
        template = data.templates[data.template_of[k]]
        d, opt = template.data, template.data.options
        lower = d.bounds.flow[1][1:d.npipe] .* opt.flow_ref_kg_per_s
        flows = template.direction .* sol.pipe_flow_kg_per_s[k, template.source_pipe]
        pinned = [e for e in 1:d.npipe if flows[e] <= 1.01 * lower[e] && template.net.pipes[e].is_loop]
        isempty(pinned) && continue
        pipes = copy(template.net.pipes)
        pipes[pinned] .= _flipped.(pipes[pinned])
        candidate = CampusNetwork(template.net.junctions, pipes, template.net.loads, template.net.plant)
        try
            compile_steam_data(candidate; options = opt)
        catch err
            err isa ArgumentError || rethrow()
            continue
        end
        updated[k] = candidate
        changed = true
    end
    return updated, changed
end

"""
    solve_multiperiod_oriented(net; heat_W, out_of_service, plant_rating_W = nothing,
                               priority_weight = nothing, ramp_limit_W_per_h = ...,
                               methods = (:search, :design), max_rounds = 2,
                               options = SteamModelOptions(), backend = nothing,
                               solver options...) -> OrientedMultiPeriodSolve

Solve a multi-period outage case with pipe directions chosen per period. Each entry of `methods` is
a starting orientation from [`orient_periods`](@ref). From each start, loop pipes that finish pinned
at their minimum flow in an outage period are flipped in that period and the horizon is solved
again, for at most `max_rounds` NLP solves. A round is kept only when it converges with a lower
objective. The converged result with the lowest objective is returned, or the last start's result
when none converges, so check `solution.converged`. This is a heuristic: the direction pattern is
not proven optimal.
"""
function solve_multiperiod_oriented(
        net::CampusNetwork;
        heat_W,
        out_of_service,
        plant_rating_W = nothing,
        priority_weight = nothing,
        ramp_limit_W_per_h = net.plant.ramp_limit_W_per_h,
        methods = (:search, :design),
        max_rounds::Int = 2,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
        kwargs...,
    )
    isempty(methods) && throw(ArgumentError("methods must name at least one orientation"))
    build(candidate) = build_multiperiod_model(
        net; heat_W, plant_rating_W, priority_weight, ramp_limit_W_per_h, out_of_service,
        networks = candidate, options, backend,
    )
    better(a, b) = a.converged && (!b.converged || a.objective_Wh < b.objective_Wh)

    function search(networks)
        model = build(networks)
        sol = solve_multiperiod(model; kwargs...)
        rounds = 1
        while rounds < max_rounds
            candidate, changed = _flip_pinned(model, sol, networks)
            changed || break
            candidate_model = build(candidate)
            candidate_sol = solve_multiperiod(candidate_model; kwargs...)
            rounds += 1
            better(candidate_sol, sol) || break
            networks, model, sol = candidate, candidate_model, candidate_sol
        end
        return (; networks, model, sol, rounds)
    end

    best, best_method, total = nothing, first(methods), 0
    tried = Vector{Vector{Vector{Pipe}}}()
    for method in methods
        networks = orient_periods(
            net; heat_W, out_of_service, plant_rating_W, method, options, backend, kwargs...,
        )
        pattern = [n.pipes for n in networks]
        pattern in tried && continue
        push!(tried, pattern)
        current = search(networks)
        total += current.rounds
        if best === nothing || better(current.sol, best.sol)
            best, best_method = current, method
        end
    end

    reversed = map(1:best.model.data.nperiod) do k
        template = best.model.data.templates[best.model.data.template_of[k]]
        sort!(template.source_pipe[template.direction .< 0])
    end
    return OrientedMultiPeriodSolve(best.model, best.sol, best.networks, reversed, best_method, total)
end

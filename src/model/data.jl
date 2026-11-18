# Compiles a network into flat arrays of isbits named tuples. Each array drives one ExaModels
# generator, so the same data runs on CPU and GPU backends.
#
# Edges share one index space: pipes `1:npipe`, loads `npipe .+ (1:nload)`, plant `nedge`.

"""
    SteamData

Scaled, backend-agnostic model data produced by [`compile_steam_data`](@ref). Holds the
generator arrays, variable bounds and starting point. Quantities are in the scaled units set
by the `SteamModelOptions` references.
"""
struct SteamData{M, EI, EO, MX, D, S, W, P, L, LP, PL, O}
    options::SteamModelOptions
    njunction::Int
    npipe::Int
    nload::Int
    nedge::Int
    nmass::Int
    npump::Int
    pipe_is_steam::Vector{Bool}
    pump_pipe::Vector{Int}
    pipe_from::Vector{Int}
    pipe_to::Vector{Int}
    pipe_length_m::Vector{Float64}
    pipe_diameter_m::Vector{Float64}
    pipe_friction::Vector{Float64}
    pipe_gamma_W_per_mK::Vector{Float64}
    load_steam::Vector{Int}
    load_water::Vector{Int}
    plant_steam::Int
    plant_water::Int
    plant_rating_W::Float64
    junction_is_steam::Vector{Bool}
    mass_row::Vector{Int}
    demand::Vector{Float64}
    mass_terms::M
    energy_in::EI
    energy_out::EO
    mixing::MX
    decay::D
    steam_pipes::S
    water_pipes::W
    pumps::P
    loads::L
    load_pressure::LP
    plant::PL
    objective_loads::O
    bounds::NamedTuple
    start::NamedTuple
end

_side(x) = lowercase(string(x))

function _validate_network(net, opt::SteamModelOptions)
    nj = length(net.junctions)
    sides = Dict(j.id => _side(j.side) for j in net.junctions)
    sort(collect(keys(sides))) == collect(1:nj) ||
        throw(ArgumentError("junction ids must be contiguous and 1-based"))
    all(in(("steam", "water")), values(sides)) ||
        throw(ArgumentError("junction side must be `steam` or `water`"))
    [p.id for p in net.pipes] == collect(1:length(net.pipes)) ||
        throw(ArgumentError("pipes must be sorted by a contiguous 1-based id"))
    [l.id for l in net.loads] == collect(1:length(net.loads)) ||
        throw(ArgumentError("loads must be sorted by a contiguous 1-based id"))
    for p in net.pipes
        side = _side(p.side)
        (sides[p.from] == side && sides[p.to] == side) ||
            throw(ArgumentError("pipe $(p.id) connects junctions on the wrong side"))
        (p.length_m > 0 && p.diameter_m > 0 && p.friction_factor > 0) ||
            throw(ArgumentError("pipe $(p.id) needs positive length, diameter and friction"))
        p.heat_loss_W_per_m2K > 0 ||
            throw(ArgumentError("pipe $(p.id) needs a positive heat-loss coefficient"))
        (side == "water" || p.max_pump_boost_Pa == 0) ||
            throw(ArgumentError("pipe $(p.id): pumps are only modeled on water pipes"))
    end
    for l in net.loads
        (sides[l.steam_junction] == "steam" && sides[l.water_junction] == "water") ||
            throw(ArgumentError("load $(l.id) must connect a steam to a water junction"))
    end
    (sides[net.plant.steam_junction] == "steam" && sides[net.plant.water_junction] == "water") ||
        throw(ArgumentError("the plant must connect a water to a steam junction"))
    opt.water_temp_min_K > opt.ambient_temp_K ||
        throw(ArgumentError("water_temp_min_K must exceed ambient_temp_K"))
    opt.saturation_temp_K > opt.water_temp_min_K ||
        throw(ArgumentError("saturation_temp_K must exceed water_temp_min_K"))
    return nothing
end

# Junctions reachable from `root` in breadth-first order, with the edge that reached each one.
function _bfs(root, n, adjacency)
    order = [root]
    parent_edge = zeros(Int, n)
    parent_node = zeros(Int, n)
    seen = falses(n)
    seen[root] = true
    head = 1
    while head <= length(order)
        i = order[head]
        head += 1
        for (e, k) in adjacency[i]
            seen[k] && continue
            seen[k] = true
            parent_edge[k] = e
            parent_node[k] = i
            push!(order, k)
        end
    end
    return order, parent_edge, parent_node, seen
end

# Spanning-tree flows: accumulates each junction's load flow toward the plant.
function _tree_flows(order, parent_edge, parent_node, injection, npipe)
    flow = zeros(npipe)
    through = copy(injection)
    for k in Iterators.reverse(order)
        e = parent_edge[k]
        e == 0 && continue
        flow[e] = through[k]
        through[parent_node[k]] += through[k]
    end
    return flow
end

"""
    compile_steam_data(net; heat_W = nothing, plant_rating_W = nothing,
                       options = SteamModelOptions())

Compile a network that follows `docs/network-schema.md` into [`SteamData`](@ref). `heat_W` is the
heat demand per load (default `design_heat_W`). `plant_rating_W` overrides the plant rating.
Throws `ArgumentError` when the network breaks the contract or a load cannot be reached from the
plant along the nominal pipe directions.
"""
function compile_steam_data(
        net;
        heat_W = nothing,
        plant_rating_W = nothing,
        options::SteamModelOptions = SteamModelOptions(),
    )
    opt = options
    _validate_network(net, opt)

    nj, np, nl = length(net.junctions), length(net.pipes), length(net.loads)
    ne = np + nl + 1
    plant = net.plant
    demand_W = heat_W === nothing ? Float64[l.design_heat_W for l in net.loads] : Float64.(collect(heat_W))
    length(demand_W) == nl || throw(ArgumentError("heat_W must have one entry per load"))
    all(>=(0), demand_W) || throw(ArgumentError("heat_W must be non-negative"))
    rating_W = plant_rating_W === nothing ? Float64(plant.rating_W) : Float64(plant_rating_W)

    pref, tref, fref, qref = opt.pressure_ref_Pa, opt.temperature_ref_K,
        opt.flow_ref_kg_per_s, opt.power_ref_W
    tamb, tsat = opt.ambient_temp_K, opt.saturation_temp_K
    cs, cw, cl = opt.cp_steam_J_per_kgK, opt.cp_water_J_per_kgK, opt.latent_heat_J_per_kg

    steam_tmax = max(opt.steam_temp_max_K, plant.supply_temp_K)
    junction_is_steam = Bool[false for _ in 1:nj]
    for j in net.junctions
        junction_is_steam[j.id] = _side(j.side) == "steam"
    end
    pipe_is_steam = Bool[_side(p.side) == "steam" for p in net.pipes]

    edge_from = vcat(Int[p.from for p in net.pipes], Int[l.steam_junction for l in net.loads], plant.water_junction)
    edge_to = vcat(Int[p.to for p in net.pipes], Int[l.water_junction for l in net.loads], plant.steam_junction)
    has_outflow = falses(nj)
    has_outflow[edge_from] .= true
    all(has_outflow) ||
        throw(ArgumentError("every junction needs an outgoing edge to define its temperature"))

    # The mass balances sum to zero over the closed circuit, so one is dropped (see model notes).
    mass_row = zeros(Int, nj)
    nmass = 0
    for j in 1:nj
        j == plant.water_junction && continue
        nmass += 1
        mass_row[j] = nmass
    end
    mass_terms = [
        (row = mass_row[j], edge = e, sign = s)
        for (e, j, s) in Iterators.flatten((
            ((e, edge_to[e], 1.0) for e in 1:ne),
            ((e, edge_from[e], -1.0) for e in 1:ne),
        )) if mass_row[j] != 0
    ]
    energy_in = [(row = edge_to[e], edge = e) for e in 1:ne]
    energy_out = [(row = edge_from[e], edge = e) for e in 1:ne]
    mixing = [(edge = e, node = edge_from[e]) for e in 1:ne]

    # Pipe coefficients and the flow bound implied by the temperature limits.
    area(p) = pi * p.diameter_m^2 / 4
    gamma = Float64[p.heat_loss_W_per_m2K * pi * p.diameter_m for p in net.pipes]
    log_ratio_steam = log((steam_tmax - tamb) / (tsat - tamb))
    log_ratio_water = log((tsat - tamb) / (opt.water_temp_min_K - tamb))
    flow_min = map(enumerate(net.pipes)) do (e, p)
        c, ratio = pipe_is_steam[e] ? (cs, log_ratio_steam) : (cw, log_ratio_water)
        max(opt.flow_floor_kg_per_s, p.length_m * gamma[e] / (c * ratio))
    end

    decay = [
        (
            edge = e,
            a = p.length_m * gamma[e] / ((pipe_is_steam[e] ? cs : cw) * fref),
            tau_amb = tamb / tref,
        ) for (e, p) in enumerate(net.pipes)
    ]
    steam_pipes = [
        (
            edge = e,
            from = p.from,
            to = p.to,
            k = p.friction_factor * opt.gas_constant_J_per_kgK * fref^2 /
                (area(p)^2 * p.diameter_m * pref^2),
            b1 = tamb * p.length_m,
            b2 = cs * fref * tref / gamma[e],
            a = p.length_m * gamma[e] / (cs * fref),
            tau_amb = tamb / tref,
        ) for (e, p) in enumerate(net.pipes) if pipe_is_steam[e]
    ]
    water_ids = [e for e in 1:np if !pipe_is_steam[e]]
    water_pipes = [
        (
            edge = e,
            from = net.pipes[e].from,
            to = net.pipes[e].to,
            k = net.pipes[e].friction_factor * net.pipes[e].length_m * fref^2 /
                (2 * area(net.pipes[e])^2 * net.pipes[e].diameter_m * opt.water_density_kg_per_m3 * pref),
        ) for e in water_ids
    ]
    pump_pipe = [e for e in water_ids if net.pipes[e].max_pump_boost_Pa > 0]
    water_row = Dict(e => r for (r, e) in enumerate(water_ids))
    pumps = [(row = water_row[e], pump = k) for (k, e) in enumerate(pump_pipe)]

    a_s, a_w, a_l = cs * fref * tref / qref, cw * fref * tref / qref, cl * fref / qref
    tau_sat = tsat / tref
    loads = [
        (load = l, edge = np + l, a_s = a_s, a_l = a_l, a_w = a_w, tau_sat = tau_sat)
        for l in 1:nl
    ]
    load_pressure = [(steam = l.steam_junction, water = l.water_junction) for l in net.loads]
    plant_row = [(edge = ne, a_s = a_s, a_l = a_l, a_w = a_w, tau_sat = tau_sat)]
    objective_loads = [
        (
            load = l.id,
            shed = opt.shed_weight * l.priority_weight,
            excess = opt.excess_weight,
        ) for l in net.loads
    ]

    # Bounds.
    plim_lo = fill(opt.pressure_min_Pa, nj)
    plim_hi = fill(max(opt.pressure_max_Pa, plant.supply_pressure_Pa), nj)
    plim_lo[plant.steam_junction] = max(opt.pressure_min_Pa, plant.supply_pressure_Pa)
    plim_lo[plant.water_junction] = max(opt.pressure_min_Pa, plant.return_pressure_Pa)

    tnode_lo = [junction_is_steam[j] ? tsat : opt.water_temp_min_K for j in 1:nj]
    tnode_hi = [junction_is_steam[j] ? steam_tmax : tsat for j in 1:nj]
    edge_in_steam = vcat(pipe_is_steam, trues(nl), false)
    edge_out_steam = vcat(pipe_is_steam, falses(nl), true)
    tin_lo = [s ? tsat : opt.water_temp_min_K for s in edge_in_steam]
    tin_hi = [s ? steam_tmax : tsat for s in edge_in_steam]
    tout_lo = [s ? tsat : opt.water_temp_min_K for s in edge_out_steam]
    tout_hi = [s ? steam_tmax : tsat for s in edge_out_steam]
    flow_lo = vcat(flow_min, zeros(nl + 1))

    bounds = (
        pressure = (plim_lo ./ pref, plim_hi ./ pref),
        temperature = (tnode_lo ./ tref, tnode_hi ./ tref),
        flow = (flow_lo ./ fref, fill(Inf, ne)),
        temp_in = (tin_lo ./ tref, tin_hi ./ tref),
        temp_out = (tout_lo ./ tref, tout_hi ./ tref),
        boost = (zeros(length(pump_pipe)), [net.pipes[e].max_pump_boost_Pa / pref for e in pump_pipe]),
        plant_power = (0.0, rating_W / qref),
    )

    start = _starting_point(
        net, opt, demand_W, flow_min, gamma, pipe_is_steam, junction_is_steam, steam_tmax, bounds
    )

    return SteamData(
        opt, nj, np, nl, ne, nmass, length(pump_pipe), pipe_is_steam, pump_pipe,
        Int[p.from for p in net.pipes], Int[p.to for p in net.pipes],
        Float64[p.length_m for p in net.pipes], Float64[p.diameter_m for p in net.pipes],
        Float64[p.friction_factor for p in net.pipes], gamma,
        Int[l.steam_junction for l in net.loads], Int[l.water_junction for l in net.loads],
        plant.steam_junction, plant.water_junction, rating_W, junction_is_steam, mass_row,
        demand_W ./ qref, mass_terms, energy_in, energy_out, mixing, decay, steam_pipes,
        water_pipes, pumps, loads, load_pressure, plant_row, objective_loads, bounds, start,
    )
end

# Physically consistent start: spanning-tree flows, decayed steam temperatures, flat pressures.
function _starting_point(
        net, opt, demand_W, flow_min, gamma, pipe_is_steam, junction_is_steam, steam_tmax, bounds
    )
    nj, np, nl = length(net.junctions), length(net.pipes), length(net.loads)
    ne = np + nl + 1
    plant = net.plant
    pref, tref, fref, qref = opt.pressure_ref_Pa, opt.temperature_ref_K,
        opt.flow_ref_kg_per_s, opt.power_ref_W
    tamb, tsat = opt.ambient_temp_K, opt.saturation_temp_K
    cs, cw, cl = opt.cp_steam_J_per_kgK, opt.cp_water_J_per_kgK, opt.latent_heat_J_per_kg

    t_steam0 = min(steam_tmax, max(plant.supply_temp_K, tsat + 5.0))
    t_water0 = 0.5 * (tsat + opt.water_temp_min_K)
    specific = cl + cs * (t_steam0 - tsat) + cw * (tsat - t_water0)
    load_flow = max.(demand_W, 1.0e-3 * max(maximum(demand_W; init = 0.0), 1.0)) ./ specific

    forward = [Tuple{Int, Int}[] for _ in 1:nj]
    backward = [Tuple{Int, Int}[] for _ in 1:nj]
    for (e, p) in enumerate(net.pipes)
        push!(pipe_is_steam[e] ? forward[p.from] : backward[p.to], (e, pipe_is_steam[e] ? p.to : p.from))
    end
    s_order, s_edge, s_node, s_seen = _bfs(plant.steam_junction, nj, forward)
    w_order, w_edge, w_node, w_seen = _bfs(plant.water_junction, nj, backward)
    for l in net.loads
        (s_seen[l.steam_junction] && w_seen[l.water_junction]) || throw(
            ArgumentError("load $(l.id) cannot be reached from the plant along nominal pipe directions")
        )
    end

    s_inject = zeros(nj)
    w_inject = zeros(nj)
    for (i, l) in enumerate(net.loads)
        s_inject[l.steam_junction] += load_flow[i]
        w_inject[l.water_junction] += load_flow[i]
    end
    tree = _tree_flows(s_order, s_edge, s_node, s_inject, np) .+
        _tree_flows(w_order, w_edge, w_node, w_inject, np)
    pipe_flow = max.(tree, 1.5 .* flow_min)

    t_node = [junction_is_steam[j] ? t_steam0 : t_water0 for j in 1:nj]
    for k in s_order
        e = s_edge[k]
        e == 0 && continue
        p = net.pipes[e]
        x = p.length_m * gamma[e] / (cs * pipe_flow[e])
        t_node[k] = max(tsat + 0.5, tamb + (t_node[s_node[k]] - tamb) * exp(-x))
    end

    edge_from = vcat(Int[p.from for p in net.pipes], Int[l.steam_junction for l in net.loads], plant.water_junction)
    t_in = t_node[edge_from]
    t_out = copy(t_in)
    for (e, p) in enumerate(net.pipes)
        c = pipe_is_steam[e] ? cs : cw
        t_out[e] = tamb + (t_in[e] - tamb) * exp(-p.length_m * gamma[e] / (c * pipe_flow[e]))
    end
    t_out[np .+ (1:nl)] .= t_water0
    t_out[ne] = t_steam0

    p_steam0 = plant.supply_pressure_Pa
    p_water0 = max(opt.pressure_min_Pa, plant.return_pressure_Pa)
    pressure = [junction_is_steam[j] ? p_steam0 : p_water0 for j in 1:nj]

    plant_flow = sum(load_flow; init = 0.0)
    flow = vcat(pipe_flow, load_flow, plant_flow)
    plant_power = min(plant_flow * specific, bounds.plant_power[2] * qref)

    clamp_to(x, (lo, hi)) = clamp.(x, lo, hi)
    return (
        pressure = clamp_to(pressure ./ pref, bounds.pressure),
        temperature = clamp_to(t_node ./ tref, bounds.temperature),
        flow = flow ./ fref,
        temp_in = clamp_to(t_in ./ tref, bounds.temp_in),
        temp_out = clamp_to(t_out ./ tref, bounds.temp_out),
        boost = 0.5 .* bounds.boost[2],
        plant_power = plant_power / qref,
    )
end

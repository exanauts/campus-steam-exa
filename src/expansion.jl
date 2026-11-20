# Network edits for capacity-planning studies: a new building, a new pipe pair, a larger pipe, better
# insulation and an extra boiler. Each edit returns a new, oriented and validated `CampusNetwork`;
# the input is never changed. New pieces follow the sizing rules of the campus generator
# (`generator/campus.jl`), without its random spread, so a new building looks like an existing one.
#
# This file is deliberately separate from the generator and the core model, whose sources are
# fingerprinted by `validation/source_hash.jl`.

# Generator rules applied without random spread: lateral and main lengths use the middle of the
# generator's ranges of route length over straight-line distance.
const _LATERAL_ROUTE_FACTOR = 1.2
const _MAIN_ROUTE_FACTOR = 1.065

"""
    water_partner(net, steam_junction) -> Int

The return-side junction that mirrors `steam_junction`. The generator draws the return network with a
fixed offset from the steam network, and every edit here keeps that rule, so the partner is the water
junction at that offset. Throws an `ArgumentError` when there is none.
"""
function water_partner(net::CampusNetwork, steam_junction::Integer)
    1 <= steam_junction <= length(net.junctions) ||
        throw(ArgumentError("Unknown junction $steam_junction."))
    s = net.junctions[steam_junction]
    s.side == "steam" || throw(ArgumentError("Junction $steam_junction is not on the steam side."))
    steam_junction == net.plant.steam_junction && return net.plant.water_junction
    x = round(s.x_m + _WATER_DRAW_OFFSET_M; digits = 1)
    y = round(s.y_m - _WATER_DRAW_OFFSET_M; digits = 1)
    for j in net.junctions
        j.side == "water" && j.kind == s.kind && isapprox(j.x_m, x; atol = 0.05) &&
            isapprox(j.y_m, y; atol = 0.05) && return j.id
    end
    throw(ArgumentError("No return-side junction mirrors steam junction $steam_junction."))
end

# Re-orient along the design flow, recompute loop flags and check the result.
_finish(junctions, pipes, loads, plant) =
    validate_network(orient_network(CampusNetwork(junctions, pipes, loads, plant)))

_distance(a::Junction, b::Junction) = hypot(a.x_m - b.x_m, a.y_m - b.y_m)

# The steam and return pipes between two steam junctions and their partners, in either direction.
function _pipe_between(net::CampusNetwork, side::AbstractString, a::Integer, b::Integer)
    for p in net.pipes
        p.side == side && minmax(p.from, p.to) == minmax(a, b) && return p
    end
    return nothing
end

"""
    add_building(net; tap, x_m, y_m, type, design_heat_W = nothing, name = nothing)
        -> (net, ids)

Add one building of `type` (`"lab"`, `"housing"`, `"classroom"` or `"critical"`) at drawing position
`(x_m, y_m)`, served by a steam lateral from the existing steam junction `tap` and a return lateral to
its partner on the return side. The design heat defaults to the middle of the generator's range for
the type, and the name to the next free name of that type, such as `Lab 17`.

Laterals follow the generator: the steam lateral is sized for at most 35 m/s at design flow and the
return lateral for 1.5 m/s of condensate, friction follows the fully rough rule, heat-loss
coefficients the generator's insulation rule, and the return lateral has a 225 kPa condensate pump.
The building gets the priority weight of its type.

Returns the new network, oriented along its design flow, and the ids of the new load, its steam and
return junctions and the two laterals. Existing junction, pipe and load ids do not change.
"""
function add_building(net::CampusNetwork; tap::Integer, x_m::Real, y_m::Real, type::AbstractString,
                      design_heat_W = nothing, name = nothing)
    type in _LOAD_TYPES || throw(ArgumentError("Unknown building type '$type'."))
    t = String(type)
    tap_junction = net.junctions[tap]
    tap_junction.side == "steam" && tap_junction.kind == "junction" ||
        throw(ArgumentError("The tap must be a steam-side junction that is not a building or the plant."))
    water_tap = water_partner(net, tap)
    heat = design_heat_W === nothing ? sum(_HEAT_RANGE_W[t]) / 2 : Float64(design_heat_W)
    heat > 0 || throw(ArgumentError("design_heat_W must be positive."))
    if name === nothing
        taken = count(l -> l.type == t, net.loads)
        name = string(_NAME_PREFIX[t], " ", lpad(taken + 1, 2, '0'))
    end
    any(l -> l.name == name, net.loads) && throw(ArgumentError("A building named '$name' exists."))

    n = length(net.junctions)
    steam_id, water_id = n + 1, n + 2
    x, y = round(Float64(x_m); digits = 1), round(Float64(y_m); digits = 1)
    steam_j = Junction(steam_id, "steam", "load", x, y)
    water_j = Junction(water_id, "water", "load", round(x + _WATER_DRAW_OFFSET_M; digits = 1),
                       round(y - _WATER_DRAW_OFFSET_M; digits = 1))
    length_m = round(_distance(tap_junction, steam_j) * _LATERAL_ROUTE_FACTOR; digits = 1)
    length_m > 0 || throw(ArgumentError("The building must not sit on its tap."))

    flow = heat / _LATENT_HEAT_J_PER_KG
    d_steam = _snap_size(sqrt(4 * flow / (pi * _STEAM_SIZING.density * _STEAM_SIZING.velocity)))
    d_water = _snap_size(sqrt(4 * flow / (pi * _WATER_DENSITY * _WATER_VELOCITY)))
    m = length(net.pipes)
    steam_pipe = Pipe(m + 1, "steam", tap, steam_id, length_m, d_steam,
                      round(_fully_rough_friction(d_steam); digits = 5),
                      round(_steam_heat_loss_u(d_steam); digits = 4), 0.0, false)
    water_pipe = Pipe(m + 2, "water", water_id, water_tap, length_m, d_water,
                      round(_fully_rough_friction(d_water); digits = 5), _WATER_HEAT_LOSS_U, 225e3, false)
    load = Load(length(net.loads) + 1, name, t, steam_id, water_id, heat, _PRIORITY[t])

    edited = _finish([net.junctions; steam_j; water_j], [net.pipes; steam_pipe; water_pipe],
                     [net.loads; load], net.plant)
    ids = (load = load.id, steam_junction = steam_id, water_junction = water_id,
           steam_pipe = m + 1, water_pipe = m + 2)
    return edited, ids
end

"""
    add_pipe_pair(net, a, b; diameter_m, length_m = nothing) -> (net, ids)

Add a steam main between the existing steam junctions `a` and `b`, and the return main beside it
between their return-side partners, for example a cross-tie that closes a loop. The return main is
0.4 times the steam diameter, as in the generator, and both use its friction and insulation rules.
`length_m` defaults to the straight-line distance times the generator's route factor for mains.

Returns the new network, oriented along its design flow, and the ids of the two new pipes.
"""
function add_pipe_pair(net::CampusNetwork, a::Integer, b::Integer; diameter_m::Real, length_m = nothing)
    ja, jb = net.junctions[a], net.junctions[b]
    ja.side == "steam" && jb.side == "steam" || throw(ArgumentError("Both ends must be steam junctions."))
    a != b || throw(ArgumentError("A pipe needs two different junctions."))
    d = Float64(diameter_m)
    d > 0 || throw(ArgumentError("diameter_m must be positive."))
    len = length_m === nothing ? round(_distance(ja, jb) * _MAIN_ROUTE_FACTOR; digits = 1) : Float64(length_m)
    len > 0 || throw(ArgumentError("length_m must be positive."))
    wa, wb = water_partner(net, a), water_partner(net, b)
    dw = round(_WATER_DIAMETER_RATIO * d; digits = 4)
    friction = round(_fully_rough_friction(d); digits = 5)
    m = length(net.pipes)
    steam_pipe = Pipe(m + 1, "steam", a, b, len, d, friction, round(_steam_heat_loss_u(d); digits = 4),
                      0.0, true)
    water_pipe = Pipe(m + 2, "water", wb, wa, len, dw, friction, _WATER_HEAT_LOSS_U, 0.0, true)
    edited = _finish(net.junctions, [net.pipes; steam_pipe; water_pipe], net.loads, net.plant)
    return edited, (steam_pipe = m + 1, water_pipe = m + 2)
end

"""
    resize_pipe(net, ids; diameter_m, with_return = true) -> net

Give the steam pipes `ids` the inner diameter `diameter_m`. Friction is recomputed with the fully
rough rule and the heat-loss coefficient with the generator's insulation rule, each keeping the pipe's
own deviation from the rule. With `with_return`, the return main beside each pipe is set to 0.4 times
the new diameter, as in the generator. A building lateral's return pipe is sized for condensate and is
left unchanged.
"""
function resize_pipe(net::CampusNetwork, ids; diameter_m::Real, with_return::Bool = true)
    d = Float64(diameter_m)
    d > 0 || throw(ArgumentError("diameter_m must be positive."))
    pipes = copy(net.pipes)
    function resized(p, dnew, u_rule)
        f = round(p.friction_factor * _fully_rough_friction(dnew) / _fully_rough_friction(p.diameter_m); digits = 5)
        u = round(p.heat_loss_W_per_m2K * u_rule(dnew) / u_rule(p.diameter_m); digits = 4)
        return Pipe(p.id, p.side, p.from, p.to, p.length_m, dnew, f, u, p.max_pump_boost_Pa, p.is_loop)
    end
    for id in ids
        1 <= id <= length(pipes) || throw(ArgumentError("Unknown pipe id $id."))
        p = pipes[id]
        p.side == "steam" || throw(ArgumentError("Pipe $id is not a steam pipe."))
        pipes[id] = resized(p, d, _steam_heat_loss_u)
        with_return || continue
        is_lateral = net.junctions[p.from].kind == "load" || net.junctions[p.to].kind == "load"
        is_lateral && continue
        w = _pipe_between(net, "water", water_partner(net, p.from), water_partner(net, p.to))
        w === nothing && continue
        pipes[w.id] = resized(w, round(_WATER_DIAMETER_RATIO * d; digits = 4), _ -> 1.0)
    end
    return _finish(net.junctions, pipes, net.loads, net.plant)
end

"""
    scale_heat_loss(net, ids, factor) -> net

Multiply the heat-loss coefficient of the pipes `ids` by `factor`, for example 0.5 for insulation that
halves the loss. Coefficients are rounded to 4 decimals as in the generator.
"""
function scale_heat_loss(net::CampusNetwork, ids, factor::Real)
    factor >= 0 || throw(ArgumentError("factor must not be negative."))
    pipes = copy(net.pipes)
    for id in ids
        1 <= id <= length(pipes) || throw(ArgumentError("Unknown pipe id $id."))
        p = pipes[id]
        pipes[id] = Pipe(p.id, p.side, p.from, p.to, p.length_m, p.diameter_m, p.friction_factor,
                         round(p.heat_loss_W_per_m2K * factor; digits = 4), p.max_pump_boost_Pa, p.is_loop)
    end
    return _finish(net.junctions, pipes, net.loads, net.plant)
end

"""
    add_boiler(net; count = 1) -> net

Add `count` boilers of the existing size to the plant. The rating grows in proportion and the ramp
limit stays at the same share of the rating. A solve can also take a different rating directly with
the `plant_rating_W` keyword.
"""
function add_boiler(net::CampusNetwork; count::Integer = 1)
    count >= 1 || throw(ArgumentError("count must be at least 1."))
    q = net.plant
    n = q.n_boilers + count
    plant = Plant(q.steam_junction, q.water_junction, q.rating_W * n / q.n_boilers, n,
                  q.ramp_limit_W_per_h * n / q.n_boilers, q.supply_temp_K, q.supply_pressure_Pa,
                  q.return_pressure_Pa)
    return validate_network(CampusNetwork(net.junctions, net.pipes, net.loads, plant))
end

"""
    steam_path(net, junction) -> Vector{Int}

Ids of the steam pipes on a shortest route, by length, from the plant to `junction`, plant end first.
Useful to pick the main that feeds a building.
"""
function steam_path(net::CampusNetwork, junction::Integer)
    n = length(net.junctions)
    dist = fill(Inf, n)
    via = zeros(Int, n)
    root = net.plant.steam_junction
    dist[root] = 0.0
    done = fill(false, n)
    steam = [p for p in net.pipes if p.side == "steam"]
    for _ in 1:n
        j, best = 0, Inf
        for i in 1:n
            !done[i] && dist[i] < best && ((j, best) = (i, dist[i]))
        end
        j == 0 && break
        done[j] = true
        for p in steam
            other = p.from == j ? p.to : p.to == j ? p.from : 0
            other == 0 && continue
            if dist[j] + p.length_m < dist[other]
                dist[other] = dist[j] + p.length_m
                via[other] = p.id
            end
        end
    end
    isfinite(dist[junction]) || throw(ArgumentError("Junction $junction has no steam route from the plant."))
    path = Int[]
    j = junction
    while j != root
        p = net.pipes[via[j]]
        push!(path, p.id)
        j = p.from == j ? p.to : p.from
    end
    return reverse!(path)
end

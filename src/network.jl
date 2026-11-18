# Network types, CSV input/output and flow orientation. The data contract is
# documented in docs/network-schema.md.

"""
    Junction(id, side, kind, x_m, y_m)

A network node. `side` is `"steam"` or `"water"`; `kind` is `"plant"`, `"load"`
or `"junction"`. Coordinates are drawing coordinates in metres.
"""
struct Junction
    id::Int
    side::String
    kind::String
    x_m::Float64
    y_m::Float64
end

"""
    Pipe(id, side, from, to, length_m, diameter_m, friction_factor,
         heat_loss_W_per_m2K, max_pump_boost_Pa, is_loop)

A pipe with nominal flow direction `from -> to`. `is_loop` is true when removing
the pipe keeps every load connected to the plant on that side.
"""
struct Pipe
    id::Int
    side::String
    from::Int
    to::Int
    length_m::Float64
    diameter_m::Float64
    friction_factor::Float64
    heat_loss_W_per_m2K::Float64
    max_pump_boost_Pa::Float64
    is_loop::Bool
end

"""
    Load(id, name, type, steam_junction, water_junction, design_heat_W, priority_weight)

A building heat load. `type` is `"lab"`, `"housing"`, `"classroom"` or `"critical"`.
"""
struct Load
    id::Int
    name::String
    type::String
    steam_junction::Int
    water_junction::Int
    design_heat_W::Float64
    priority_weight::Float64
end

"""
    Plant(steam_junction, water_junction, rating_W, n_boilers, ramp_limit_W_per_h,
          supply_temp_K, supply_pressure_Pa, return_pressure_Pa)

The central steam plant. The `n_boilers` identical boilers share `rating_W`.
"""
struct Plant
    steam_junction::Int
    water_junction::Int
    rating_W::Float64
    n_boilers::Int
    ramp_limit_W_per_h::Float64
    supply_temp_K::Float64
    supply_pressure_Pa::Float64
    return_pressure_Pa::Float64
end

"""
    CampusNetwork(junctions, pipes, loads, plant)

A complete campus network. See `docs/network-schema.md`.
"""
struct CampusNetwork
    junctions::Vector{Junction}
    pipes::Vector{Pipe}
    loads::Vector{Load}
    plant::Plant
end

function Base.:(==)(a::CampusNetwork, b::CampusNetwork)
    return a.junctions == b.junctions && a.pipes == b.pipes && a.loads == b.loads &&
           a.plant == b.plant
end

"""
    LoadProfiles(outdoor_temp_C, is_cold_snap, heat_W)

Hourly weather and heat demand. `heat_W` is indexed `(hour, load_id)`.
"""
struct LoadProfiles
    outdoor_temp_C::Vector{Float64}
    is_cold_snap::Vector{Bool}
    heat_W::Matrix{Float64}
end

function Base.:(==)(a::LoadProfiles, b::LoadProfiles)
    return a.outdoor_temp_C == b.outdoor_temp_C && a.is_cold_snap == b.is_cold_snap &&
           a.heat_W == b.heat_W
end

# ---------------------------------------------------------------------------
# Connectivity
# ---------------------------------------------------------------------------

_plant_junction(net::CampusNetwork, side::AbstractString) =
    side == "steam" ? net.plant.steam_junction : net.plant.water_junction

_load_junction(load::Load, side::AbstractString) =
    side == "steam" ? load.steam_junction : load.water_junction

# Undirected adjacency in compressed form: the neighbours of junction `j` are
# `(other[k], edge[k])` for `k` in `first[j]:first[j+1]-1`.
function _adjacency(n::Int, us::Vector{Int}, vs::Vector{Int})
    first = zeros(Int, n + 1)
    for (u, v) in zip(us, vs)
        first[u] += 1
        first[v] += 1
    end
    total = 1
    for j in 1:(n + 1)
        degree = first[j]
        first[j] = total
        total += degree
    end
    next = copy(first)
    other = Vector{Int}(undef, 2 * length(us))
    edge = Vector{Int}(undef, 2 * length(us))
    for (e, (u, v)) in enumerate(zip(us, vs))
        other[next[u]] = v
        edge[next[u]] = e
        next[u] += 1
        other[next[v]] = u
        edge[next[v]] = e
        next[v] += 1
    end
    return first, other, edge
end

# Hop distance from `root` over undirected edges; -1 marks unreachable junctions.
function _hops(n::Int, us::Vector{Int}, vs::Vector{Int}, root::Int)
    first, other, _ = _adjacency(n, us, vs)
    hops = fill(-1, n)
    hops[root] = 0
    queue = Vector{Int}(undef, n)
    queue[1] = root
    head, tail = 1, 1
    while head <= tail
        j = queue[head]
        head += 1
        for k in first[j]:(first[j + 1] - 1)
            i = other[k]
            if hops[i] < 0
                hops[i] = hops[j] + 1
                tail += 1
                queue[tail] = i
            end
        end
    end
    return hops
end

# For each edge, true when removing it keeps every marked junction connected to
# `root`. The bridge search is iterative so deep networks cannot overflow the stack.
function _loop_edges(n::Int, us::Vector{Int}, vs::Vector{Int}, root::Int, marked::Vector{Bool})
    first, other, edge = _adjacency(n, us, vs)
    is_loop = fill(true, length(us))
    order = zeros(Int, n)
    low = zeros(Int, n)
    below = zeros(Int, n)       # marked junctions in the search subtree
    parent_edge = zeros(Int, n)
    cursor = first[1:n]
    stack = Vector{Int}(undef, n)
    depth = 1
    stack[1] = root
    clock = 1
    order[root] = low[root] = clock
    below[root] = marked[root] ? 1 : 0
    while depth > 0
        j = stack[depth]
        if cursor[j] < first[j + 1]
            k = cursor[j]
            cursor[j] += 1
            e = edge[k]
            e == parent_edge[j] && continue
            i = other[k]
            if order[i] == 0
                clock += 1
                order[i] = low[i] = clock
                below[i] = marked[i] ? 1 : 0
                parent_edge[i] = e
                depth += 1
                stack[depth] = i
            else
                low[j] = min(low[j], order[i])
            end
        else
            depth -= 1
            if depth > 0
                parent = stack[depth]
                low[parent] = min(low[parent], low[j])
                below[parent] += below[j]
                if low[j] > order[parent] && below[j] > 0
                    is_loop[parent_edge[j]] = false
                end
            end
        end
    end
    return is_loop
end

# Recompute `is_loop` for every pipe from the topology.
function _with_loop_flags(junctions::Vector{Junction}, pipes::Vector{Pipe}, loads::Vector{Load},
                          plant::Plant)
    net = CampusNetwork(junctions, pipes, loads, plant)
    flags = fill(true, length(pipes))
    for side in ("steam", "water")
        idx = findall(p -> p.side == side, pipes)
        marked = fill(false, length(junctions))
        for load in loads
            marked[_load_junction(load, side)] = true
        end
        flags[idx] .= _loop_edges(length(junctions), [pipes[i].from for i in idx],
                                  [pipes[i].to for i in idx], _plant_junction(net, side), marked)
    end
    return [Pipe(p.id, p.side, p.from, p.to, p.length_m, p.diameter_m, p.friction_factor,
                 p.heat_loss_W_per_m2K, p.max_pump_boost_Pa, flags[i])
            for (i, p) in enumerate(pipes)]
end

# ---------------------------------------------------------------------------
# Hydraulics used to orient looped mains
# ---------------------------------------------------------------------------

# Solve the turbulent network equations `h[u] - h[v] = r * phi * abs(phi)` with the
# nodal balance `outflow - inflow = injection`, holding `h[root] = 0`, by the global
# gradient method. Every junction must be connected to `root`.
function _solve_hydraulics(n::Int, us::Vector{Int}, vs::Vector{Int}, r::Vector{Float64},
                           injection::Vector{Float64}, root::Int; maxiter::Int = 200,
                           tol::Float64 = 1e-10)
    m = length(us)
    scale = max(maximum(abs, injection), eps())
    floor_phi = 1e-7 * scale
    phi = fill(scale / max(m, 1), m)
    h = zeros(n)
    index = zeros(Int, n)
    unknowns = 0
    for j in 1:n
        if j != root
            unknowns += 1
            index[j] = unknowns
        end
    end
    unknowns == 0 && return h, phi

    I = Int[]
    J = Int[]
    sizehint!(I, 4m)
    sizehint!(J, 4m)
    for (u, v) in zip(us, vs)
        iu, iv = index[u], index[v]
        if iu > 0
            push!(I, iu)
            push!(J, iu)
        end
        if iv > 0
            push!(I, iv)
            push!(J, iv)
        end
        if iu > 0 && iv > 0
            push!(I, iu, iv)
            push!(J, iv, iu)
        end
    end
    V = zeros(length(I))
    rhs = zeros(unknowns)
    factor = nothing

    for _ in 1:maxiter
        for j in 1:n
            index[j] > 0 && (rhs[index[j]] = injection[j])
        end
        pos = 0
        for e in 1:m
            iu, iv = index[us[e]], index[vs[e]]
            g = 1 / (2 * r[e] * max(abs(phi[e]), floor_phi))
            if iu > 0
                pos += 1
                V[pos] = g
                rhs[iu] -= phi[e] / 2
            end
            if iv > 0
                pos += 1
                V[pos] = g
                rhs[iv] += phi[e] / 2
            end
            if iu > 0 && iv > 0
                V[pos + 1] = -g
                V[pos + 2] = -g
                pos += 2
            end
        end
        A = sparse(I, J, V, unknowns, unknowns)
        if factor === nothing
            factor = cholesky(Symmetric(A))
        else
            cholesky!(factor, Symmetric(A))
        end
        x = factor \ rhs
        for j in 1:n
            h[j] = index[j] > 0 ? x[index[j]] : 0.0
        end
        change = 0.0
        for e in 1:m
            g = 1 / (2 * r[e] * max(abs(phi[e]), floor_phi))
            updated = phi[e] / 2 + g * (h[us[e]] - h[vs[e]])
            change = max(change, abs(updated - phi[e]))
            phi[e] = updated
        end
        change <= tol * scale && return h, phi
    end
    error("Hydraulic solve did not converge in $maxiter iterations.")
end

_pipe_resistance(p::Pipe) = 8 * p.friction_factor * p.length_m / (pi^2 * p.diameter_m^5)

# Orient the pipes of one side along the design-load flow. Junctions are placed in a
# single total order, so the result cannot contain a directed cycle.
function _orient_side(net::CampusNetwork, side::String, pipes::Vector{Pipe})
    n = length(net.junctions)
    root = _plant_junction(net, side)
    hops = _hops(n, [p.from for p in pipes], [p.to for p in pipes], root)

    # Hydraulics run on the energized part only.
    local_id = zeros(Int, n)
    energized = 0
    for j in 1:n
        if hops[j] >= 0
            energized += 1
            local_id[j] = energized
        end
    end
    kept = [p for p in pipes if hops[p.from] >= 0 && hops[p.to] >= 0]
    us = [local_id[p.from] for p in kept]
    vs = [local_id[p.to] for p in kept]
    r = [_pipe_resistance(p) for p in kept]
    load_sign = side == "steam" ? -1.0 : 1.0
    injection = zeros(energized)
    for load in net.loads
        injection[local_id[_load_junction(load, side)]] += load_sign * load.design_heat_W / 1e6
    end
    injection[local_id[root]] -= sum(injection)
    h, _ = _solve_hydraulics(energized, us, vs, r, injection, local_id[root])

    # Ties in head (zero-flow pipes) fall back to hop distance from the plant.
    tie = maximum(abs, h; init = 0.0) * 1e-9
    level(j) = tie > 0 ? round(Int64, h[local_id[j]] / tie) : Int64(0)
    hop_rank(j) = side == "steam" ? hops[j] : -hops[j]
    upstream(a, b) = (-level(a), hop_rank(a), a) < (-level(b), hop_rank(b), b)

    oriented = Pipe[]
    sizehint!(oriented, length(kept))
    for p in kept
        keep_direction = upstream(p.from, p.to)
        from, to = keep_direction ? (p.from, p.to) : (p.to, p.from)
        # A pump cannot push against its installed direction.
        boost = keep_direction ? p.max_pump_boost_Pa : 0.0
        push!(oriented, Pipe(p.id, p.side, from, to, p.length_m, p.diameter_m, p.friction_factor,
                             p.heat_loss_W_per_m2K, boost, p.is_loop))
    end
    return oriented
end

# Junctions reached by following pipe directions from the plant (steam side) or
# against them (water side).
function _directed_reach(net::CampusNetwork, side::AbstractString)
    n = length(net.junctions)
    pipes = [p for p in net.pipes if p.side == side]
    tails = side == "steam" ? [p.from for p in pipes] : [p.to for p in pipes]
    heads = side == "steam" ? [p.to for p in pipes] : [p.from for p in pipes]
    outgoing = [Int[] for _ in 1:n]
    for (t, v) in zip(tails, heads)
        push!(outgoing[t], v)
    end
    seen = fill(false, n)
    root = _plant_junction(net, side)
    seen[root] = true
    stack = [root]
    while !isempty(stack)
        for i in outgoing[pop!(stack)]
            if !seen[i]
                seen[i] = true
                push!(stack, i)
            end
        end
    end
    return seen
end

"""
    orient_network(net; out_of_service = Int[]) -> CampusNetwork

Return a copy of `net` with the pipes listed in `out_of_service` (ids in `net`)
removed and every remaining pipe directed along the design-load flow: away from
the plant on the steam side and toward it on the water side.

Directions come from solving the turbulent pipe-network equations at the design
heat of every load, so looped mains get the direction the flow actually takes.
Pipes are renumbered contiguously in their original order, junction and load ids
do not change, and `is_loop` is recomputed for the reduced network. Pipes left
without a path to the plant serve no load and are removed as well.

Throws an `ArgumentError` when a pipe id is unknown or when the outage disconnects
a load from the plant on either side.
"""
function orient_network(net::CampusNetwork; out_of_service = Int[])
    unknown = [id for id in out_of_service if !(1 <= id <= length(net.pipes))]
    isempty(unknown) ||
        throw(ArgumentError("Unknown pipe ids in out_of_service: $(join(unknown, ", "))."))
    removed = Set{Int}(out_of_service)
    remaining = [p for p in net.pipes if !(p.id in removed)]

    oriented = Pipe[]
    for side in ("steam", "water")
        side_pipes = [p for p in remaining if p.side == side]
        hops = _hops(length(net.junctions), [p.from for p in side_pipes],
                     [p.to for p in side_pipes], _plant_junction(net, side))
        lost = [load for load in net.loads if hops[_load_junction(load, side)] < 0]
        if !isempty(lost)
            names = join((l.name for l in lost), ", ")
            ids = join(sort!(collect(removed)), ", ")
            throw(ArgumentError("Taking pipes [$ids] out of service disconnects " *
                                "$(length(lost)) load(s) from the plant on the $side side: $names."))
        end
        append!(oriented, _orient_side(net, side, side_pipes))
    end

    sort!(oriented; by = p -> p.id)
    renumbered = [Pipe(i, p.side, p.from, p.to, p.length_m, p.diameter_m, p.friction_factor,
                       p.heat_loss_W_per_m2K, p.max_pump_boost_Pa, p.is_loop)
                  for (i, p) in enumerate(oriented)]
    flagged = _with_loop_flags(net.junctions, renumbered, net.loads, net.plant)
    result = CampusNetwork(net.junctions, flagged, net.loads, net.plant)
    for side in ("steam", "water")
        seen = _directed_reach(result, side)
        for load in result.loads
            seen[_load_junction(load, side)] ||
                error("Orientation left $(load.name) without a directed path on the $side side.")
        end
    end
    return result
end

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

"""
    validate_network(net) -> net

Check `net` against `docs/network-schema.md`: contiguous ids, valid labels, pipes
that stay on one side, correct connection points, positive physical quantities and
`is_loop` flags that match the topology. Throws an `ArgumentError` on a violation.
"""
function validate_network(net::CampusNetwork)
    check(ok, message) = ok || throw(ArgumentError("Invalid network: $message"))
    n = length(net.junctions)
    for (i, j) in enumerate(net.junctions)
        check(j.id == i, "junction ids must be contiguous (position $i has id $(j.id)).")
        check(j.side in ("steam", "water"), "junction $i has side '$(j.side)'.")
        check(j.kind in ("plant", "load", "junction"), "junction $i has kind '$(j.kind)'.")
        check(isfinite(j.x_m) && isfinite(j.y_m), "junction $i has non-finite coordinates.")
    end
    for (i, p) in enumerate(net.pipes)
        check(p.id == i, "pipe ids must be contiguous (position $i has id $(p.id)).")
        check(p.side in ("steam", "water"), "pipe $i has side '$(p.side)'.")
        check(1 <= p.from <= n && 1 <= p.to <= n, "pipe $i references an unknown junction.")
        check(p.from != p.to, "pipe $i is a self-loop.")
        check(net.junctions[p.from].side == p.side && net.junctions[p.to].side == p.side,
              "pipe $i connects junctions that are not on its side.")
        check(p.length_m > 0 && p.diameter_m > 0 && p.friction_factor > 0,
              "pipe $i has non-positive geometry or friction.")
        check(p.heat_loss_W_per_m2K >= 0 && p.max_pump_boost_Pa >= 0,
              "pipe $i has a negative heat-loss coefficient or pump boost.")
    end
    for (i, l) in enumerate(net.loads)
        check(l.id == i, "load ids must be contiguous (position $i has id $(l.id)).")
        check(l.type in ("lab", "housing", "classroom", "critical"), "load $i has type '$(l.type)'.")
        check(1 <= l.steam_junction <= n && net.junctions[l.steam_junction].side == "steam" &&
              net.junctions[l.steam_junction].kind == "load", "load $i has a bad steam junction.")
        check(1 <= l.water_junction <= n && net.junctions[l.water_junction].side == "water" &&
              net.junctions[l.water_junction].kind == "load", "load $i has a bad water junction.")
        check(l.design_heat_W > 0 && l.priority_weight > 0,
              "load $i has a non-positive design heat or priority weight.")
    end
    plant = net.plant
    check(1 <= plant.steam_junction <= n && net.junctions[plant.steam_junction].side == "steam" &&
          net.junctions[plant.steam_junction].kind == "plant", "plant has a bad steam junction.")
    check(1 <= plant.water_junction <= n && net.junctions[plant.water_junction].side == "water" &&
          net.junctions[plant.water_junction].kind == "plant", "plant has a bad water junction.")
    check(count(j -> j.kind == "plant", net.junctions) == 2,
          "there must be exactly one plant junction per side.")
    check(plant.rating_W > 0 && plant.n_boilers >= 1 && plant.ramp_limit_W_per_h > 0,
          "plant rating, boiler count and ramp limit must be positive.")
    check(plant.supply_temp_K > 0 && plant.supply_pressure_Pa > plant.return_pressure_Pa > 0,
          "plant supply state must be positive with supply pressure above return pressure.")
    flagged = _with_loop_flags(net.junctions, net.pipes, net.loads, net.plant)
    for (p, q) in zip(net.pipes, flagged)
        check(p.is_loop == q.is_loop, "pipe $(p.id) has an is_loop flag that contradicts the topology.")
    end
    return net
end

# ---------------------------------------------------------------------------
# CSV input and output
# ---------------------------------------------------------------------------

function _write_csv(path::AbstractString, header::Vector{String}, rows)
    open(path, "w") do io
        println(io, join(header, ','))
        for row in rows
            println(io, join(row, ','))
        end
    end
    return path
end

function _read_csv(path::AbstractString, header::Vector{String})
    isfile(path) || throw(ArgumentError("Missing network file: $(basename(path))."))
    lines = readlines(path)
    (isempty(lines) || split(lines[1], ',') != header) &&
        throw(ArgumentError("$(basename(path)) must have the columns: $(join(header, ','))."))
    rows = Vector{Vector{SubString{String}}}()
    sizehint!(rows, length(lines) - 1)
    for (number, line) in enumerate(lines[2:end])
        isempty(line) && continue
        fields = split(line, ',')
        length(fields) == length(header) ||
            throw(ArgumentError("$(basename(path)) row $number has $(length(fields)) columns."))
        push!(rows, fields)
    end
    return rows
end

const _JUNCTION_COLUMNS = ["id", "side", "kind", "x_m", "y_m"]
const _PIPE_COLUMNS = ["id", "side", "from", "to", "length_m", "diameter_m", "friction_factor",
                       "heat_loss_W_per_m2K", "max_pump_boost_Pa", "is_loop"]
const _LOAD_COLUMNS = ["id", "name", "type", "steam_junction", "water_junction", "design_heat_W",
                       "priority_weight"]
const _PLANT_COLUMNS = ["steam_junction", "water_junction", "rating_W", "n_boilers",
                        "ramp_limit_W_per_h", "supply_temp_K", "supply_pressure_Pa",
                        "return_pressure_Pa"]
const _WEATHER_COLUMNS = ["hour", "outdoor_temp_C", "is_cold_snap"]
const _PROFILE_COLUMNS = ["hour", "load_id", "heat_W"]

"""
    write_network(dir, net) -> dir

Write `junctions.csv`, `pipes.csv`, `loads.csv` and `plant.csv` to `dir`, creating
the directory when needed.
"""
function write_network(dir::AbstractString, net::CampusNetwork)
    mkpath(dir)
    _write_csv(joinpath(dir, "junctions.csv"), _JUNCTION_COLUMNS,
               ((j.id, j.side, j.kind, j.x_m, j.y_m) for j in net.junctions))
    _write_csv(joinpath(dir, "pipes.csv"), _PIPE_COLUMNS,
               ((p.id, p.side, p.from, p.to, p.length_m, p.diameter_m, p.friction_factor,
                 p.heat_loss_W_per_m2K, p.max_pump_boost_Pa, p.is_loop) for p in net.pipes))
    _write_csv(joinpath(dir, "loads.csv"), _LOAD_COLUMNS,
               ((l.id, l.name, l.type, l.steam_junction, l.water_junction, l.design_heat_W,
                 l.priority_weight) for l in net.loads))
    q = net.plant
    _write_csv(joinpath(dir, "plant.csv"), _PLANT_COLUMNS,
               ((q.steam_junction, q.water_junction, q.rating_W, q.n_boilers, q.ramp_limit_W_per_h,
                 q.supply_temp_K, q.supply_pressure_Pa, q.return_pressure_Pa),))
    return dir
end

"""
    read_network(dir) -> CampusNetwork

Read and validate a network written by [`write_network`](@ref).
"""
function read_network(dir::AbstractString)
    junctions = [Junction(parse(Int, r[1]), String(r[2]), String(r[3]), parse(Float64, r[4]),
                          parse(Float64, r[5]))
                 for r in _read_csv(joinpath(dir, "junctions.csv"), _JUNCTION_COLUMNS)]
    pipes = [Pipe(parse(Int, r[1]), String(r[2]), parse(Int, r[3]), parse(Int, r[4]),
                  parse(Float64, r[5]), parse(Float64, r[6]), parse(Float64, r[7]),
                  parse(Float64, r[8]), parse(Float64, r[9]), parse(Bool, r[10]))
             for r in _read_csv(joinpath(dir, "pipes.csv"), _PIPE_COLUMNS)]
    loads = [Load(parse(Int, r[1]), String(r[2]), String(r[3]), parse(Int, r[4]), parse(Int, r[5]),
                  parse(Float64, r[6]), parse(Float64, r[7]))
             for r in _read_csv(joinpath(dir, "loads.csv"), _LOAD_COLUMNS)]
    rows = _read_csv(joinpath(dir, "plant.csv"), _PLANT_COLUMNS)
    length(rows) == 1 || throw(ArgumentError("plant.csv must have exactly one row."))
    r = rows[1]
    plant = Plant(parse(Int, r[1]), parse(Int, r[2]), parse(Float64, r[3]), parse(Int, r[4]),
                  parse(Float64, r[5]), parse(Float64, r[6]), parse(Float64, r[7]),
                  parse(Float64, r[8]))
    return validate_network(CampusNetwork(junctions, pipes, loads, plant))
end

"""
    write_weather(dir, profiles) -> dir

Write only `weather.csv` to `dir`, creating the directory when needed.
"""
function write_weather(dir::AbstractString, profiles::LoadProfiles)
    mkpath(dir)
    _write_csv(joinpath(dir, "weather.csv"), _WEATHER_COLUMNS,
               ((h, profiles.outdoor_temp_C[h], profiles.is_cold_snap[h])
                for h in eachindex(profiles.outdoor_temp_C)))
    return dir
end

"""
    write_profiles(dir, profiles) -> dir

Write `weather.csv` and `load_profiles.csv` to `dir`, creating the directory when needed.
"""
function write_profiles(dir::AbstractString, profiles::LoadProfiles)
    write_weather(dir, profiles)
    hours, n_loads = size(profiles.heat_W)
    _write_csv(joinpath(dir, "load_profiles.csv"), _PROFILE_COLUMNS,
               ((h, l, profiles.heat_W[h, l]) for h in 1:hours for l in 1:n_loads))
    return dir
end

"""
    read_profiles(dir) -> LoadProfiles

Read profiles written by [`write_profiles`](@ref).
"""
function read_profiles(dir::AbstractString)
    weather = _read_csv(joinpath(dir, "weather.csv"), _WEATHER_COLUMNS)
    temps = [parse(Float64, r[2]) for r in weather]
    snap = Bool[parse(Bool, r[3]) for r in weather]
    rows = _read_csv(joinpath(dir, "load_profiles.csv"), _PROFILE_COLUMNS)
    hours = length(temps)
    n_loads = hours == 0 ? 0 : div(length(rows), hours)
    length(rows) == hours * n_loads ||
        throw(ArgumentError("load_profiles.csv does not cover every hour and load."))
    heat = zeros(hours, n_loads)
    for r in rows
        heat[parse(Int, r[1]), parse(Int, r[2])] = parse(Float64, r[3])
    end
    return LoadProfiles(temps, snap, heat)
end

# Synthetic campus layout and pipe sizing for the fictional Example University.
#
# Layout. Streets form a jittered grid. Each block holds up to four buildings, one
# per quadrant, and each building connects by a short service lateral to the street
# intersection at its block corner, so laterals never cross. Two feeders join the
# plant, south of the grid, to adjacent intersections. The return network mirrors the
# steam network and is drawn with a small offset.
#
# Parameter ranges (all synthetic, typical of campus steam systems):
#   Supply steam            1.0 MPa absolute, 463 K (about 10 K superheat)
#   Condensate at plant     0.25 MPa absolute
#   Building design heat    lab 1.5-3.5 MW, housing 0.6-1.6 MW, classroom 0.5-1.4 MW,
#                           critical 2.5-4.5 MW; scaled campuses shrink these so the
#                           total stays at or below 250 MW
#   Pipe inner diameter     0.05-1.2 m from a standard size list; return mains are
#                           0.4 times the steam main they run beside
#   Steam velocity          sized for at most 35 m/s, condensate for at most 1.5 m/s
#   Darcy friction factor   about 0.01-0.03 (rough commercial steel, 5 % spread)
#   Heat-loss coefficient   1.0-2.0 W/(m2 K) on the pipe surface
#   Condensate pumps        150-300 kPa at buildings, 400 kPa on the plant return
#   Plant rating            at least 1.35 times the total design heat
#   Boiler ramp limit       25 % of rating per hour

"""
Building footprint `(width_m, depth_m)` that fits around every load junction without
overlapping another building.
"""
const BUILDING_FOOTPRINT_M = (70.0, 50.0)

const _LOAD_TYPES = ("lab", "housing", "classroom", "critical")
const _NAME_PREFIX = Dict("lab" => "Lab", "housing" => "Housing", "classroom" => "Classroom",
                          "critical" => "Clinic")
const _HEAT_RANGE_W = Dict("lab" => (1.5e6, 3.5e6), "housing" => (0.6e6, 1.6e6),
                           "classroom" => (0.5e6, 1.4e6), "critical" => (2.5e6, 4.5e6))
const _PRIORITY = Dict("critical" => 100.0, "lab" => 10.0, "housing" => 5.0, "classroom" => 1.0)

const _SCALED_MAX_TOTAL_HEAT_W = 250e6
const _RATING_MARGIN = 1.35
const _LATENT_HEAT_J_PER_KG = 2.0e6
const _ROUGHNESS_M = 4.6e-5
const _WATER_DRAW_OFFSET_M = 7.0

const _PIPE_SIZES_M = [0.05, 0.065, 0.08, 0.10, 0.125, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45,
                       0.50, 0.60, 0.70, 0.80, 0.90, 1.00, 1.20]

# Sizing data for the steam side. Return laterals are sized for condensate velocity and
# return mains follow the steam mains at a fixed diameter ratio.
const _STEAM_SIZING = (density = 4.5, velocity = 35.0, budget_Pa = 2.0e5, min_main_m = 0.20)
const _WATER_DENSITY = 950.0
const _WATER_VELOCITY = 1.5
const _WATER_DIAMETER_RATIO = 0.4

# Block types of the demo campus, south to north (rows) and west to east (columns).
const _DEMO_BLOCKS = ["housing" "classroom" "critical" "housing";
                      "housing" "classroom" "classroom" "lab";
                      "housing" "lab" "lab" "lab"]
# Most of one block stays open as the central quad.
const _DEMO_QUAD_BLOCK = (2, 2)
const _DEMO_QUAD_KEEP = (0, 0)

_fully_rough_friction(d) = 0.25 / log10(_ROUGHNESS_M / (3.7 * d))^2

function _snap_size(d::Float64)
    for size in _PIPE_SIZES_M
        size >= d && return size
    end
    return _PIPE_SIZES_M[end]
end

# Mutable pipe description used while the network is assembled.
mutable struct _DraftPipe
    from::Int
    to::Int
    length_m::Float64
    role::Symbol        # :feeder, :main or :lateral
    diameter_m::Float64
    friction::Float64
    heat_loss::Float64
    boost_Pa::Float64
end

_draft(from, to, length_m, role) = _DraftPipe(from, to, length_m, role, 0.0, 0.0, 0.0, 0.0)

# Longest route from the plant, in metres, along a breadth-first tree.
function _longest_route(n::Int, draft::Vector{_DraftPipe}, root::Int)
    first, other, edge = _adjacency(n, [p.from for p in draft], [p.to for p in draft])
    dist = fill(-1.0, n)
    dist[root] = 0.0
    queue = [root]
    head = 1
    while head <= length(queue)
        j = queue[head]
        head += 1
        for k in first[j]:(first[j + 1] - 1)
            i = other[k]
            if dist[i] < 0
                dist[i] = dist[j] + draft[edge[k]].length_m
                push!(queue, i)
            end
        end
    end
    return maximum(dist)
end

_sizing_resistance(p::_DraftPipe, density) =
    8 * _fully_rough_friction(p.diameter_m) * p.length_m / (pi^2 * density * p.diameter_m^5)

# Size one side for the design flow. Velocity limits set a first estimate; diameters
# then grow until the design pressure drop fits the budget. Mains carry a flow margin
# so they can take rerouted flow during an outage, and each feeder can carry the whole
# campus alone.
function _size_side!(draft::Vector{_DraftPipe}, n::Int, root::Int, demand_kg_s::Vector{Float64},
                     sizing)
    total = sum(demand_kg_s)
    injection = -demand_kg_s
    injection[root] += total
    us = [p.from for p in draft]
    vs = [p.to for p in draft]
    for p in draft
        p.diameter_m = p.role == :lateral ? 0.10 : 0.30
    end
    target_gradient = sizing.budget_Pa / _longest_route(n, draft, root)
    for _ in 1:12
        r = [_sizing_resistance(p, sizing.density) for p in draft]
        _, phi = _solve_hydraulics(n, us, vs, r, injection, root)
        for (e, p) in enumerate(draft)
            flow = p.role == :feeder ? total :
                   p.role == :main ? max(1.5 * abs(phi[e]), 0.15 * total) : abs(phi[e])
            d_velocity = sqrt(4 * flow / (pi * sizing.density * sizing.velocity))
            f = _fully_rough_friction(p.diameter_m)
            d_gradient = (8 * f * flow^2 / (pi^2 * sizing.density * target_gradient))^(1 / 5)
            d = p.role == :lateral ? d_velocity : max(d_velocity, d_gradient, sizing.min_main_m)
            p.diameter_m = _snap_size(d)
        end
        r = [_sizing_resistance(p, sizing.density) for p in draft]
        h, _ = _solve_hydraulics(n, us, vs, r, injection, root)
        maximum(abs, h) <= sizing.budget_Pa && return draft
        target_gradient /= 1.5
    end
    return draft
end

function _block_types(rng::SplitMix64, nx::Int, ny::Int, demo::Bool)
    demo && return _DEMO_BLOCKS
    types = Matrix{String}(undef, ny, nx)
    for j in 1:ny, i in 1:nx
        u = _uniform!(rng)
        types[j, i] = u < 0.06 ? "critical" : u < 0.32 ? "lab" : u < 0.66 ? "housing" : "classroom"
    end
    # Every campus has a hospital-like block next to the plant.
    types[1, max(1, div(nx, 2))] = "critical"
    return types
end

# Build a campus with `nx` by `ny` street intersections and `n_loads` buildings.
function _build_campus(nx::Int, ny::Int, n_loads::Int, seed::Integer; demo::Bool = false)
    layout = _stream(seed, 1)
    sizing_rng = _stream(seed, 2)

    # Street grid.
    xs = cumsum([0.0; [_uniform!(layout, 230.0, 300.0) for _ in 1:(nx - 1)]])
    ys = cumsum([0.0; [_uniform!(layout, 180.0, 240.0) for _ in 1:(ny - 1)]])
    street_x = [round(xs[i] + _uniform!(layout, -8.0, 8.0); digits = 1) for i in 1:nx, j in 1:ny]
    street_y = [round(ys[j] + _uniform!(layout, -8.0, 8.0); digits = 1) for i in 1:nx, j in 1:ny]

    # Building slots: (block i, block j, quadrant sx, quadrant sy).
    slots = NTuple{4,Int}[]
    for j in 1:(ny - 1), i in 1:(nx - 1), sy in 0:1, sx in 0:1
        demo && (i, j) == _DEMO_QUAD_BLOCK && (sx, sy) != _DEMO_QUAD_KEEP && continue
        push!(slots, (i, j, sx, sy))
    end
    length(slots) >= n_loads ||
        throw(ArgumentError("A $nx by $ny street grid cannot hold $n_loads buildings."))
    if length(slots) > n_loads
        chosen = sort!(_shuffle!(layout, collect(eachindex(slots)))[1:n_loads])
        slots = slots[chosen]
    end
    block_types = _block_types(layout, nx - 1, ny - 1, demo)

    # Junction ids on one side: plant, then intersections, then buildings.
    n_street = nx * ny
    n_side = 1 + n_street + n_loads
    street_id(i, j) = 1 + (j - 1) * nx + i
    building_id(k) = 1 + n_street + k
    plant_i = max(1, div(nx, 2))
    plant_x = round((street_x[plant_i, 1] + street_x[plant_i + 1, 1]) / 2; digits = 1)
    plant_y = round(minimum(street_y) - 140.0; digits = 1)

    positions = Vector{Tuple{Float64,Float64}}(undef, n_side)
    kinds = Vector{String}(undef, n_side)
    positions[1] = (plant_x, plant_y)
    kinds[1] = "plant"
    for j in 1:ny, i in 1:nx
        positions[street_id(i, j)] = (street_x[i, j], street_y[i, j])
        kinds[street_id(i, j)] = "junction"
    end

    # Buildings, numbered per type.
    counters = Dict(t => 0 for t in _LOAD_TYPES)
    names = String[]
    types = String[]
    heats = Float64[]
    corners = Int[]
    for (k, (i, j, sx, sy)) in enumerate(slots)
        x = xs[i] + (sx == 0 ? 0.25 : 0.75) * (xs[i + 1] - xs[i]) + _uniform!(layout, -5.0, 5.0)
        y = ys[j] + (sy == 0 ? 0.25 : 0.75) * (ys[j + 1] - ys[j]) + _uniform!(layout, -5.0, 5.0)
        positions[building_id(k)] = (round(x; digits = 1), round(y; digits = 1))
        kinds[building_id(k)] = "load"
        type = block_types[j, i]
        counters[type] += 1
        push!(names, string(_NAME_PREFIX[type], " ", lpad(counters[type], 2, '0')))
        push!(types, type)
        low, high = _HEAT_RANGE_W[type]
        push!(heats, _uniform!(layout, low, high))
        push!(corners, street_id(i + sx, j + sy))
    end

    # Large campuses keep the plant plausible by serving many smaller buildings.
    raw_total = sum(heats)
    shrink = (!demo && raw_total > _SCALED_MAX_TOTAL_HEAT_W) ?
             _SCALED_MAX_TOTAL_HEAT_W / raw_total : 1.0
    heats = [round(h * shrink / 1000) * 1000 for h in heats]
    total_heat = sum(heats)

    # Topology shared by both sides, listed in steam-flow direction.
    template = _DraftPipe[]
    function add_pipe!(from, to, role, a, b)
        dx = positions[from][1] - positions[to][1]
        dy = positions[from][2] - positions[to][2]
        length_m = round(hypot(dx, dy) * _uniform!(layout, a, b); digits = 1)
        push!(template, _draft(from, to, length_m, role))
    end
    add_pipe!(1, street_id(plant_i, 1), :feeder, 1.05, 1.15)
    add_pipe!(1, street_id(plant_i + 1, 1), :feeder, 1.05, 1.15)
    for j in 1:ny, i in 1:(nx - 1)
        add_pipe!(street_id(i, j), street_id(i + 1, j), :main, 1.03, 1.10)
    end
    for j in 1:(ny - 1), i in 1:nx
        add_pipe!(street_id(i, j), street_id(i, j + 1), :main, 1.03, 1.10)
    end
    for k in 1:n_loads
        add_pipe!(corners[k], building_id(k), :lateral, 1.10, 1.30)
    end

    demand = zeros(n_side)
    for k in 1:n_loads
        demand[building_id(k)] = heats[k] / _LATENT_HEAT_J_PER_KG
    end

    steam = [_draft(p.from, p.to, p.length_m, p.role) for p in template]
    water = [_draft(p.to, p.from, p.length_m, p.role) for p in template]
    _size_side!(steam, n_side, 1, demand, _STEAM_SIZING)

    for p in steam
        p.friction = round(_fully_rough_friction(p.diameter_m) * _uniform!(sizing_rng, 0.95, 1.05);
                           digits = 5)
        p.heat_loss = round(_uniform!(sizing_rng, 1.0, 2.0); digits = 3)
    end
    for (p, s) in zip(water, steam)
        if p.role == :lateral
            d = sqrt(4 * demand[p.from] / (pi * _WATER_DENSITY * _WATER_VELOCITY))
            p.diameter_m = _snap_size(d)
            p.friction = round(_fully_rough_friction(p.diameter_m) *
                               _uniform!(sizing_rng, 0.95, 1.05); digits = 5)
        else
            # Return mains keep a fixed ratio to the steam main in the same trench, so
            # both sides split flow identically around every loop at every load mix.
            p.diameter_m = round(_WATER_DIAMETER_RATIO * s.diameter_m; digits = 4)
            p.friction = s.friction
        end
        p.heat_loss = round(_uniform!(sizing_rng, 1.0, 2.0); digits = 3)
        # Condensate pumps sit where the flow direction can never change: at each
        # building's receiver and on the return into the plant.
        p.boost_Pa = p.role == :feeder ? 400e3 :
                     p.role == :lateral ? 1000.0 * round(_uniform!(sizing_rng, 150.0, 300.0)) : 0.0
    end

    junctions = Junction[]
    sizehint!(junctions, 2 * n_side)
    for j in 1:n_side
        push!(junctions, Junction(j, "steam", kinds[j], positions[j][1], positions[j][2]))
    end
    for j in 1:n_side
        push!(junctions, Junction(n_side + j, "water", kinds[j],
                                  round(positions[j][1] + _WATER_DRAW_OFFSET_M; digits = 1),
                                  round(positions[j][2] - _WATER_DRAW_OFFSET_M; digits = 1)))
    end

    pipes = Pipe[]
    sizehint!(pipes, 2 * length(steam))
    for p in steam
        push!(pipes, Pipe(length(pipes) + 1, "steam", p.from, p.to, p.length_m, p.diameter_m,
                          p.friction, p.heat_loss, 0.0, true))
    end
    for p in water
        push!(pipes, Pipe(length(pipes) + 1, "water", n_side + p.from, n_side + p.to, p.length_m,
                          p.diameter_m, p.friction, p.heat_loss, p.boost_Pa, true))
    end

    loads = [Load(k, names[k], types[k], building_id(k), n_side + building_id(k), heats[k],
                  _PRIORITY[types[k]]) for k in 1:n_loads]

    rating = ceil(_RATING_MARGIN * total_heat / 5e6) * 5e6
    n_boilers = rating >= 200e6 ? 6 : 4
    plant = Plant(1, n_side + 1, rating, n_boilers, 0.25 * rating, 463.0, 1.0e6, 2.5e5)

    return validate_network(orient_network(CampusNetwork(junctions, pipes, loads, plant)))
end

"""
    demo_campus(; seed = 1) -> CampusNetwork

The demo network of the fictional Example University: 45 buildings on a 5 by 4 street
grid, 132 junctions over both sides, with looped mains and a central quad. The seed
changes geometry and building sizes but never the counts.
"""
demo_campus(; seed::Integer = 1) = _build_campus(5, 4, 45, seed; demo = true)

"""
    scaled_campus(n_junctions; seed = 1) -> CampusNetwork

A campus with exactly `n_junctions` junctions over both sides. `n_junctions` must be
even, because the two sides mirror each other, and at least 40. Building sizes shrink
on large campuses so that the total design heat stays at or below 250 MW.
"""
function scaled_campus(n_junctions::Integer; seed::Integer = 1)
    iseven(n_junctions) ||
        throw(ArgumentError("n_junctions must be even because both sides mirror each other; got $n_junctions."))
    n_junctions >= 40 || throw(ArgumentError("n_junctions must be at least 40; got $n_junctions."))
    per_side = div(Int(n_junctions), 2) - 1    # junctions other than the plant
    target = max(6, round(Int, 0.31 * per_side))
    ny = max(2, floor(Int, sqrt(0.8 * target)))
    nx = max(3, ceil(Int, target / ny))
    while true
        n_loads = per_side - nx * ny
        n_loads >= 1 ||
            throw(ArgumentError("n_junctions = $n_junctions is too small for a street grid."))
        n_loads <= 4 * (nx - 1) * (ny - 1) && return _build_campus(nx, ny, n_loads, seed)
        nx += 1
    end
end

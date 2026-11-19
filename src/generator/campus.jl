# Synthetic campus layout and pipe sizing for the fictional Example University.
#
# Layout (see `_campus_layout`). The plant sits on the south edge. Two trunk mains leave it
# along a header, turn north at the corners and pass a series of branch stations; the trunks
# taper because every main is sized for its own flow. Branch mains run east-west from the
# stations, and buildings hang off the branches by short laterals. Two cross-ties join the
# trunks around an open quad lined with classrooms and close the two loops. The first tie feeds
# a short clinic spur toward the plant from its middle, so the clinics get steam from both
# trunks; the second feeds a north spine to an outlying housing group. On larger campuses the
# east trunk detours around the lab district as a ring, and the outermost branches start with a
# long untapped run to outlying buildings. Everything else is a tree. Mains run straight with
# bends at the corners and one jog in the west trunk, and no pipe crosses another pipe or a
# building footprint. Building sizes are drawn until no looped main changes direction over the
# load mixes of a year. The return network mirrors the steam network and is drawn with a small
# offset.
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
#   Heat-loss coefficient   steam 0.35 W/(m2 K) and condensate 0.175 W/(m2 K) on the pipe
#                           surface, each with a 10 % spread; small steam pipes lose at least
#                           0.20 W/(m K) per metre. See `_STEAM_HEAT_LOSS_U`.
#   Condensate pumps        150-300 kPa at buildings, 400 kPa on the plant return
#   Plant rating            at least 1.35 times the total design heat, in 5 MW steps
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

# Overall heat-transfer coefficients, W/(m2 K) of pipe surface. Heat loss in the model is sensible
# cooling only, so the steam that reaches a building must stay above 100 C on superheat alone. These
# values keep lightly loaded mains within that limit at part load. Larger values force the plant to
# overfire and release excess heat at the buildings (see docs/model-notes.md).
const _STEAM_HEAT_LOSS_U = 0.35
const _WATER_HEAT_LOSS_U = 0.175
const _HEAT_LOSS_SPREAD = 0.10
# Insulation on a small pipe cannot be arbitrarily thick, so its loss per metre has a lower limit.
const _STEAM_MIN_LINE_LOSS_W_PER_MK = 0.20

_steam_heat_loss_u(d) = max(_STEAM_HEAT_LOSS_U, _STEAM_MIN_LINE_LOSS_W_PER_MK / (pi * d))

# Every main can carry at least 15 % of the campus flow during an outage, up to this flow. Without
# the cap, large campuses get oversized mains that run nearly empty and cool the steam too far.
const _MAIN_FLOW_FLOOR_KG_S = 6.0

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
                   p.role == :main ? max(1.5 * abs(phi[e]), min(0.15 * total, _MAIN_FLOW_FLOOR_KG_S)) :
                   abs(phi[e])
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

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

# Geometry ranges in metres. Mains run east-west or north-south; laterals leave them at right angles.
const _TAP_FIRST_M = (90.0, 110.0)          # station to the first tap of a branch
const _TAP_SPACING_EW_M = (82.0, 105.0)     # between taps on an east-west main
const _TAP_SPACING_NS_M = (62.0, 85.0)      # between taps on a north-south main
const _LATERAL_NS_M = (42.0, 52.0)          # lateral to a building north or south of its main
const _LATERAL_EW_M = (50.0, 60.0)          # lateral to a building east or west of its main
const _LATERAL_AHEAD_M = (72.0, 82.0)       # lateral that continues past the last tap
const _FIRST_STATION_M = (225.0, 255.0)     # plant header to the first cross-tie
const _SPUR_FIRST_M = (110.0, 115.0)        # first cross-tie to the first tap of the clinic spur
const _SPINE_CLEARANCE_M = 130.0            # north spine taps start this far past the last station
const _QUAD_M = (300.0, 340.0)              # between the two cross-ties
const _QUAD_WIDE_M = (345.0, 375.0)         # the same, with a branch station halfway
const _STATION_SPACING_M = (185.0, 260.0)   # between branch stations farther out
const _DEAD_END_RUN_M = (220.0, 300.0)      # untapped run toward an outlying group of buildings
const _JOG_M = (35.0, 55.0)                 # sideways jog of the west trunk
const _JOG_RISE_M = 100.0
const _RING_CORNER_M = (85.0, 100.0)        # last tap of a ring side to the ring corner
# Half a footprint plus a clear margin, so inner branches stop short of the middle of the campus.
const _INNER_CLEARANCE_M = 60.0

# Load counts of the demo campus, which also set the mix of scaled campuses.
const _DEMO_LOAD_COUNTS = ("critical" => 4, "classroom" => 9, "housing" => 16, "lab" => 16)

# A possible building position on a lateral from main node `tap`. Slots of lower `rank` are filled
# first; every tap at the end of a main has one slot of rank 1, so no main ends without a building.
# Slots above `_LAST_RANK` stay empty: south of the first cross-tie is kept for the clinic spur.
const _LAST_RANK = 3
struct _Slot
    tap::Int
    x::Float64
    y::Float64
    rank::Int
    zone::Symbol
end

# A tree branch off a trunk. `station` is 0 for the plant header, 1 and 2 for the cross-tie
# stations, -1 for the station halfway between them, and 3 or more for stations farther out.
struct _BranchSpec
    side::Symbol        # :west or :east trunk
    station::Int
    kind::Symbol        # :outer, :inner or :header
    min_taps::Int
    max_taps::Int
    weight::Float64
    dead_end::Bool      # starts with a long untapped run
end

mutable struct _Layout
    x::Vector{Float64}                       # main nodes; node 1 is the plant
    y::Vector{Float64}
    pipes::Vector{Tuple{Int,Int,Symbol}}     # (upstream, downstream, role)
    slots::Vector{_Slot}
    quad::Tuple{Float64,Float64}
end

function _node!(L::_Layout, x, y)
    push!(L.x, round(x; digits = 1))
    push!(L.y, round(y; digits = 1))
    return length(L.x)
end

# Taps of inner branches, which must fit in half the width between the trunks.
_inner_taps(K::Int) = K <= 2 ? 0 : min(2, max(1, round(Int, K / 2)))

# Branch stations per trunk for a campus with `per_side` junctions on each side.
_stations_for(per_side::Int) = max(2, round(Int, sqrt(per_side / 9)))

function _branch_specs(rng::SplitMix64, K::Int)
    specs = _BranchSpec[]
    weight() = _uniform!(rng, 0.6, 1.5)
    many = typemax(Int)
    # A main junction without a building must not become the dead end of a main when one pipe is
    # out, because a main that serves nothing has no defined flow. So the top stations of a small
    # campus always carry a branch, and corners without a branch carry a building (see below).
    if K == 2
        for (side, station, required) in ((:west, 2, 1), (:east, 2, 1), (:west, 1, 0), (:east, 1, 0))
            push!(specs, _BranchSpec(side, station, :outer, required, many, weight(), false))
        end
        push!(specs, _BranchSpec(:west, 0, :header, 0, many, 0.6 * weight(), false))
        push!(specs, _BranchSpec(:east, 0, :header, 0, many, 0.6 * weight(), false))
        return specs
    end
    # Required branches first, then optional ones in priority order.
    push!(specs, _BranchSpec(:west, 1, :outer, 1, many, weight(), false))
    push!(specs, _BranchSpec(:west, 2, :outer, 1, many, weight(), false))
    for k in 3:K
        push!(specs, _BranchSpec(:west, k, :outer, 1, many, weight(), k == K))
        push!(specs, _BranchSpec(:east, k, :outer, 1, many, weight(), k == K))
    end
    m_in = _inner_taps(K)
    for k in 3:K
        push!(specs, _BranchSpec(:west, k, :inner, 0, m_in, 0.5 * weight(), false))
        push!(specs, _BranchSpec(:east, k, :inner, 0, m_in, 0.5 * weight(), false))
    end
    push!(specs, _BranchSpec(:west, 0, :header, 0, many, 0.6 * weight(), false))
    push!(specs, _BranchSpec(:east, 0, :header, 0, many, 0.6 * weight(), false))
    push!(specs, _BranchSpec(:west, -1, :outer, 0, many, weight(), false))
    # The north spine leaves the middle of the second cross-tie. Its buildings are a large sink
    # where the flows from both trunks meet, which keeps the flow direction in that tie fixed.
    pushfirst!(specs, _BranchSpec(:center, 2, :spine, 2, many, 2.0 * weight(), true))
    return specs
end

# Share `T` taps among the branches: the required minimum, then one tap per optional branch in
# priority order, then the rest by weight. Returns `nothing` when `T` is below the minimum.
function _allocate_taps(specs::Vector{_BranchSpec}, T::Int)
    taps = [s.min_taps for s in specs]
    left = T - sum(taps)
    left < 0 && return nothing
    for (i, s) in enumerate(specs)
        left == 0 && break
        if taps[i] == 0 && s.max_taps > 0
            taps[i] = 1
            left -= 1
        end
    end
    while left > 0
        best, score = 0, Inf
        for (i, s) in enumerate(specs)
            taps[i] < s.max_taps || continue
            v = (taps[i] + 1) / s.weight
            if v < score
                best, score = i, v
            end
        end
        best == 0 && return nothing
        taps[best] += 1
        left -= 1
    end
    return taps
end

const _NORTH = (0.0, 1.0)
const _SOUTH = (0.0, -1.0)
const _EAST = (1.0, 0.0)
const _WEST = (-1.0, 0.0)

# Building positions beside main node `tap`, one per unit vector in `sides`.
function _side_slots!(L::_Layout, rng, tap, sides, ranks, zones)
    for (side, rank, zone) in zip(sides, ranks, zones)
        offset = side[2] == 0 ? _uniform!(rng, _LATERAL_EW_M...) : _uniform!(rng, _LATERAL_NS_M...)
        push!(L.slots, _Slot(tap, round(L.x[tap] + side[1] * offset; digits = 1),
                             round(L.y[tap] + side[2] * offset; digits = 1), rank, zone))
    end
end

# A straight tree branch from `start` in direction `dir` with `ntaps` taps. Each tap serves a
# building on either side; the last one can also serve a building straight ahead.
function _branch!(L::_Layout, rng, start, dir, ntaps; extra_run = 0.0, sides = nothing,
                  ahead = true, zone = :west)
    sides = something(sides, dir[2] == 0 ? [_NORTH, _SOUTH] : [_EAST, _WEST])
    spacing = dir[2] == 0 ? _TAP_SPACING_EW_M : _TAP_SPACING_NS_M
    prev = start
    dist = _uniform!(rng, _TAP_FIRST_M...) + extra_run
    for t in 1:ntaps
        t > 1 && (dist += _uniform!(rng, spacing...))
        tap = _node!(L, L.x[start] + dir[1] * dist, L.y[start] + dir[2] * dist)
        push!(L.pipes, (prev, tap, :main))
        prev = tap
        order = length(sides) == 2 && _uniform!(rng) < 0.5 ? reverse(sides) : sides
        _side_slots!(L, rng, tap, order, [1, 3][1:length(order)], fill(zone, length(order)))
        if t == ntaps && ahead
            offset = _uniform!(rng, _LATERAL_AHEAD_M...)
            push!(L.slots, _Slot(tap, round(L.x[tap] + dir[1] * offset; digits = 1),
                                 round(L.y[tap] + dir[2] * offset; digits = 1), 2, zone))
        end
    end
    return prev
end

# A cross-tie between stations `a` and `b` on the two trunks, with buildings on both sides. With
# `hub` set to `_NORTH` or `_SOUTH`, the middle tap leaves that side free for a branch and is
# returned; otherwise the result is 0. `ranks` gives the slot ranks south and north of the tie.
function _cross_tie!(L::_Layout, rng, a, b, south_zone, north_zone; hub = nothing, ranks = (1, 2),
                     max_taps = typemax(Int))
    lo = L.x[a] + _uniform!(rng, _TAP_FIRST_M...)
    hi = L.x[b] - _uniform!(rng, _TAP_FIRST_M...)
    span = hi - lo
    n = clamp(round(Int, span / 100) + 1, 1, max_taps)
    while n > 1 && span / (n - 1) < _TAP_SPACING_EW_M[1]
        n -= 1
    end
    hub === nothing || iseven(n) && (n -= 1)
    middle = (n + 1) ÷ 2
    # Taps shift a little along the tie where the spacing leaves room.
    jitter = n == 1 ? 0.0 : clamp((span / (n - 1) - _TAP_SPACING_EW_M[1] - 2.0) / 2, 0.0, 12.0)
    prev, hub_tap = a, 0
    for t in 1:n
        x = n == 1 ? (lo + hi) / 2 : lo + span * (t - 1) / (n - 1)
        is_hub = hub !== nothing && t == middle
        is_hub || (x += _uniform!(rng, -jitter, jitter))
        tap = _node!(L, x, L.y[a])
        push!(L.pipes, (prev, tap, :main))
        prev = tap
        if is_hub
            hub_tap = tap
            side, zone = hub == _NORTH ? (_SOUTH, south_zone) : (_NORTH, north_zone)
            _side_slots!(L, rng, tap, [side], [1], [zone])
        else
            _side_slots!(L, rng, tap, [_SOUTH, _NORTH], [ranks...], [south_zone, north_zone])
        end
    end
    push!(L.pipes, (prev, b, :main))
    return hub_tap
end

# The clinic spur: a short main south from the first cross-tie toward the plant, with buildings on
# both sides of each tap.
function _clinic_spur!(L::_Layout, rng, hub, n_taps)
    prev = hub
    y = L.y[hub] - _uniform!(rng, _SPUR_FIRST_M...)
    for t in 1:n_taps
        t > 1 && (y -= _uniform!(rng, _TAP_SPACING_NS_M[1], _TAP_SPACING_NS_M[1] + 6.0))
        tap = _node!(L, L.x[hub], y)
        push!(L.pipes, (prev, tap, :main))
        prev = tap
        _side_slots!(L, rng, tap, [_WEST, _EAST], [1, 1], [:clinic, :clinic])
    end
end

# A ring main east of the east trunk, from station `a` out and back to station `b` farther north.
# Buildings inside the ring are filled before the ones outside.
function _ring!(L::_Layout, rng, a, b, n_taps)
    x0, ya, yb = L.x[a], L.y[a], L.y[b]
    prev = a
    dist = _uniform!(rng, _TAP_FIRST_M...)
    for t in 1:n_taps
        t > 1 && (dist += _uniform!(rng, _TAP_SPACING_EW_M...))
        tap = _node!(L, x0 + dist, ya)
        push!(L.pipes, (prev, tap, :main))
        prev = tap
        _side_slots!(L, rng, tap, [_NORTH, _SOUTH], [1, 3], [:east, :east])
    end
    xr = x0 + dist + _uniform!(rng, _RING_CORNER_M...)
    corner = _node!(L, xr, ya)
    push!(L.pipes, (prev, corner, :main))
    _side_slots!(L, rng, corner, [_EAST], [1], [:east])
    prev = corner
    y = ya + _uniform!(rng, 110.0, 120.0)
    while y <= yb - 110.0
        tap = _node!(L, xr, y)
        push!(L.pipes, (prev, tap, :main))
        prev = tap
        _side_slots!(L, rng, tap, [_WEST, _EAST], [1, 3], [:east, :east])
        y += _uniform!(rng, _TAP_SPACING_NS_M...)
    end
    corner = _node!(L, xr, yb)
    push!(L.pipes, (prev, corner, :main))
    _side_slots!(L, rng, corner, [_EAST], [1], [:east])
    prev = corner
    lo = x0 + _uniform!(rng, _TAP_FIRST_M...)
    hi = xr - _uniform!(rng, _RING_CORNER_M...)
    n = n_taps
    while n > 1 && (hi - lo) / (n - 1) < _TAP_SPACING_EW_M[1]
        n -= 1
    end
    for t in n:-1:1
        tap = _node!(L, n == 1 ? (lo + hi) / 2 : lo + (hi - lo) * (t - 1) / (n - 1), yb)
        push!(L.pipes, (prev, tap, :main))
        prev = tap
        _side_slots!(L, rng, tap, [_SOUTH, _NORTH], [1, 3], [:east, :east])
    end
    push!(L.pipes, (prev, b, :main))
end

# Main nodes, mains and building slots for `K` stations per trunk and `taps[i]` taps on branch
# `specs[i]`. The plant sits on the south edge. A west and an east trunk leave it along a header,
# turn north and pass the stations. Two cross-ties join the trunks around the central quad, and for
# `K >= 3` the east trunk runs as a ring around the lab district. Every other branch is a tree.
function _campus_layout(seed::Integer, K::Int, specs::Vector{_BranchSpec}, taps::Vector{Int})
    rng = _stream(seed, 4)
    L = _Layout([0.0], [0.0], Tuple{Int,Int,Symbol}[], _Slot[], (0.0, 0.0))
    count_of(side, station, kind) =
        sum((n for (s, n) in zip(specs, taps) if (s.side, s.station, s.kind) == (side, station, kind)); init = 0)

    m_in = _inner_taps(K)
    gap = K == 2 ? _uniform!(rng, 300.0, 340.0) :
          2 * (_TAP_FIRST_M[2] + (m_in - 1) * _TAP_SPACING_EW_M[2] + _INNER_CLEARANCE_M) +
          _uniform!(rng, 40.0, 80.0)
    xw = -gap * _uniform!(rng, 0.42, 0.52)
    xe = xw + gap
    has_mid = count_of(:west, -1, :outer) > 0
    # Larger campuses have more clinics, so the spur and the room for it grow.
    n_spur = max(2, K - 2)
    y1 = _uniform!(rng, _FIRST_STATION_M...) + (n_spur - 2) * (_TAP_SPACING_NS_M[1] + 6.0)
    y2 = y1 + _uniform!(rng, (has_mid ? _QUAD_WIDE_M : _QUAD_M)...)
    L.quad = ((xw + xe) / 2, (y1 + y2) / 2)

    station = Dict{Tuple{Symbol,Int},Int}()
    station[(:west, 0)] = _node!(L, xw, 0.0)
    station[(:east, 0)] = _node!(L, xe, 0.0)
    push!(L.pipes, (1, station[(:west, 0)], :feeder))
    push!(L.pipes, (1, station[(:east, 0)], :feeder))

    # West trunk.
    prev = station[(:west, 0)]
    station[(:west, 1)] = _node!(L, xw, y1)
    push!(L.pipes, (prev, station[(:west, 1)], :main))
    prev = station[(:west, 1)]
    if has_mid
        station[(:west, -1)] = _node!(L, xw, y1 + (y2 - y1) / 2 + _uniform!(rng, -5.0, 5.0))
        push!(L.pipes, (prev, station[(:west, -1)], :main))
        prev = station[(:west, -1)]
    end
    station[(:west, 2)] = _node!(L, xw, y2)
    push!(L.pipes, (prev, station[(:west, 2)], :main))
    prev = station[(:west, 2)]
    if K >= 3
        x = xw - _uniform!(rng, _JOG_M...)
        jog = _node!(L, x, y2 + _JOG_RISE_M)
        push!(L.pipes, (prev, jog, :main))
        prev, y = jog, y2
        for k in 3:K
            y += _uniform!(rng, _STATION_SPACING_M...)
            station[(:west, k)] = _node!(L, x, y)
            push!(L.pipes, (prev, station[(:west, k)], :main))
            prev = station[(:west, k)]
        end
    end

    # East trunk. On larger campuses it loops around the lab district between the two cross-tie
    # stations instead of running straight.
    prev = station[(:east, 0)]
    station[(:east, 1)] = _node!(L, xe, y1)
    push!(L.pipes, (prev, station[(:east, 1)], :main))
    station[(:east, 2)] = _node!(L, xe, y2)
    if K >= 3
        _ring!(L, rng, station[(:east, 1)], station[(:east, 2)], max(2, m_in))
    else
        push!(L.pipes, (station[(:east, 1)], station[(:east, 2)], :main))
    end
    prev, y = station[(:east, 2)], y2
    for k in 3:K
        y += _uniform!(rng, _STATION_SPACING_M...)
        station[(:east, k)] = _node!(L, xe, y)
        push!(L.pipes, (prev, station[(:east, k)], :main))
        prev = station[(:east, k)]
    end

    # Cross-ties. The first one feeds the clinic spur from both trunks, the second the north spine.
    # A small campus has one tap on each tie.
    max_taps = K >= 3 ? typemax(Int) : 1
    hub1 = _cross_tie!(L, rng, station[(:west, 1)], station[(:east, 1)], :tie1_south, :tie1_north;
                       hub = K >= 3 ? _SOUTH : nothing, ranks = K >= 3 ? (4, 1) : (1, 2), max_taps)
    hub1 > 0 && _clinic_spur!(L, rng, hub1, n_spur)
    station[(:center, 2)] = _cross_tie!(L, rng, station[(:west, 2)], station[(:east, 2)],
                                        :tie2_south, :tie2_north; hub = K >= 3 ? _NORTH : nothing,
                                        max_taps)
    top = maximum(L.y[station[(side, K)]] for side in (:west, :east))

    # A header corner without a branch serves one building beyond the corner.
    for (side, dir) in ((:west, _WEST), (:east, _EAST))
        count_of(side, 0, :header) == 0 &&
            _side_slots!(L, rng, station[(side, 0)], [dir], [1], [side])
    end

    # Tree branches.
    for (s, n) in zip(specs, taps)
        n == 0 && continue
        start = station[(s.side, s.station)]
        outward = s.side == :west ? _WEST : _EAST
        if s.kind == :spine
            run = max(0.0, top + _SPINE_CLEARANCE_M - L.y[start] - _TAP_FIRST_M[2])
            _branch!(L, rng, start, _NORTH, n; extra_run = run, zone = :north)
        elseif s.kind == :header
            _branch!(L, rng, start, outward, n; sides = [_NORTH], zone = s.side)
        elseif s.kind == :inner
            _branch!(L, rng, start, (-outward[1], 0.0), n; ahead = false, zone = :central)
        elseif s.dead_end
            # A long untapped run out from the last station, then north to an outlying group.
            bend = _node!(L, L.x[start] + outward[1] * _uniform!(rng, _DEAD_END_RUN_M...), L.y[start])
            push!(L.pipes, (start, bend, :main))
            _branch!(L, rng, bend, _NORTH, n; extra_run = 15.0, zone = s.side)
        else
            _branch!(L, rng, start, outward, n; zone = s.side)
        end
    end
    return L
end

# Which slots get a building: rank 1 first, then rank 2, then rank 3, in random order within a rank.
function _choose_slots(rng::SplitMix64, slots::Vector{_Slot}, n_loads::Int)
    order = Int[]
    for rank in 1:_LAST_RANK
        append!(order, _shuffle!(rng, [i for (i, s) in enumerate(slots) if s.rank == rank]))
    end
    return sort!(order[1:n_loads])
end

# Building types by district: clinics on the first cross-tie nearest the plant, classrooms around
# the quad, housing to the west and labs to the east.
function _assign_types(slots::Vector{_Slot}, chosen::Vector{Int}, counts, quad)
    type = Dict{Int,String}()
    free = copy(chosen)
    function claim!(n, t, primary, key)
        ranked = vcat(sort([i for i in free if slots[i].zone in primary]; by = key),
                      sort([i for i in free if !(slots[i].zone in primary)]; by = key))
        for i in ranked[1:n]
            type[i] = t
        end
        filter!(i -> !haskey(type, i), free)
    end
    claim!(counts["critical"], "critical", (:clinic, :tie1_south),
           i -> (slots[i].zone != :clinic, hypot(slots[i].x, slots[i].y), i))
    claim!(counts["classroom"], "classroom", (:tie1_north, :tie2_south),
           i -> (hypot(slots[i].x - quad[1], slots[i].y - quad[2]), i))
    claim!(counts["housing"], "housing", (), i -> (slots[i].x, slots[i].y, i))
    for i in free
        type[i] = "lab"
    end
    return [type[i] for i in chosen]
end

function _load_counts(n_loads::Int, demo::Bool)
    demo && return Dict(_DEMO_LOAD_COUNTS)
    total = sum(last, _DEMO_LOAD_COUNTS)
    critical = max(1, round(Int, n_loads * 4 / total))
    classroom = max(1, round(Int, n_loads * 9 / total))
    housing = max(1, round(Int, n_loads * 16 / total))
    return Dict("critical" => critical, "classroom" => classroom, "housing" => housing,
                "lab" => n_loads - critical - classroom - housing)
end

# The smallest number of branch taps that fits the requested size. With `n_loads` given, that is
# the first layout with enough building slots; with `per_side` given, it is the first layout in
# which every remaining junction can be a building.
function _plan_campus(seed::Integer, K::Int; n_loads = nothing, per_side = nothing)
    specs = _branch_specs(_stream(seed, 5), K)
    for T in 0:100_000
        taps = _allocate_taps(specs, T)
        taps === nothing && continue
        L = _campus_layout(seed, K, specs, taps)
        # Every slot of rank 1 must get its building.
        loads = n_loads === nothing ? per_side - length(L.x) : n_loads
        loads < count(s -> s.rank == 1, L.slots) && return nothing
        loads <= count(s -> s.rank <= _LAST_RANK, L.slots) && return (L, loads)
    end
    return nothing
end

# Design heat by building. A stratified draw within each type's range keeps the campus total near
# the mean of the ranges, so the plant rating does not jump with the seed. Large campuses keep the
# plant plausible by serving many smaller buildings.
function _draw_heats(rng::SplitMix64, types::Vector{String}, demo::Bool)
    heats = zeros(length(types))
    for t in _LOAD_TYPES
        members = findall(==(t), types)
        isempty(members) && continue
        strata = _shuffle!(rng, collect(0:(length(members) - 1)))
        low, high = _HEAT_RANGE_W[t]
        for (k, m) in enumerate(members)
            heats[m] = low + (high - low) * (strata[k] + _uniform!(rng)) / length(members)
        end
    end
    raw_total = sum(heats)
    shrink = (!demo && raw_total > _SCALED_MAX_TOTAL_HEAT_W) ?
             _SCALED_MAX_TOTAL_HEAT_W / raw_total : 1.0
    return [round(h * shrink / 1000) * 1000 for h in heats]
end

# Draws of building sizes tried, and the smallest flow a looped main must keep in its design
# direction, as a share of the plant flow, over the load mixes below.
const _SIZE_DRAWS = 40
const _DIRECTION_MARGIN = 0.004
# Outdoor conditions (0 at the balance point, 1 at design) and (hour of day, day of week) pairs
# that span the load mixes of `generate_profiles`.
const _MIX_WEATHER = (0.0, 0.3, 0.6, 1.0)
const _MIX_HOURS = ((3, 0), (7, 0), (13, 0), (19, 0), (3, 5), (13, 5))

# Smallest flow, as a share of the plant flow, that a looped main keeps in one direction over the
# load mixes; negative when some main changes direction.
function _direction_margin(steam::Vector{_DraftPipe}, n::Int, heats, types, junction)
    us = [p.from for p in steam]
    vs = [p.to for p in steam]
    marked = fill(false, n)
    marked[junction] .= true
    loop = _loop_edges(n, us, vs, 1, marked)
    any(loop) || return Inf
    r = [_sizing_resistance(p, _STEAM_SIZING.density) for p in steam]
    lo = fill(Inf, length(steam))
    hi = fill(-Inf, length(steam))
    mixes = [(1.0, nothing); [(w, h) for w in _MIX_WEATHER for h in _MIX_HOURS]]
    for (w, hour) in mixes
        injection = zeros(n)
        for (k, t) in enumerate(types)
            base = _BASE_FRACTION[t]
            pattern = hour === nothing ? 1.0 : _pattern(t, hour...)
            injection[junction[k]] = -heats[k] * (base + (1 - base) * w) * pattern
        end
        injection ./= -sum(injection)
        injection[1] += 1.0
        _, phi = _solve_hydraulics(n, us, vs, r, injection, 1)
        lo .= min.(lo, phi)
        hi .= max.(hi, phi)
    end
    margin = Inf
    for e in findall(loop)
        m = lo[e] > 0 ? lo[e] : hi[e] < 0 ? -hi[e] : -min(hi[e], -lo[e])
        margin = min(margin, m)
    end
    return margin
end

# Build a campus on a planned layout with `n_loads` buildings.
function _build_campus(L::_Layout, n_loads::Int, seed::Integer; demo::Bool = false)
    layout = _stream(seed, 1)
    sizing_rng = _stream(seed, 2)

    chosen = _choose_slots(layout, L.slots, n_loads)
    types = _assign_types(L.slots, chosen, _load_counts(n_loads, demo), L.quad)

    n_main = length(L.x)
    n_side = n_main + n_loads
    building_id(k) = n_main + k
    positions = Vector{Tuple{Float64,Float64}}(undef, n_side)
    kinds = Vector{String}(undef, n_side)
    for j in 1:n_main
        positions[j] = (L.x[j], L.y[j])
        kinds[j] = j == 1 ? "plant" : "junction"
    end
    for (k, i) in enumerate(chosen)
        positions[building_id(k)] = (L.slots[i].x, L.slots[i].y)
        kinds[building_id(k)] = "load"
    end

    counters = Dict(t => 0 for t in _LOAD_TYPES)
    names = map(types) do t
        counters[t] += 1
        string(_NAME_PREFIX[t], " ", lpad(counters[t], 2, '0'))
    end

    # Topology shared by both sides, listed in steam-flow direction.
    template = _DraftPipe[]
    function add_pipe!(from, to, role, a, b)
        dx = positions[from][1] - positions[to][1]
        dy = positions[from][2] - positions[to][2]
        length_m = round(hypot(dx, dy) * _uniform!(layout, a, b); digits = 1)
        push!(template, _draft(from, to, length_m, role))
    end
    for (from, to, role) in L.pipes
        role == :feeder ? add_pipe!(from, to, role, 1.05, 1.15) : add_pipe!(from, to, role, 1.03, 1.10)
    end
    for (k, i) in enumerate(chosen)
        add_pipe!(L.slots[i].tap, building_id(k), :lateral, 1.10, 1.30)
    end

    # Building sizes are drawn until no looped main changes direction over the typical load mixes
    # of a year, because models orient every pipe once along the design flow. The draw with the
    # largest margin is kept if none reaches the target.
    best = nothing
    for attempt in 1:_SIZE_DRAWS
        heats = _draw_heats(_stream(seed, 10 + attempt), types, demo)
        demand = zeros(n_side)
        for k in 1:n_loads
            demand[building_id(k)] = heats[k] / _LATENT_HEAT_J_PER_KG
        end
        steam = [_draft(p.from, p.to, p.length_m, p.role) for p in template]
        _size_side!(steam, n_side, 1, demand, _STEAM_SIZING)
        margin = _direction_margin(steam, n_side, heats, types, building_id.(1:n_loads))
        if best === nothing || margin > best.margin
            best = (; heats, demand, steam, margin)
        end
        margin >= _DIRECTION_MARGIN && break
    end
    (; heats, demand, steam) = best
    total_heat = sum(heats)
    water = [_draft(p.to, p.from, p.length_m, p.role) for p in template]

    for p in steam
        p.friction = round(_fully_rough_friction(p.diameter_m) * _uniform!(sizing_rng, 0.95, 1.05);
                           digits = 5)
        p.heat_loss = round(_steam_heat_loss_u(p.diameter_m) *
                            _uniform!(sizing_rng, 1 - _HEAT_LOSS_SPREAD, 1 + _HEAT_LOSS_SPREAD); digits = 4)
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
        p.heat_loss = round(_WATER_HEAT_LOSS_U *
                            _uniform!(sizing_rng, 1 - _HEAT_LOSS_SPREAD, 1 + _HEAT_LOSS_SPREAD); digits = 4)
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

The demo network of the fictional Example University: 45 buildings on a trunk-and-branch steam
network with two loops, a central quad, a clinic spur and three long dead-end runs, 166
junctions over both sides. The seed changes geometry and building sizes but never the load
counts.
"""
function demo_campus(; seed::Integer = 1)
    n_loads = sum(last, _DEMO_LOAD_COUNTS)
    plan = _plan_campus(seed, 3; n_loads)
    plan === nothing && error("No demo layout fits $n_loads buildings.")
    return _build_campus(plan[1], plan[2], seed; demo = true)
end

"""
    scaled_campus(n_junctions; seed = 1) -> CampusNetwork

A campus with exactly `n_junctions` junctions over both sides, laid out by the same
trunk, branch and loop rule as the demo campus. `n_junctions` must be even, because the two
sides mirror each other, and at least 40. Building sizes shrink on large campuses so that the
total design heat stays at or below 250 MW.
"""
function scaled_campus(n_junctions::Integer; seed::Integer = 1)
    iseven(n_junctions) ||
        throw(ArgumentError("n_junctions must be even because both sides mirror each other; got $n_junctions."))
    n_junctions >= 40 || throw(ArgumentError("n_junctions must be at least 40; got $n_junctions."))
    per_side = div(Int(n_junctions), 2)
    K = _stations_for(per_side)
    while K >= 2
        plan = _plan_campus(seed, K; per_side)
        plan === nothing || return _build_campus(plan[1], plan[2], seed)
        K -= 1
    end
    throw(ArgumentError("n_junctions = $n_junctions is too small for a trunk and branch layout."))
end


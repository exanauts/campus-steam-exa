# Estimating pipe heat-loss and friction coefficients from historian tags.
#
# All data here is synthetic. A "true" network, whose coefficients differ from the nominal ones in a
# seeded way, is simulated hour by hour and sampled into historian-style CSV. The inverse problem is one
# NLP over all hours: every hour has the steady-state physics of the steam model, and the coefficient
# multipliers are decision variables shared by all hours. See docs/site-data.md and docs/model-notes.md.
#
# The physics is written once, in `_add_calibration_physics`, and used by both the forward simulator
# (multipliers are parameters) and the inverse problem (multipliers are variables).

using ExaModels: ExaModels
using LinearAlgebra: Symmetric, eigvals, norm, I as _Identity
using SparseArrays: sparse
using Dates: DateTime, Hour

export CoefficientGroups, coefficient_groups, TrueCoefficients, true_coefficients
export CalibrationTag, curated_tags, select_tags, TAG_COUNTS
export ForwardSimulator, simulate_hours, nominal_heat_profile
export SyntheticHistorian, generate_synthetic_historian
export CalibrationProblem, build_calibration_model, solve_calibration, recovery_errors
export identifiability_analysis

"Synthetic campus used for the calibration demonstration."
calibration_network(; seed::Integer = 1) = scaled_campus(40; seed)

# Coefficient groups -------------------------------------------------------------------------------

"""
    CoefficientGroups

Assigns each pipe to one heat-loss multiplier and one friction multiplier. `names` lists the groups
and `pipe_group[e]` is the group of pipe `e`, the same for both coefficients. Groups with
`estimated[g] == false` are held at their nominal value by the inverse problem.
"""
struct CoefficientGroups
    names::Vector{String}
    pipe_group::Vector{Int}
    estimated::Vector{Bool}
end

"""
    coefficient_groups(net) -> CoefficientGroups

Three groups: steam mains, steam service laterals (pipes that end at a building) and condensate
return pipes. The condensate group is not estimated: pump boost and building condensate temperatures
are not metered, so the tags do not determine its coefficients (see `identifiability_analysis`).
"""
function coefficient_groups(net::CampusNetwork)
    is_load = Dict(j.id => j.kind == "load" for j in net.junctions)
    group = map(net.pipes) do p
        p.side == "water" && return 3
        return (is_load[p.from] || is_load[p.to]) ? 2 : 1
    end
    return CoefficientGroups(["steam mains", "steam laterals", "condensate return"], group, [true, true, false])
end

"""
    TrueCoefficients

The multipliers of the synthetic true network relative to the nominal coefficients:
`loss[e]` and `friction[e]` per pipe, and their length-weighted means per group in `group_loss` and
`group_friction`, which are what the inverse problem is scored against.
"""
struct TrueCoefficients
    loss::Vector{Float64}
    friction::Vector{Float64}
    group_loss::Vector{Float64}
    group_friction::Vector{Float64}
end

"Group multipliers of the true network: heat loss, then friction, in the order of the groups."
const TRUE_GROUP_LOSS = (1.30, 1.15, 0.85)
const TRUE_GROUP_FRICTION = (1.25, 0.90, 1.20)
"Relative standard deviation of the seeded pipe-to-pipe spread around the group multiplier."
const TRUE_PIPE_SPREAD = 0.03

"""
    true_coefficients(net, groups; seed = 1, spread = TRUE_PIPE_SPREAD) -> TrueCoefficients

Seeded multipliers of the true network: each pipe takes its group's value from `TRUE_GROUP_LOSS` and
`TRUE_GROUP_FRICTION`, times `1 + spread * z` with `z` a standard normal clamped to +/-2.
"""
function true_coefficients(net::CampusNetwork, groups::CoefficientGroups; seed::Integer = 1, spread::Real = TRUE_PIPE_SPREAD)
    rng = _stream(seed, 7001)
    jitter() = 1 + spread * clamp(_normal!(rng), -2.0, 2.0)
    loss = [TRUE_GROUP_LOSS[g] * jitter() for g in groups.pipe_group]
    friction = [TRUE_GROUP_FRICTION[g] * jitter() for g in groups.pipe_group]
    lengths = [p.length_m for p in net.pipes]
    mean_of(values, g) = sum(values[e] * lengths[e] for e in eachindex(values) if groups.pipe_group[e] == g) /
        sum(lengths[e] for e in eachindex(values) if groups.pipe_group[e] == g)
    n = length(groups.names)
    return TrueCoefficients(loss, friction, [mean_of(loss, g) for g in 1:n], [mean_of(friction, g) for g in 1:n])
end

# Physics ------------------------------------------------------------------------------------------

# Adds every equality family of the steam model, with the heat-loss and friction coefficients of each
# pipe multiplied by `loss[...]` and `friction[...]`. The load pressure ordering is left out, and the
# load heat row has no shed or excess: `demand` is the heat actually delivered. `group_of` maps a pipe
# of one period to the index into `loss` and `friction`.
function _add_calibration_physics(core, d::SteamData, v, demand, loss, friction, group_of, nedge_period)
    (; pressure, temperature, flow, temp_in, temp_out, boost, plant_power) = v
    group(t) = group_of[mod1(t.edge, nedge_period)]

    core, mass = add_con(core, d.nmass)
    core, _ = add_con!(core, mass, t.row => t.sign * flow[t.edge] for t in d.mass_terms)
    core, energy = add_con(core, d.njunction)
    core, _ = add_con!(core, energy, t.row => flow[t.edge] * temp_out[t.edge] for t in d.energy_in)
    core, _ = add_con!(core, energy, t.row => -flow[t.edge] * temp_in[t.edge] for t in d.energy_out)
    core, mixing = add_con(core, temp_in[t.edge] - temperature[t.node] for t in d.mixing)

    decay = [merge(t, (; g = group(t))) for t in d.decay]
    core, decay_rows = add_con(
        core,
        temp_out[t.edge] - t.tau_amb - (temp_in[t.edge] - t.tau_amb) * exp(-t.a * loss[t.g] / flow[t.edge])
        for t in decay
    )
    steam = [merge(t, (; g = group(t))) for t in d.steam_pipes]
    core, steam_rows = add_con(
        core,
        pressure[t.to]^2 - pressure[t.from]^2 +
            t.k * friction[t.g] * flow[t.edge]^2 * (
                t.b1 + t.b2 / loss[t.g] * flow[t.edge] * (temp_in[t.edge] - t.tau_amb) *
                    (1 - exp(-t.a * loss[t.g] / flow[t.edge]))
            )
        for t in steam
    )
    water = [merge(t, (; g = group(t))) for t in d.water_pipes]
    core, water_rows = add_con(
        core,
        pressure[t.from] - pressure[t.to] - t.k * friction[t.g] * flow[t.edge]^2 for t in water
    )
    core, _ = add_con!(core, water_rows, t.row => boost[t.pump] for t in d.pumps)

    core, load_rows = add_con(
        core,
        flow[t.edge] * (
            t.a_s * (temp_in[t.edge] - t.tau_sat) + t.a_l + t.a_w * (t.tau_sat - temp_out[t.edge])
        ) - demand[t.load]
        for t in d.loads
    )
    core, plant_rows = add_con(
        core,
        flow[t.edge] * (
            t.a_w * (t.tau_sat - temp_in[t.edge]) + t.a_l + t.a_s * (temp_out[t.edge] - t.tau_sat)
        ) - plant_power[t.power]
        for t in d.plant
    )
    return core, (; mass, energy, mixing, decay = decay_rows, steam = steam_rows, water = water_rows,
                  load = load_rows, plant = plant_rows)
end

# Positions of the variables of one period in the state vector.
struct _StateLayout
    nj::Int
    ne::Int
    np::Int
    nl::Int
    npump::Int
end
_nstate(s::_StateLayout) = 2s.nj + 3s.ne + s.npump + 1
_ip(s::_StateLayout, j) = j
_it(s::_StateLayout, j) = s.nj + j
_iflow(s::_StateLayout, e) = 2s.nj + e
_itin(s::_StateLayout, e) = 2s.nj + s.ne + e
_itout(s::_StateLayout, e) = 2s.nj + 2s.ne + e
_iboost(s::_StateLayout, k) = 2s.nj + 3s.ne + k
_ipower(s::_StateLayout) = 2s.nj + 3s.ne + s.npump + 1

# Forward simulator --------------------------------------------------------------------------------

"Condensate temperature leaving each building in the synthetic operation, in K."
const CONDENSATE_OUTLET_K = 363.15
"Fraction of its maximum boost at which every condensate pump runs in the synthetic operation."
const PUMP_BOOST_FRACTION = 0.30

"""
    ForwardSimulator(net; options = SteamModelOptions())

Solves the steady-state physics of one hour by Newton's method, for given building heat, pipe
multipliers and operating setpoints: plant steam temperature and both plant pressures, the condensate
temperature leaving each building, and the boost of each pump. The equations are the ones used by the
inverse problem.
"""
mutable struct ForwardSimulator{N, D, PD, PL, PF}
    net::CampusNetwork
    options::SteamModelOptions
    nlp::N
    data::D
    demand::PD
    loss::PL
    friction::PF
    layout::_StateLayout
    free::Vector{Int}
    jac_rows::Vector{Int}
    jac_cols::Vector{Int}
    jac_keep::Vector{Int}
    jac_values::Vector{Float64}
    residual::Vector{Float64}
    x::Vector{Float64}
end

function ForwardSimulator(net::CampusNetwork; options::SteamModelOptions = SteamModelOptions())
    heat = reshape(Float64[l.design_heat_W for l in net.loads], 1, :)
    data = compile_multiperiod_data(net; heat_W = heat, ramp_limit_W_per_h = Inf, options)
    d = data.stacked
    layout = _StateLayout(d.njunction, d.nedge, d.npipe, d.nload, d.npump)
    core = ExaCore(Float64)
    core, demand = add_par(core, d.demand)
    core, loss = add_par(core, ones(d.npipe))
    core, friction = add_par(core, ones(d.npipe))
    core, pressure = add_var(core, d.njunction; start = d.start.pressure)
    core, temperature = add_var(core, d.njunction; start = d.start.temperature)
    core, flow = add_var(core, d.nedge; start = d.start.flow)
    core, temp_in = add_var(core, d.nedge; start = d.start.temp_in)
    core, temp_out = add_var(core, d.nedge; start = d.start.temp_out)
    core, boost = add_var(core, d.npump; start = d.start.boost)
    core, plant_power = add_var(core, 1; start = d.start.plant_power)
    vars = (; pressure, temperature, flow, temp_in, temp_out, boost, plant_power)
    pipe_index = vcat(collect(1:d.npipe), zeros(Int, d.nedge - d.npipe))
    core, _ = _add_calibration_physics(core, d, vars, demand, loss, friction, pipe_index, d.nedge)
    nlp = ExaModel(core)

    # The operating setpoints are fixed; every other state is an unknown of the square system.
    fixed = falses(_nstate(layout))
    fixed[_ip(layout, d.plant_steam)] = true
    fixed[_ip(layout, d.plant_water)] = true
    fixed[_itout(layout, d.nedge)] = true
    for l in 1:d.nload
        fixed[_itout(layout, d.npipe + l)] = true
    end
    for k in 1:d.npump
        fixed[_iboost(layout, k)] = true
    end
    free = findall(.!fixed)
    length(free) == nlp.meta.ncon ||
        throw(ArgumentError("the forward system is not square: $(length(free)) unknowns, $(nlp.meta.ncon) rows"))

    rows, cols = zeros(Int, nlp.meta.nnzj), zeros(Int, nlp.meta.nnzj)
    ExaModels.NLPModels.jac_structure!(nlp, rows, cols)
    column = zeros(Int, _nstate(layout))
    column[free] .= eachindex(free)
    keep = findall(>(0), column[cols])

    x = copy(nlp.meta.x0)
    x[_ip(layout, d.plant_steam)] = net.plant.supply_pressure_Pa / options.pressure_ref_Pa
    x[_ip(layout, d.plant_water)] = net.plant.return_pressure_Pa / options.pressure_ref_Pa
    x[_itout(layout, d.nedge)] = net.plant.supply_temp_K / options.temperature_ref_K
    for l in 1:d.nload
        x[_itout(layout, d.npipe + l)] = CONDENSATE_OUTLET_K / options.temperature_ref_K
    end
    for k in 1:d.npump
        x[_iboost(layout, k)] = PUMP_BOOST_FRACTION * d.bounds.boost[2][k]
    end
    return ForwardSimulator(
        net, options, nlp, d, demand, loss, friction, layout, free, rows[keep], column[cols[keep]], keep,
        zeros(nlp.meta.nnzj), zeros(nlp.meta.ncon), x,
    )
end

"Set the per-pipe heat-loss and friction multipliers of the simulator."
function set_coefficients!(sim::ForwardSimulator, loss, friction)
    ExaModels.set_value!(sim.nlp, sim.loss, collect(Float64, loss))
    ExaModels.set_value!(sim.nlp, sim.friction, collect(Float64, friction))
    return sim
end

# Newton iteration on the free states from the current `sim.x`, with a simple backtracking line search.
function _newton!(sim::ForwardSimulator; tol = 1.0e-10, max_iter = 40)
    x, r = sim.x, sim.residual
    ExaModels.NLPModels.cons!(sim.nlp, x, r)
    current = norm(r, Inf)
    for _ in 1:max_iter
        current <= tol && return true
        ExaModels.NLPModels.jac_coord!(sim.nlp, x, sim.jac_values)
        A = sparse(sim.jac_rows, sim.jac_cols, sim.jac_values[sim.jac_keep], length(r), length(sim.free))
        step = A \ r
        base = x[sim.free]
        alpha = 1.0
        while true
            x[sim.free] .= base .- alpha .* step
            ExaModels.NLPModels.cons!(sim.nlp, x, r)
            trial = norm(r, Inf)
            if (isfinite(trial) && trial < current) || alpha < 1.0e-3
                current = trial
                break
            end
            alpha /= 2
        end
    end
    return current <= 1.0e-7
end

"""
    simulate_hours(sim, heat_W) -> Matrix

Solve each hour of `heat_W`, indexed `(hour, load)`, warm starting from the previous hour. Returns the
scaled states indexed `(state, hour)`. Throws an error if an hour does not converge.
"""
function simulate_hours(sim::ForwardSimulator, heat_W::AbstractMatrix)
    states = Matrix{Float64}(undef, _nstate(sim.layout), size(heat_W, 1))
    scale = sim.options.power_ref_W
    for h in axes(heat_W, 1)
        ExaModels.set_value!(sim.nlp, sim.demand, heat_W[h, :] ./ scale)
        _newton!(sim) || error("the forward simulation did not converge in hour $h")
        states[:, h] .= sim.x
    end
    return states
end

# Tags ---------------------------------------------------------------------------------------------

"""
    CalibrationTag

One curated historian tag. `kind` is `:flow` (`index` is an edge), `:temperature` or `:pressure`
(`index` is a junction), or `:run` (`index` is a boiler number). Sensor noise has the standard deviation
`noise_abs + noise_rel * |value|` in the tag's unit.
"""
struct CalibrationTag
    name::String
    category::String
    unit::String
    description::String
    kind::Symbol
    index::Int
    noise_abs::Float64
    noise_rel::Float64
end

"Nested tag counts used for the recovery grid. The first `n` curated tags form the set of size `n`."
const TAG_COUNTS = (5, 10, 15, 25)

const _FLOW_NOISE = (0.02, 0.01)
const _TEMP_NOISE = (0.25, 0.0)
const _PRESSURE_NOISE = (1500.0, 0.0)

# Shortest pipe distance from the plant along the steam side.
function _steam_distance(net::CampusNetwork)
    distance = fill(Inf, length(net.junctions))
    distance[net.plant.steam_junction] = 0.0
    steam = [p for p in net.pipes if p.side == "steam"]
    for _ in eachindex(net.junctions), p in steam
        distance[p.to] = min(distance[p.to], distance[p.from] + p.length_m)
    end
    return distance
end

"""
    curated_tags(net, design_state, layout) -> Vector{CalibrationTag}

The 25 curated tags in priority order, so that the first `n` form the tag set of size `n`. They are
signals that the physics pins down: steam-side temperatures, steam-side pressures and flows in heavily
loaded pipes, plus boiler run states. Condensate-side tags are left out on purpose. Pump boost and
building condensate temperatures are not metered, so water-side pressures and return temperatures say
little about pipe coefficients, and they slowed the solver down when they were included.
"""
function curated_tags(net::CampusNetwork, design_state::AbstractVector, s::_StateLayout)
    distance = _steam_distance(net)
    by_distance(ids) = sort(ids; by = j -> (-distance[j], j))
    far = by_distance([l.steam_junction for l in net.loads])
    plant = net.plant.steam_junction
    is_load = Set(l.steam_junction for l in net.loads)
    mid = by_distance([j.id for j in net.junctions if j.side == "steam" && j.id != plant && !(j.id in is_load)])
    steam_pipes = [p.id for p in net.pipes if p.side == "steam"]
    mains = sort(steam_pipes; by = e -> (-design_state[_iflow(s, e)], e))
    buildings = sort(collect(1:s.nl); by = l -> (-design_state[_iflow(s, s.np + l)], l))
    n_boilers = net.plant.n_boilers
    n_boilers >= 4 || throw(ArgumentError("the curated tag list expects at least 4 boilers"))

    flow(name, edge, what) = CalibrationTag(name, "flow", "kg/s", what, :flow, edge, _FLOW_NOISE...)
    temp(name, j, what) = CalibrationTag(name, "temperature", "K", what, :temperature, j, _TEMP_NOISE...)
    pres(name, j, what) = CalibrationTag(name, "pressure", "Pa", what, :pressure, j, _PRESSURE_NOISE...)
    run_state(k) = CalibrationTag("BLR-$k.RUN", "run state", "0/1", "Boiler $k running", :run, k, 0.0, 0.0)
    return [
        flow("PLANT.STM.FLOW", s.ne, "Total steam flow leaving the plant"),
        temp("PLANT.STM.TEMP", plant, "Steam temperature at the plant header"),
        pres("PLANT.STM.PRES", plant, "Steam pressure at the plant header"),
        temp("FAR-1.STM.TEMP", far[1], "Steam temperature at the building farthest from the plant"),
        pres("FAR-1.STM.PRES", far[1], "Steam pressure at the building farthest from the plant"),
        flow("MAIN-1.STM.FLOW", mains[1], "Steam flow in the most heavily loaded main"),
        flow("MAIN-2.STM.FLOW", mains[2], "Steam flow in the second most heavily loaded main"),
        temp("MID-1.STM.TEMP", mid[1], "Steam temperature at the farthest street junction"),
        pres("MID-1.STM.PRES", mid[1], "Steam pressure at the farthest street junction"),
        temp("FAR-2.STM.TEMP", far[2], "Steam temperature at the second farthest building"),
        pres("FAR-2.STM.PRES", far[2], "Steam pressure at the second farthest building"),
        flow("MAIN-3.STM.FLOW", mains[3], "Steam flow in the third most heavily loaded main"),
        temp("MID-2.STM.TEMP", mid[2], "Steam temperature at the second farthest street junction"),
        pres("MID-2.STM.PRES", mid[2], "Steam pressure at the second farthest street junction"),
        run_state(1),
        run_state(2),
        run_state(3),
        run_state(4),
        flow("MAIN-4.STM.FLOW", mains[4], "Steam flow in the fourth most heavily loaded main"),
        flow("BLDG-1.STM.FLOW", s.np + buildings[1], "Steam flow into the largest building"),
        flow("BLDG-2.STM.FLOW", s.np + buildings[2], "Steam flow into the second largest building"),
        temp("FAR-3.STM.TEMP", far[3], "Steam temperature at the third farthest building"),
        pres("FAR-3.STM.PRES", far[3], "Steam pressure at the third farthest building"),
        temp("FAR-4.STM.TEMP", far[4], "Steam temperature at the fourth farthest building"),
        pres("FAR-4.STM.PRES", far[4], "Steam pressure at the fourth farthest building"),
    ]
end

"The first `n` curated tags."
select_tags(tags::Vector{CalibrationTag}, n::Integer) = tags[1:n]

_tag_sigma(tag::CalibrationTag, value) = tag.noise_abs + tag.noise_rel * abs(value)

# The measured quantity in SI units, from a scaled state.
function _tag_value(tag::CalibrationTag, x::AbstractVector, s::_StateLayout, opt::SteamModelOptions)
    tag.kind === :flow && return x[_iflow(s, tag.index)] * opt.flow_ref_kg_per_s
    tag.kind === :temperature && return x[_it(s, tag.index)] * opt.temperature_ref_K
    tag.kind === :pressure && return x[_ip(s, tag.index)] * opt.pressure_ref_Pa
    throw(ArgumentError("tag $(tag.name) has no continuous value"))
end

# Synthetic historian ------------------------------------------------------------------------------

"First timestamp of the synthetic historian file."
const HISTORIAN_START = DateTime(2024, 1, 1)
"Hours in one month of the calibration grid: one twelfth of a 8760-hour year."
const HOURS_PER_MONTH = 730

# Shares of tag-hours by fault, applied independently to each tag and hour.
const _P_ABSENT = 0.010
const _P_BAD = 0.020
const _P_UNCERTAIN = 0.005
# Plant-wide communication gaps per year, each 4 to 12 hours with no rows for any tag.
const _GAPS_PER_YEAR = 6
# The smallest building heat in the synthetic operation, as a share of design heat.
const _MIN_HEAT_SHARE = 0.30

"""
    nominal_heat_profile(net; seed = 1, hours) -> Matrix

The building heat the estimator assumes before seeing data, indexed `(hour, load)`. Each 8760-hour year
is one synthetic year of `generate_profiles`, with its own weather, and heat stays at or above 30% of
design heat so that the steam stays above 100 C at part load.
"""
function nominal_heat_profile(net::CampusNetwork; seed::Integer = 1, hours::Integer)
    years = ceil(Int, hours / _HOURS_PER_YEAR)
    heat = reduce(vcat, (generate_profiles(net; seed = seed + y - 1).heat_W for y in 1:years))
    floor_W = [_MIN_HEAT_SHARE * l.design_heat_W for l in net.loads]
    return max.(heat[1:hours, :], floor_W')
end

# True building heat: nominal heat with a persistent bias per building and hourly correlated noise.
function _true_heat(nominal::AbstractMatrix, seed::Integer)
    out = copy(nominal)
    for l in axes(nominal, 2)
        rng = _stream(seed, 7100 + l)
        bias = 1 + 0.06 * clamp(_normal!(rng), -2.0, 2.0)
        noise = 0.0
        for h in axes(nominal, 1)
            noise = 0.9 * noise + 0.02 * _normal!(rng)
            out[h, l] = max(0.0, nominal[h, l] * bias * (1 + noise))
        end
    end
    return out
end

"""
    SyntheticHistorian

A generated synthetic historian file and what is known about it: `path`, `rows`, `bytes`, `hours`,
`tags`, the `truth` multipliers, the `groups`, the estimator's `nominal_heat_W`, the true states
`true_state` indexed `(state, hour)` and the true hourly heat `true_heat_W`.
"""
struct SyntheticHistorian
    path::String
    rows::Int
    bytes::Int
    hours::Int
    tags::Vector{CalibrationTag}
    truth::TrueCoefficients
    groups::CoefficientGroups
    nominal_heat_W::Matrix{Float64}
    true_heat_W::Matrix{Float64}
    true_state::Matrix{Float64}
    layout::_StateLayout
end

# Hours inside a plant-wide communication gap.
function _gap_hours(hours::Integer, seed::Integer)
    rng = _stream(seed, 7200)
    gap = falses(hours)
    for _ in 1:ceil(Int, _GAPS_PER_YEAR * hours / _HOURS_PER_YEAR)
        first_hour = _uniform_int!(rng, 1, hours)
        last_hour = min(hours, first_hour + _uniform_int!(rng, 4, 12) - 1)
        gap[first_hour:last_hour] .= true
    end
    return gap
end

"""
    generate_synthetic_historian(path; net = calibration_network(), hours = 17520, seed = 1)
        -> SyntheticHistorian

Simulate the true network for `hours` hours and write the curated tags to `path` as narrow
historian-style CSV. All data is synthetic. Every sample gets sensor noise. Independently per tag and
hour, 1% of rows are absent, 2% are flagged `Bad` (a spike, a frozen value or an empty value) and 0.5%
are flagged `Uncertain` with a biased value. About six plant-wide communication gaps per year of 4 to 12
hours have no rows at all.
"""
function generate_synthetic_historian(
        path::AbstractString; net::CampusNetwork = calibration_network(), hours::Integer = 17520,
        seed::Integer = 1, spread::Real = TRUE_PIPE_SPREAD,
    )
    groups = coefficient_groups(net)
    truth = true_coefficients(net, groups; seed, spread)
    nominal = nominal_heat_profile(net; seed, hours)
    true_heat = _true_heat(nominal, seed)
    sim = ForwardSimulator(net)
    design = simulate_hours(sim, reshape(Float64[l.design_heat_W for l in net.loads], 1, :))
    tags = curated_tags(net, design[:, 1], sim.layout)
    set_coefficients!(sim, truth.loss, truth.friction)
    states = simulate_hours(sim, true_heat)

    s, opt = sim.layout, sim.options
    gap = _gap_hours(hours, seed)
    boiler_W = net.plant.rating_W / net.plant.n_boilers
    rows = 0
    open(path, "w") do io
        write_historian_header(io)
        for (i, tag) in enumerate(tags)
            rng = _stream(seed, 7300 + i)
            previous = NaN
            for h in 1:hours
                x = view(states, :, h)
                exact = if tag.kind === :run
                    power_W = x[_ipower(s)] * opt.power_ref_W
                    Float64(tag.index <= clamp(ceil(Int, power_W / boiler_W), 1, net.plant.n_boilers))
                else
                    _tag_value(tag, x, s, opt)
                end
                sigma = _tag_sigma(tag, exact)
                value = tag.kind === :run ? exact : exact + sigma * _normal!(rng)
                u, shape, magnitude = _uniform!(rng), _uniform!(rng), _uniform!(rng)
                (gap[h] || u < _P_ABSENT) && continue
                quality = "Good"
                if u < _P_ABSENT + _P_BAD
                    quality = "Bad"
                    if tag.kind === :run
                        value = 1 - exact
                    elseif shape < 0.5
                        value = exact * (1 + (shape < 0.25 ? -1 : 1) * (0.2 + 0.3 * magnitude))
                    elseif shape < 0.8
                        value = isnan(previous) ? exact : previous
                    else
                        value = NaN
                    end
                elseif u < _P_ABSENT + _P_BAD + _P_UNCERTAIN
                    quality = "Uncertain"
                    tag.kind === :run || (value += 4 * sigma)
                end
                write_historian_row(io, HISTORIAN_START + Hour(h - 1), tag.name, value, quality)
                rows += 1
                isnan(value) || (previous = value)
            end
        end
    end
    return SyntheticHistorian(String(path), rows, filesize(path), hours, tags, truth, groups, nominal, true_heat, states, s)
end

# Inverse problem ----------------------------------------------------------------------------------

"""
    CalibrationProblem(net, series, tags, nominal_heat_W, nominal_state; heat_sigma = 0.15)

Inputs of one calibration run. `series` holds the aligned samples, `tags` the tags to use and
`nominal_heat_W` the prior building heat, indexed `(hour, load)`. `nominal_state` is a forward simulation
with nominal coefficients, used only as the starting point. `heat_sigma` is the standard deviation of
the prior on building heat, as a share of the prior value. Only the hours present in `series` are used.
"""
struct CalibrationProblem
    net::CampusNetwork
    series::HistorianSeries
    tags::Vector{CalibrationTag}
    nominal_heat_W::Matrix{Float64}
    nominal_state::Matrix{Float64}
    groups::CoefficientGroups
    heat_sigma::Float64
    multiplier_sigma::Float64
end

function CalibrationProblem(
        net::CampusNetwork, series::HistorianSeries, tags, nominal_heat_W, nominal_state;
        groups = coefficient_groups(net), heat_sigma::Real = 0.15, multiplier_sigma::Real = 1.0,
    )
    return CalibrationProblem(net, series, collect(tags), nominal_heat_W, nominal_state, groups, heat_sigma, multiplier_sigma)
end

"""
    build_calibration_model(problem; backend = nothing, options = SteamModelOptions()) -> NamedTuple

Build one NLP over all hours of `problem.series`. The variables are the hourly network states, the
hourly heat of each building, and one heat-loss and one friction multiplier per coefficient group,
shared across hours. The objective is the weighted least-squares misfit of the good samples, plus
priors on building heat and on the multipliers. Samples that are not good add no term. Groups that are
not estimated are held at `held_loss` and `held_friction`, by default the nominal value 1.
"""
function build_calibration_model(
        problem::CalibrationProblem; backend = nothing, options::SteamModelOptions = SteamModelOptions(),
        held_loss::Real = 1.0, held_friction::Real = 1.0,
    )
    net, series, tags = problem.net, problem.series, problem.tags
    T = size(series.values, 1)
    nl = length(net.loads)
    data = compile_multiperiod_data(
        net; heat_W = problem.nominal_heat_W[1:T, :], ramp_limit_W_per_h = Inf, options,
    )
    d = data.stacked
    s = _StateLayout(d.njunction ÷ T, d.nedge ÷ T, d.npipe ÷ T, nl, d.npump ÷ T)
    pref, tref, fref, qref = options.pressure_ref_Pa, options.temperature_ref_K,
        options.flow_ref_kg_per_s, options.power_ref_W

    start(range) = vec(problem.nominal_state[range, 1:T])
    capacity = _hourly_capacity(net, series, tags, T)

    core = ExaCore(Float64; backend)
    # Bounds are wide on purpose: the historian decides the state, not the operating limits.
    core, pressure = add_var(core, d.njunction; lvar = 0.01, uvar = 30.0, start = start(1:s.nj))
    core, temperature = add_var(core, d.njunction; lvar = 3.0, uvar = 5.5, start = start((s.nj + 1):(2s.nj)))
    flow_lower = repeat(vcat(fill(5.0e-3 / fref, s.np), zeros(nl + 1)), T)
    core, flow = add_var(core, d.nedge; lvar = flow_lower, start = max.(start(_iflow(s, 1):_iflow(s, s.ne)), flow_lower .+ 1.0e-3))
    core, temp_in = add_var(core, d.nedge; lvar = 3.0, uvar = 5.5, start = start(_itin(s, 1):_itin(s, s.ne)))
    core, temp_out = add_var(core, d.nedge; lvar = 3.0, uvar = 5.5, start = start(_itout(s, 1):_itout(s, s.ne)))
    core, boost = add_var(core, d.npump; lvar = 0.0, uvar = d.bounds.boost[2], start = start(_iboost(s, 1):_iboost(s, s.npump)))
    core, plant_power = add_var(
        core, T; lvar = 0.0, uvar = capacity ./ qref,
        start = min.(vec(problem.nominal_state[_ipower(s), 1:T]), capacity ./ qref),
    )
    prior_heat = vec(permutedims(problem.nominal_heat_W[1:T, :])) ./ qref
    core, heat = add_var(core, T * nl; lvar = 0.0, start = prior_heat)

    ngroup = length(problem.groups.names)
    # A group that is not estimated has equal bounds, which hold it at the nominal value.
    bounds(held) = (
        lvar = [e ? 0.2 : Float64(held) for e in problem.groups.estimated],
        uvar = [e ? 5.0 : Float64(held) for e in problem.groups.estimated],
        start = [e ? 1.0 : Float64(held) for e in problem.groups.estimated],
    )
    core, loss = add_var(core, ngroup; bounds(held_loss)...)
    core, friction = add_var(core, ngroup; bounds(held_friction)...)

    vars = (; pressure, temperature, flow, temp_in, temp_out, boost, plant_power)
    group_of = vcat(problem.groups.pipe_group, zeros(Int, nl + 1))
    core, cons = _add_calibration_physics(core, d, vars, heat, loss, friction, group_of, s.ne)

    # Misfit, one generator per measured quantity. Weights are 1 / sigma^2 in scaled units.
    terms(kind, size_of, ref) = [
        (idx = (h - 1) * size_of + tag.index, y = series.values[h, c] / ref,
         w = (ref / _tag_sigma(tag, series.values[h, c]))^2)
        for (tag, c) in _tag_columns(series, tags) if tag.kind === kind
        for h in 1:T if series.status[h, c] == SAMPLE_GOOD
    ]
    flow_terms, temp_terms, pressure_terms = terms(:flow, s.ne, fref), terms(:temperature, s.nj, tref),
        terms(:pressure, s.nj, pref)
    isempty(flow_terms) || ((core, _) = add_obj(core, 0.5 * t.w * (flow[t.idx] - t.y)^2 for t in flow_terms))
    isempty(temp_terms) || ((core, _) = add_obj(core, 0.5 * t.w * (temperature[t.idx] - t.y)^2 for t in temp_terms))
    isempty(pressure_terms) || ((core, _) = add_obj(core, 0.5 * t.w * (pressure[t.idx] - t.y)^2 for t in pressure_terms))

    heat_terms = [
        (idx = i, y = prior_heat[i], w = 1 / max(problem.heat_sigma * prior_heat[i], 1.0e-3)^2)
        for i in eachindex(prior_heat)
    ]
    core, _ = add_obj(core, 0.5 * t.w * (heat[t.idx] - t.y)^2 for t in heat_terms)
    prior = [(idx = g, w = 1 / problem.multiplier_sigma^2) for g in 1:ngroup]
    core, _ = add_obj(core, 0.5 * t.w * (loss[t.idx] - 1)^2 for t in prior)
    core, _ = add_obj(core, 0.5 * t.w * (friction[t.idx] - 1)^2 for t in prior)

    nlp = ExaModel(core)
    nmeasure = length(flow_terms) + length(temp_terms) + length(pressure_terms)
    return (; nlp, loss, friction, heat, vars, cons, layout = s, nmeasure, nhours = T)
end

_tag_columns(series::HistorianSeries, tags) = [(tag, findfirst(==(tag.name), series.tags)) for tag in tags]

# Plant output limit of each hour: the running boilers, when every boiler tag has a good sample.
function _hourly_capacity(net::CampusNetwork, series::HistorianSeries, tags, T)
    capacity = fill(net.plant.rating_W, T)
    columns = [c for (tag, c) in _tag_columns(series, tags) if tag.kind === :run]
    length(columns) == net.plant.n_boilers || return capacity
    boiler_W = net.plant.rating_W / net.plant.n_boilers
    for h in 1:T
        all(c -> series.status[h, c] == SAMPLE_GOOD, columns) || continue
        capacity[h] = boiler_W * count(c -> series.values[h, c] > 0.5, columns)
    end
    return capacity
end

"""
    solve_calibration(model; print_level = MadNLP.ERROR, tol = 1.0e-6, max_iter = 500, kwargs...)
        -> NamedTuple

Solve the calibration NLP with MadNLP. Returns the estimated `loss` and `friction` multipliers per
group, `status`, `converged`, `iterations`, `solve_time_s`, and the problem size in `nvar`, `ncon`,
`nnzj` and `nmeasure`.
"""
function solve_calibration(model; print_level = MadNLP.ERROR, tol = 1.0e-6, max_iter = 500, kwargs...)
    result = MadNLP.madnlp(model.nlp; print_level, tol, max_iter, kwargs...)
    return (
        loss = Array(ExaModels.solution(result, model.loss)),
        friction = Array(ExaModels.solution(result, model.friction)),
        status = string(result.status),
        converged = result.status in (MadNLP.SOLVE_SUCCEEDED, MadNLP.SOLVED_TO_ACCEPTABLE_LEVEL),
        iterations = result.iter,
        solve_time_s = result.counters.total_time,
        nvar = model.nlp.meta.nvar,
        ncon = model.nlp.meta.ncon,
        nnzj = model.nlp.meta.nnzj,
        nmeasure = model.nmeasure,
        nhours = model.nhours,
    )
end

"""
    recovery_errors(estimate, truth::TrueCoefficients) -> NamedTuple

Relative error of each group multiplier against the length-weighted true value, as fractions:
`loss` and `friction` per group.
"""
function recovery_errors(estimate, truth::TrueCoefficients)
    return (
        loss = abs.(estimate.loss .- truth.group_loss) ./ truth.group_loss,
        friction = abs.(estimate.friction .- truth.group_friction) ./ truth.group_friction,
    )
end

# Identifiability ----------------------------------------------------------------------------------

"""
    identifiability_analysis(sim, tags, heat_W; truth, groups, sample_hours, tag_counts = TAG_COUNTS,
                             heat_sigma = 0.15) -> Vector{NamedTuple}

Linearized identifiability at the true coefficients, from finite-difference sensitivities of the
numeric tags at `sample_hours`. Quantities the historian does not meter are nuisance parameters of each
hour and are marginalized out: building heat (prior `heat_sigma`), the condensate temperature leaving
each building (10 K), pump boost (0.5 bar), the plant steam temperature (10 K) and both plant pressures
(0.5 bar).

For each tag count the result holds `group_std_1_month` and `group_std_12_months`, the predicted standard
deviation of each group multiplier as a fraction of the nominal value, with `loss` and `friction` entries,
and `pipe_directions_resolved`: how many of the `pipe_coefficients` per-pipe coefficient directions would
have a predicted standard deviation below 10% with 12 months of hourly data.
"""
function identifiability_analysis(
        sim::ForwardSimulator, tags::Vector{CalibrationTag}, heat_W::AbstractMatrix;
        truth::TrueCoefficients, groups::CoefficientGroups, sample_hours,
        tag_counts = TAG_COUNTS, heat_sigma::Real = 0.15,
    )
    s, opt = sim.layout, sim.options
    numeric = findall(t -> t.kind !== :run, tags)
    measure(x) = [_tag_value(tags[i], x, s, opt) for i in numeric]
    np, nl = s.np, s.nl
    ntheta = 2np
    set_coefficients!(sim, truth.loss, truth.friction)
    information = Dict(n => zeros(ntheta, ntheta) for n in tag_counts)

    for h in sample_hours
        base_heat = heat_W[h, :] ./ opt.power_ref_W
        ExaModels.set_value!(sim.nlp, sim.demand, base_heat)
        _newton!(sim) || error("the forward simulation did not converge in hour $h")
        base = copy(sim.x)
        y0 = measure(base)
        sigma = [_tag_sigma(tags[i], y0[k]) for (k, i) in enumerate(numeric)]

        respond(perturb!, restore!) = begin
            perturb!()
            _newton!(sim) || error("the forward simulation did not converge in hour $h")
            dy = (measure(sim.x) .- y0) ./ sigma
            restore!()
            sim.x .= base
            dy
        end

        step = 1.0e-3
        s_theta = zeros(length(numeric), ntheta)
        for e in 1:np
            loss = copy(truth.loss)
            loss[e] *= 1 + step
            s_theta[:, e] = respond(
                () -> ExaModels.set_value!(sim.nlp, sim.loss, loss),
                () -> ExaModels.set_value!(sim.nlp, sim.loss, truth.loss),
            ) ./ step
            friction = copy(truth.friction)
            friction[e] *= 1 + step
            s_theta[:, np + e] = respond(
                () -> ExaModels.set_value!(sim.nlp, sim.friction, friction),
                () -> ExaModels.set_value!(sim.nlp, sim.friction, truth.friction),
            ) ./ step
        end

        # Nuisance columns are scaled by their prior standard deviation.
        columns = Vector{Vector{Float64}}()
        for l in 1:nl
            prior = heat_sigma * max(base_heat[l], 1.0e-3)
            bumped = copy(base_heat)
            bumped[l] += 1.0e-3 * prior
            push!(columns, respond(
                () -> ExaModels.set_value!(sim.nlp, sim.demand, bumped),
                () -> ExaModels.set_value!(sim.nlp, sim.demand, base_heat),
            ) ./ 1.0e-3)
        end
        fixed_state(index, prior) = respond(() -> (sim.x[index] += 1.0e-3 * prior), () -> nothing) ./ 1.0e-3
        for l in 1:nl
            push!(columns, fixed_state(_itout(s, np + l), 10.0 / opt.temperature_ref_K))
        end
        for k in 1:s.npump
            push!(columns, fixed_state(_iboost(s, k), 0.5e5 / opt.pressure_ref_Pa))
        end
        push!(columns, fixed_state(_itout(s, s.ne), 10.0 / opt.temperature_ref_K))
        push!(columns, fixed_state(_ip(s, sim.data.plant_steam), 0.5e5 / opt.pressure_ref_Pa))
        push!(columns, fixed_state(_ip(s, sim.data.plant_water), 0.5e5 / opt.pressure_ref_Pa))
        s_nuisance = reduce(hcat, columns)

        for n in tag_counts
            keep = [k for (k, i) in enumerate(numeric) if i <= n]
            A, B = s_theta[keep, :], s_nuisance[keep, :]
            M = Symmetric(B' * B + _Identity)
            information[n] .+= A' * A .- A' * B * (M \ (B' * A))
        end
    end

    nsample = length(sample_hours)
    ngroup = length(groups.names)
    G = zeros(ntheta, 2ngroup)
    for e in 1:np
        G[e, groups.pipe_group[e]] = truth.loss[e] / truth.group_loss[groups.pipe_group[e]]
        G[np + e, ngroup + groups.pipe_group[e]] = truth.friction[e] / truth.group_friction[groups.pipe_group[e]]
    end
    return map(collect(tag_counts)) do n
        per_hour = Symmetric((information[n] .+ information[n]') ./ (2nsample))
        group_info = Symmetric(G' * per_hour * G)
        std_at(hours) = sqrt.(max.(0.0, [inv(Symmetric(hours .* group_info + _Identity))[i, i] for i in 1:2ngroup]))
        one_month, twelve = std_at(HOURS_PER_MONTH), std_at(12 * HOURS_PER_MONTH)
        resolved = count(>=(100.0), max.(eigvals(per_hour), 0.0) .* (12 * HOURS_PER_MONTH))
        (
            tag_count = n,
            group_std_1_month = (loss = one_month[1:ngroup], friction = one_month[(ngroup + 1):end]),
            group_std_12_months = (loss = twelve[1:ngroup], friction = twelve[(ngroup + 1):end]),
            pipe_directions_resolved = resolved,
            pipe_coefficients = ntheta,
            sample_hours = nsample,
        )
    end
end

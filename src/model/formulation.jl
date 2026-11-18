# ExaModels formulation. Each constraint family is one generator over one data array. The balance
# rows are built from empty rows plus augmentation layers, so their patterns do not depend on
# junction degree.

"""
    add_steam_variables(core, data::SteamData) -> (core, vars)

Add the scaled variables of one steady-state period to an `ExaCore`. `vars` is a named tuple with
`pressure`, `temperature` (per junction), `flow`, `temp_in`, `temp_out` (per edge), `boost` (per
pump), `shed`, `excess` (per load) and `plant_power`.
"""
function add_steam_variables(core, data::SteamData)
    b, s = data.bounds, data.start
    core, pressure = add_var(core, data.njunction; lvar = b.pressure[1], uvar = b.pressure[2], start = s.pressure)
    core, temperature = add_var(core, data.njunction; lvar = b.temperature[1], uvar = b.temperature[2], start = s.temperature)
    core, flow = add_var(core, data.nedge; lvar = b.flow[1], uvar = b.flow[2], start = s.flow)
    core, temp_in = add_var(core, data.nedge; lvar = b.temp_in[1], uvar = b.temp_in[2], start = s.temp_in)
    core, temp_out = add_var(core, data.nedge; lvar = b.temp_out[1], uvar = b.temp_out[2], start = s.temp_out)
    core, boost = add_var(core, data.npump; lvar = b.boost[1], uvar = b.boost[2], start = s.boost)
    core, shed = add_var(core, data.nload; lvar = 0.0, start = 0.0)
    core, excess = add_var(core, data.nload; lvar = 0.0, start = 0.0)
    core, plant_power = add_var(core, 1; lvar = b.plant_power[1], uvar = b.plant_power[2], start = s.plant_power)
    return core, (; pressure, temperature, flow, temp_in, temp_out, boost, shed, excess, plant_power)
end

"""
    add_steam_constraints(core, data::SteamData, vars, demand) -> (core, cons)

Add the constraint families of one period. `demand` is an indexable of scaled load demand, usually
an ExaModels parameter. `cons` names each family: `mass_balance`, `energy_balance`, `mixing`,
`temperature_decay`, `steam_pressure`, `water_pressure`, `load_heat`, `load_pressure`,
`plant_power`.
"""
function add_steam_constraints(core, data::SteamData, vars, demand)
    (; pressure, temperature, flow, temp_in, temp_out, boost, shed, excess, plant_power) = vars

    core, mass_balance = add_con(core, data.nmass)
    core, _ = add_con!(core, mass_balance, t.row => t.sign * flow[t.edge] for t in data.mass_terms)

    core, energy_balance = add_con(core, data.njunction)
    core, _ = add_con!(core, energy_balance, t.row => flow[t.edge] * temp_out[t.edge] for t in data.energy_in)
    core, _ = add_con!(core, energy_balance, t.row => -flow[t.edge] * temp_in[t.edge] for t in data.energy_out)

    core, mixing = add_con(core, temp_in[t.edge] - temperature[t.node] for t in data.mixing)

    core, temperature_decay = add_con(
        core,
        temp_out[t.edge] - t.tau_amb - (temp_in[t.edge] - t.tau_amb) * exp(-t.a / flow[t.edge])
        for t in data.decay
    )

    # The temperature integral of Eq. (14) uses the inlet-outlet difference implied by the decay law.
    # Writing it with `temp_out` instead is equal at a feasible point, but multiplies any decay
    # residual by `c * flow / gamma`, which derails the solver on well-insulated pipes.
    core, steam_pressure = add_con(
        core,
        pressure[t.to]^2 - pressure[t.from]^2 +
            t.k * flow[t.edge]^2 * (
                t.b1 + t.b2 * flow[t.edge] * (temp_in[t.edge] - t.tau_amb) * (1 - exp(-t.a / flow[t.edge]))
            )
        for t in data.steam_pipes
    )

    core, water_pressure = add_con(
        core,
        pressure[t.from] - pressure[t.to] - t.k * flow[t.edge]^2 for t in data.water_pipes
    )
    core, _ = add_con!(core, water_pressure, t.row => boost[t.pump] for t in data.pumps)

    core, load_heat = add_con(
        core,
        flow[t.edge] * (
            t.a_s * (temp_in[t.edge] - t.tau_sat) + t.a_l + t.a_w * (t.tau_sat - temp_out[t.edge])
        ) - excess[t.load] + shed[t.load] - demand[t.load]
        for t in data.loads
    )

    core, load_pressure = add_con(
        core,
        pressure[t.steam] - pressure[t.water] for t in data.load_pressure;
        lcon = 0.0, ucon = Inf,
    )

    core, plant_balance = add_con(
        core,
        flow[t.edge] * (
            t.a_w * (t.tau_sat - temp_in[t.edge]) + t.a_l + t.a_s * (temp_out[t.edge] - t.tau_sat)
        ) - plant_power[1]
        for t in data.plant
    )

    return core, (;
        mass_balance, energy_balance, mixing, temperature_decay, steam_pressure,
        water_pressure, load_heat, load_pressure, plant_power = plant_balance,
    )
end

"""
    add_steam_objective(core, data::SteamData, vars; scale = 1.0) -> core

Add the objective of Eq. (20) of the paper, in units of `objective_ref_W`: weighted shed and
excess power plus the plant pressure, flow and outlet temperature terms that remove degeneracy.
`scale` multiplies every term, for example a period length in multi-period models.
"""
function add_steam_objective(core, data::SteamData, vars; scale = 1.0)
    opt = data.options
    qref = opt.objective_ref_W
    power = opt.power_ref_W / qref
    (; pressure, flow, temp_out, shed, excess, plant_power) = vars

    terms = [
        (
            load = t.load,
            shed = scale * power * t.shed,
            excess = scale * power * t.excess,
        ) for t in data.objective_loads
    ]
    core, _ = add_obj(core, t.shed * shed[t.load] + t.excess * excess[t.load] for t in terms)

    plant_terms = [
        (
            steam = data.plant_steam,
            water = data.plant_water,
            edge = data.nedge,
            w_p = scale * opt.pressure_weight * opt.pressure_ref_Pa / qref,
            w_f = scale * opt.flow_weight * opt.flow_ref_kg_per_s / qref,
            w_t = scale * opt.temperature_weight * opt.temperature_ref_K / qref,
            w_q = scale * power * opt.plant_power_weight,
        ),
    ]
    core, _ = add_obj(
        core,
        t.w_p * (pressure[t.steam] + pressure[t.water]) + t.w_f * flow[t.edge] +
            t.w_t * temp_out[t.edge] + t.w_q * plant_power[1]
        for t in plant_terms
    )
    return core
end

"""
    SteamModel

A built single-period model: the `ExaModel` in `nlp`, the compiled `data`, the variable handles
`vars`, the constraint handles `cons`, and the demand parameter `demand`.
"""
struct SteamModel{N, D <: SteamData, V, C, P}
    nlp::N
    data::D
    vars::V
    cons::C
    demand::P
end

"""
    build_steam_model(net; heat_W = nothing, plant_rating_W = nothing,
                      options = SteamModelOptions(), backend = nothing) -> SteamModel

Build the single-period steady-state district-steam NLP. `backend` is a KernelAbstractions
backend such as `CUDABackend()`, or `nothing` for the CPU.

The model is steady-state: it has no pipe transients and no valves.
"""
function build_steam_model(
        net;
        heat_W = nothing,
        plant_rating_W = nothing,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
    )
    data = compile_steam_data(net; heat_W, plant_rating_W, options)
    core = ExaCore(Float64; backend)
    core, demand = add_par(core, data.demand)
    core, vars = add_steam_variables(core, data)
    core, cons = add_steam_constraints(core, data, vars, demand)
    core = add_steam_objective(core, data, vars)
    return SteamModel(ExaModel(core), data, vars, cons, demand)
end

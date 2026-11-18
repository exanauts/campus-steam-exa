# Independent JuMP statement of the thermal network flow optimization problem (TNFO), Eq. (27) of
# Hari, Srinivasan, Zlotnik, Sundar and Ewers, arXiv:2404.18868. Equation numbers refer to the paper.
#
# This file shares no code with `src/model/`. Only the network description is common. Constants,
# bounds, scaling, row selection and the starting point are all stated here. Deliberate differences
# from the ExaModels model, none of which change the feasible set:
#
# - Plant power is the inequality (1), with no auxiliary power variable.
# - The redundant mass balance dropped is the one at the plant's steam junction.
# - Variables are scaled by different references, and each edge class has its own variables.

using JuMP: JuMP, @constraint, @objective, @variable, Model, optimizer_with_attributes
using JuMP: set_attribute, set_start_value, optimize!, termination_status, objective_value, objective_function, value,
    num_variables, num_constraints, primal_feasibility_report, all_variables, delete
using Ipopt: Ipopt

"Physical constants and limits from Section 4.2 of the paper, and the documented flow floor."
const TNFO = (
    R_s = 461.5,            # J/(kg K)
    c_s = 1996.0,           # J/(kg K)
    c_w = 4186.0,           # J/(kg K)
    c_L = 2230.0e3,         # J/kg
    rho_w = 1000.0,         # kg/m^3
    T_ext = 25.0 + 273.15,  # K
    T_sat = 100.0 + 273.15, # K
    T_max = 150.0 + 273.15, # K
    T_min = 80.0 + 273.15,  # K
    p_min = 34473.8,        # Pa, 5 psi
    p_max = 551581.0,       # Pa, 80 psi
    f_floor = 1.0e-4,       # kg/s, docs/model-notes.md
)

# Scaling references of this model, chosen differently from the ExaModels model on purpose.
const P0 = 2.0e5    # Pa
const TH0 = 300.0   # K
const F0 = 2.0      # kg/s
const W0 = 5.0e6    # W
const OBJ0 = 1.0e4  # W

struct TNFOModel
    model::Any
    net::CampusNetwork
    heat_W::Vector{Float64}
    rating_W::Float64
    vars::NamedTuple
end

"Bounds of the TNFO instance in SI units, derived from the paper and `docs/model-notes.md`."
function tnfo_bounds(net::CampusNetwork)
    c = TNFO
    plant = net.plant
    T_top = max(c.T_max, plant.supply_temp_K)
    is_steam(j) = net.junctions[j].side == "steam"

    p_lo = fill(c.p_min, length(net.junctions))
    p_hi = fill(max(c.p_max, plant.supply_pressure_Pa), length(net.junctions))
    p_lo[plant.steam_junction] = max(c.p_min, plant.supply_pressure_Pa)
    p_lo[plant.water_junction] = max(c.p_min, plant.return_pressure_Pa)

    T_lo = [is_steam(j) ? c.T_sat : c.T_min for j in eachindex(net.junctions)]
    T_hi = [is_steam(j) ? T_top : c.T_sat for j in eachindex(net.junctions)]

    # A pipe slower than this could not hold its outlet above the carrier's lower limit.
    f_lo = map(net.pipes) do pipe
        steam = pipe.side == "steam"
        gamma = pipe.heat_loss_W_per_m2K * pi * pipe.diameter_m
        spec = steam ? c.c_s : c.c_w
        hi, lo = steam ? (T_top, c.T_sat) : (c.T_sat, c.T_min)
        max(c.f_floor, pipe.length_m * gamma / (spec * log((hi - c.T_ext) / (lo - c.T_ext))))
    end
    return (; p_lo, p_hi, T_lo, T_hi, f_lo, T_top)
end

# Hop-count spanning tree from the plant, used only to place the starting flows.
function _tree_parents(net::CampusNetwork, side::String, root::Int)
    parent = Dict{Int, Tuple{Int, Int}}()
    seen = Set([root])
    frontier = [root]
    while !isempty(frontier)
        next = Int[]
        for j in frontier, (k, pipe) in enumerate(net.pipes)
            pipe.side == side || continue
            other = pipe.from == j ? pipe.to : pipe.to == j ? pipe.from : 0
            (other == 0 || other in seen) && continue
            push!(seen, other)
            parent[other] = (j, k)
            push!(next, other)
        end
        frontier = next
    end
    return parent
end

function _starting_flows(net::CampusNetwork, heat_W, bounds)
    c = TNFO
    specific = c.c_L + c.c_s * 20.0 + c.c_w * 10.0
    f_load = max.(heat_W, 1.0e3) ./ specific
    f_pipe = zeros(length(net.pipes))
    for (side, root) in (("steam", net.plant.steam_junction), ("water", net.plant.water_junction))
        parent = _tree_parents(net, side, root)
        for (l, load) in enumerate(net.loads)
            j = side == "steam" ? load.steam_junction : load.water_junction
            while j != root
                j, k = parent[j]
                f_pipe[k] += f_load[l]
            end
        end
    end
    return max.(f_pipe, 2.0 .* bounds.f_lo), f_load
end

"""
    build_tnfo(net; heat_W, rating_W, tol) -> TNFOModel

State problem (27) of the paper for `net` as a JuMP model solved by Ipopt.
"""
function build_tnfo(
        net::CampusNetwork;
        heat_W = [l.design_heat_W for l in net.loads],
        rating_W = net.plant.rating_W,
        tol = 1.0e-9,
        max_iter = 3000,
        steam_row::Symbol = :paper,
    )
    steam_row in (:paper, :substituted) || throw(ArgumentError("unknown steam_row $steam_row"))
    c = TNFO
    b = tnfo_bounds(net)
    m = Model(optimizer_with_attributes(
        Ipopt.Optimizer,
        "tol" => tol,
        "constr_viol_tol" => tol,
        "dual_inf_tol" => tol,
        "compl_inf_tol" => tol,
        "acceptable_iter" => 0,
        "bound_relax_factor" => 0.0,
        "honor_original_bounds" => "yes",
        "mu_strategy" => "monotone",
        "max_iter" => max_iter,
        "print_level" => 0,
        "sb" => "yes",
    ))

    junctions = eachindex(net.junctions)
    pipes = eachindex(net.pipes)
    loads = eachindex(net.loads)
    steam_pipes = [e for e in pipes if net.pipes[e].side == "steam"]
    water_pipes = [e for e in pipes if net.pipes[e].side == "water"]
    pumps = [e for e in water_pipes if net.pipes[e].max_pump_boost_Pa > 0]
    plant = net.plant

    f_pipe0, f_load0 = _starting_flows(net, heat_W, b)
    f_plant0 = sum(f_load0)
    T_steam0, T_water0 = min(c.T_sat + 20.0, b.T_top), c.T_sat - 10.0
    T0(j) = net.junctions[j].side == "steam" ? T_steam0 : T_water0
    p0(j) = clamp(net.junctions[j].side == "steam" ? plant.supply_pressure_Pa : 1.5 * plant.return_pressure_Pa,
        b.p_lo[j], b.p_hi[j])

    @variable(m, b.p_lo[j] / P0 <= p[j in junctions] <= b.p_hi[j] / P0, start = p0(j) / P0)
    @variable(m, b.T_lo[j] / TH0 <= T[j in junctions] <= b.T_hi[j] / TH0, start = T0(j) / TH0)

    # Pipes: flow, inlet temperature and outlet temperature, on the pipe's own carrier.
    side_T(e) = net.pipes[e].side == "steam" ? (c.T_sat, b.T_top, T_steam0) : (c.T_min, c.T_sat, T_water0)
    @variable(m, f[e in pipes] >= b.f_lo[e] / F0, start = f_pipe0[e] / F0)
    @variable(m, side_T(e)[1] / TH0 <= Tin[e in pipes] <= side_T(e)[2] / TH0, start = side_T(e)[3] / TH0)
    @variable(m, side_T(e)[1] / TH0 <= Tout[e in pipes] <= side_T(e)[2] / TH0, start = side_T(e)[3] / TH0)

    # Loads take steam in and return water, Eq. (4).
    @variable(m, fl[l in loads] >= 0, start = f_load0[l] / F0)
    @variable(m, c.T_sat / TH0 <= Tl_in[l in loads] <= b.T_top / TH0, start = T_steam0 / TH0)
    @variable(m, c.T_min / TH0 <= Tl_out[l in loads] <= c.T_sat / TH0, start = T_water0 / TH0)
    @variable(m, QS[l in loads] >= 0, start = 0.0)
    @variable(m, QE[l in loads] >= 0, start = 0.0)

    # The plant takes water in and sends steam out.
    @variable(m, fg >= 0, start = f_plant0 / F0)
    @variable(m, c.T_min / TH0 <= Tg_in <= c.T_sat / TH0, start = T_water0 / TH0)
    @variable(m, c.T_sat / TH0 <= Tg_out <= b.T_top / TH0, start = T_steam0 / TH0)

    # Pump boost, Eq. (25).
    @variable(m, 0 <= alpha[e in pumps] <= net.pipes[e].max_pump_boost_Pa / P0,
        start = 0.25 * net.pipes[e].max_pump_boost_Pa / P0)

    # Eq. (17): every stream leaving a junction carries the junction temperature.
    @constraint(m, [e in pipes], Tin[e] == T[net.pipes[e].from])
    @constraint(m, [l in loads], Tl_in[l] == T[net.loads[l].steam_junction])
    @constraint(m, Tg_in == T[plant.water_junction])

    # Eq. (18) and (19): conservation at each junction, collected edge by edge.
    mass_in = [Any[] for _ in junctions]
    mass_out = [Any[] for _ in junctions]
    heat_in = [Any[] for _ in junctions]
    heat_out = [Any[] for _ in junctions]
    function attach!(from, to, flow, T_from, T_to)
        push!(mass_out[from], flow)
        push!(mass_in[to], flow)
        push!(heat_out[from], flow * T_from)
        push!(heat_in[to], flow * T_to)
        return nothing
    end
    for e in pipes
        attach!(net.pipes[e].from, net.pipes[e].to, f[e], Tin[e], Tout[e])
    end
    for l in loads
        attach!(net.loads[l].steam_junction, net.loads[l].water_junction, fl[l], Tl_in[l], Tl_out[l])
    end
    attach!(plant.water_junction, plant.steam_junction, fg, Tg_in, Tg_out)

    # The specific heat is uniform on each side of the network and divides out of Eq. (19).
    for j in junctions
        j == plant.steam_junction && continue
        @constraint(m, sum(mass_in[j]) == sum(mass_out[j]))
    end
    for j in junctions
        @constraint(m, sum(heat_in[j]) == sum(heat_out[j]))
    end

    for e in pipes
        pipe = net.pipes[e]
        gamma = pipe.heat_loss_W_per_m2K * pi * pipe.diameter_m
        spec = pipe.side == "steam" ? c.c_s : c.c_w
        area = pi * pipe.diameter_m^2 / 4

        # Eq. (7).
        rate = pipe.length_m * gamma / (spec * F0)
        @constraint(m, Tout[e] - c.T_ext / TH0 == (Tin[e] - c.T_ext / TH0) * exp(-rate / f[e]))

        if pipe.side == "steam"
            # Eq. (14), with flow non-negative in the nominal direction.
            r = pipe.friction_factor * c.R_s * F0^2 / (area^2 * pipe.diameter_m * P0^2)
            drop = steam_row == :paper ? Tin[e] - Tout[e] :
                (Tin[e] - c.T_ext / TH0) * (1 - exp(-rate / f[e]))
            @constraint(m,
                p[pipe.to]^2 - p[pipe.from]^2 ==
                    -r * f[e]^2 * (c.T_ext * pipe.length_m + spec * F0 * TH0 * f[e] * drop / gamma))
        else
            # Eq. (16).
            r = pipe.friction_factor * pipe.length_m * F0^2 / (2 * area^2 * pipe.diameter_m * c.rho_w * P0)
            boost = e in pumps ? alpha[e] : 0.0
            @constraint(m, p[pipe.to] - p[pipe.from] == boost - r * f[e]^2)
        end
    end

    # Eq. (2) and (5).
    specific(T_steam, T_water) = (c.c_s * TH0 * T_steam - c.c_s * c.T_sat + c.c_L + c.c_w * c.T_sat - c.c_w * TH0 * T_water)
    for l in loads
        @constraint(m, F0 * fl[l] * specific(Tl_in[l], Tl_out[l]) / W0 == heat_W[l] / W0 + QE[l] - QS[l])
        @constraint(m, p[net.loads[l].steam_junction] >= p[net.loads[l].water_junction])
    end

    # Eq. (1).
    @constraint(m, F0 * fg * specific(Tg_out, Tg_in) / W0 <= rating_W / W0)

    # Eq. (20), with the priority weight the demo places on each load's shed power.
    @objective(m, Min,
        (W0 * sum(net.loads[l].priority_weight * QS[l] + QE[l] for l in loads) +
            P0 * (p[plant.steam_junction] + p[plant.water_junction]) + TH0 * Tg_out + F0 * fg) / OBJ0)

    vars = (; p, T, f, Tin, Tout, fl, Tl_in, Tl_out, QS, QE, fg, Tg_in, Tg_out, alpha)
    return TNFOModel(m, net, collect(Float64, heat_W), Float64(rating_W), vars)
end

"""
    solve_tnfo(net; tol, max_iter) -> (tnfo, presolve_status)

Solve problem (27) with Eq. (14) exactly as printed in the paper. On well-insulated pipes that row
multiplies any residual of Eq. (7) by `c * f / gamma`, and Ipopt fails from a cold start. A first
solve therefore uses Eq. (14) with Eq. (7) substituted for `Tin - Tout`, and its solution starts the
final solve of the printed form. The returned model and all reported values use the printed form.
"""
function solve_tnfo(net::CampusNetwork; tol = 1.0e-9, max_iter = 3000)
    first_stage = build_tnfo(net; tol, max_iter, steam_row = :substituted)
    optimize!(first_stage.model)
    presolve_status = string(termination_status(first_stage.model))
    tnfo = build_tnfo(net; tol, max_iter, steam_row = :paper)
    set_start_value.(all_variables(tnfo.model), value.(all_variables(first_stage.model)))
    set_attribute(tnfo.model, "mu_init", 1.0e-7)
    optimize!(tnfo.model)
    return tnfo, presolve_status
end

"Physical solution of a solved `TNFOModel`, in SI units."
function tnfo_solution(t::TNFOModel)
    c, v, net = TNFO, t.vars, t.net
    val(x) = value(x)
    f_load = [F0 * val(v.fl[l]) for l in eachindex(net.loads)]
    T_in, T_out = TH0 * val(v.Tg_in), TH0 * val(v.Tg_out)
    f_plant = F0 * val(v.fg)
    boost = zeros(length(net.pipes))
    for e in axes(v.alpha, 1)
        boost[e] = P0 * val(v.alpha[e])
    end
    return (
        pressure_Pa = [P0 * val(v.p[j]) for j in eachindex(net.junctions)],
        temperature_K = [TH0 * val(v.T[j]) for j in eachindex(net.junctions)],
        pipe_flow = [F0 * val(v.f[e]) for e in eachindex(net.pipes)],
        pipe_T_in = [TH0 * val(v.Tin[e]) for e in eachindex(net.pipes)],
        pipe_T_out = [TH0 * val(v.Tout[e]) for e in eachindex(net.pipes)],
        load_flow = f_load,
        load_T_in = [TH0 * val(v.Tl_in[l]) for l in eachindex(net.loads)],
        load_T_out = [TH0 * val(v.Tl_out[l]) for l in eachindex(net.loads)],
        shed_W = [W0 * val(v.QS[l]) for l in eachindex(net.loads)],
        excess_W = [W0 * val(v.QE[l]) for l in eachindex(net.loads)],
        boost_Pa = boost,
        plant_flow = f_plant,
        plant_T_in = T_in,
        plant_T_out = T_out,
        plant_output_W = f_plant * (c.c_w * (c.T_sat - T_in) + c.c_L + c.c_s * (T_out - c.T_sat)),
        objective_W = OBJ0 * objective_value(t.model),
    )
end

"Map a `SteamSolution` onto the variables of `t`, as a point for feasibility evaluation."
function tnfo_point(t::TNFOModel, sol)
    v, net = t.vars, t.net
    point = Dict{JuMP.VariableRef, Float64}()
    for j in eachindex(net.junctions)
        point[v.p[j]] = sol.junction_pressure_Pa[j] / P0
        point[v.T[j]] = sol.junction_temperature_K[j] / TH0
    end
    for e in eachindex(net.pipes)
        point[v.f[e]] = sol.pipe_flow_kg_per_s[e] / F0
        point[v.Tin[e]] = sol.pipe_inlet_temp_K[e] / TH0
        point[v.Tout[e]] = sol.pipe_outlet_temp_K[e] / TH0
    end
    for l in eachindex(net.loads)
        point[v.fl[l]] = sol.load_flow_kg_per_s[l] / F0
        point[v.Tl_in[l]] = sol.load_inlet_temp_K[l] / TH0
        point[v.Tl_out[l]] = sol.load_outlet_temp_K[l] / TH0
        point[v.QS[l]] = sol.load_shed_W[l] / W0
        point[v.QE[l]] = sol.load_excess_W[l] / W0
    end
    point[v.fg] = sol.plant_flow_kg_per_s / F0
    point[v.Tg_in] = sol.plant_inlet_temp_K / TH0
    point[v.Tg_out] = sol.plant_outlet_temp_K / TH0
    for e in axes(v.alpha, 1)
        point[v.alpha[e]] = sol.pump_boost_Pa[e] / P0
    end
    return point
end

"Largest constraint or bound violation of `sol` in this model's scaled rows."
function tnfo_max_violation(t::TNFOModel, sol)
    report = primal_feasibility_report(t.model, tnfo_point(t, sol); skip_missing = false)
    return isempty(report) ? 0.0 : maximum(values(report))
end

"""
    tnfo_face_range(t, var, scale, objective_bound_W) -> NamedTuple

Range of `scale * var` over the points of the solved model `t` whose objective is at most
`objective_bound_W`. Each end is a local solve started from the solution of `t`, so the interval is
an inner estimate of the true range. Returns each end with its solver status and its largest
constraint violation, because an end that did not converge is not evidence of anything. The model
is restored afterwards.
"""
function tnfo_face_range(t::TNFOModel, var, scale, objective_bound_W)
    m = t.model
    variables = all_variables(m)
    solution = value.(variables)
    original = objective_function(m)
    cut = @constraint(m, original <= objective_bound_W / OBJ0)
    function extreme(sign)
        set_start_value.(variables, solution)
        @objective(m, Min, sign * var)
        optimize!(m)
        report = primal_feasibility_report(m)
        violation = isempty(report) ? 0.0 : maximum(values(report))
        return scale * value(var), string(termination_status(m)), violation
    end
    low, low_status, low_violation = extreme(1.0)
    high, high_status, high_violation = extreme(-1.0)
    delete(m, cut)
    @objective(m, Min, original)
    set_start_value.(variables, solution)
    optimize!(m)
    return (; low, high, low_status, high_status, low_violation, high_violation)
end

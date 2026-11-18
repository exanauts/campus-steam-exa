# Reference validation of the ExaModels steam model against an independent JuMP + Ipopt statement of
# the same problem. All networks are synthetic. The upstream example network is downloaded at run
# time from a pinned commit of ThermalModels.jl (see upstream_example.jl) and is not stored here.
#
#     julia --project=validation -e 'using Pkg; Pkg.instantiate()'
#     julia --project=validation validation/run_validation.jl
#
# Writes, under results/:
#   validation.csv                  one row per instance, at the reference tolerance
#   validation_tolerance_ladder.csv the same differences at tighter solver tolerances
#   validation_optimal_face.csv     range of the worst-matching quantities over near-optimal points
#   validation_size_sweep.csv       solver outcome for every scaled size that was attempted

using CampusSteam
using Printf: @sprintf

include("upstream_example.jl")
include("jump_model.jl")
include("source_hash.jl")

const TOL = 1.0e-8
const LADDER = (1.0e-8, 1.0e-10, 1.0e-12)
const MAX_ITER = 3000
const THRESHOLD = 1.0e-6
const REPO = dirname(@__DIR__)

# Selection rule: validate the two largest swept sizes that both solvers solve at the reference
# tolerance, meaning MadNLP reports SOLVE_SUCCEEDED and Ipopt reports LOCALLY_SOLVED.
const SWEEP_SIZES = (200, 300, 400, 500, 600, 800)
const N_VALIDATED_SIZES = 2

relative_difference(a, b) = a == b ? 0.0 : abs(a - b) / max(abs(a), abs(b))

git(args...) = readchomp(Cmd(`git $args`; dir = REPO))

"Fail when the constants or bounds stated in jump_model.jl have drifted from the ExaModels model."
function audit_inputs(net, data)
    opt, c = data.options, TNFO
    constants = (
        opt.gas_constant_J_per_kgK => c.R_s, opt.cp_steam_J_per_kgK => c.c_s,
        opt.cp_water_J_per_kgK => c.c_w, opt.latent_heat_J_per_kg => c.c_L,
        opt.water_density_kg_per_m3 => c.rho_w, opt.ambient_temp_K => c.T_ext,
        opt.saturation_temp_K => c.T_sat, opt.steam_temp_max_K => c.T_max,
        opt.water_temp_min_K => c.T_min, opt.pressure_min_Pa => c.p_min,
        opt.pressure_max_Pa => c.p_max, opt.flow_floor_kg_per_s => c.f_floor,
    )
    all(isapprox(a, b; rtol = 1.0e-12) for (a, b) in constants) || error("Physical constants differ.")
    b = tnfo_bounds(net)
    same(x, y) = all(isapprox.(x, y; rtol = 1.0e-12))
    same(data.bounds.pressure[1] .* opt.pressure_ref_Pa, b.p_lo) || error("Pressure lower bounds differ.")
    same(data.bounds.pressure[2] .* opt.pressure_ref_Pa, b.p_hi) || error("Pressure upper bounds differ.")
    same(data.bounds.temperature[1] .* opt.temperature_ref_K, b.T_lo) || error("Temperature lower bounds differ.")
    same(data.bounds.temperature[2] .* opt.temperature_ref_K, b.T_hi) || error("Temperature upper bounds differ.")
    same(data.bounds.flow[1][1:data.npipe] .* opt.flow_ref_kg_per_s, b.f_lo) || error("Flow lower bounds differ.")
    return nothing
end

# Every compared quantity: (group, element label, JuMP variable, SI scale, MadNLP value, Ipopt value).
function compared_quantities(t::TNFOModel, sol, ref)
    v, net = t.vars, t.net
    items = NamedTuple[]
    add!(group, label, var, scale, a, b) = push!(items, (; group, label, var, scale, a, b))
    for j in eachindex(net.junctions)
        side = net.junctions[j].side
        add!("pressure_$side", "junction $j", v.p[j], P0, sol.junction_pressure_Pa[j], ref.pressure_Pa[j])
        add!("temperature", "junction $j", v.T[j], TH0, sol.junction_temperature_K[j], ref.temperature_K[j])
    end
    for e in eachindex(net.pipes)
        add!("flow", "pipe $e", v.f[e], F0, sol.pipe_flow_kg_per_s[e], ref.pipe_flow[e])
        add!("temperature", "pipe $e inlet", v.Tin[e], TH0, sol.pipe_inlet_temp_K[e], ref.pipe_T_in[e])
        add!("temperature", "pipe $e outlet", v.Tout[e], TH0, sol.pipe_outlet_temp_K[e], ref.pipe_T_out[e])
    end
    for l in eachindex(net.loads)
        add!("flow", "load $l", v.fl[l], F0, sol.load_flow_kg_per_s[l], ref.load_flow[l])
        add!("temperature", "load $l inlet", v.Tl_in[l], TH0, sol.load_inlet_temp_K[l], ref.load_T_in[l])
        add!("temperature", "load $l outlet", v.Tl_out[l], TH0, sol.load_outlet_temp_K[l], ref.load_T_out[l])
    end
    add!("flow", "plant", v.fg, F0, sol.plant_flow_kg_per_s, ref.plant_flow)
    add!("temperature", "plant inlet", v.Tg_in, TH0, sol.plant_inlet_temp_K, ref.plant_T_in)
    add!("temperature", "plant outlet", v.Tg_out, TH0, sol.plant_outlet_temp_K, ref.plant_T_out)
    return items
end

function worst(items, prefix)
    selected = filter(i -> startswith(i.group, prefix), items)
    isempty(selected) && return (0.0, nothing)
    d, k = findmax(i -> relative_difference(i.a, i.b), selected)
    return (d, selected[k])
end

function solve_pair(net; tol)
    exa = build_steam_model(net)
    sol = solve_steam(exa; tol, max_iter = MAX_ITER, bound_relax_factor = 0.0)
    tnfo = build_tnfo(net; tol, max_iter = MAX_ITER)
    optimize!(tnfo.model)
    return exa, sol, tnfo, tnfo_solution(tnfo)
end

function differences(tnfo, sol, ref)
    items = compared_quantities(tnfo, sol, ref)
    return (
        items = items,
        objective = relative_difference(sol.objective_W, ref.objective_W),
        pressure = worst(items, "pressure")[1],
        pressure_steam = worst(items, "pressure_steam")[1],
        pressure_water = worst(items, "pressure_water")[1],
        temperature = worst(items, "temperature")[1],
        flow = worst(items, "flow")[1],
        plant_output = relative_difference(sol.plant_output_W, ref.plant_output_W),
    )
end

end_verified(status, violation) =
    status in ("LOCALLY_SOLVED", "ALMOST_LOCALLY_SOLVED") && violation <= 1.0e-6

function validate_instance(name, net, provenance)
    exa, sol, tnfo, ref = solve_pair(net; tol = TOL)
    audit_inputs(net, exa.data)
    d = differences(tnfo, sol, ref)
    row = (
        instance = name,
        data = "synthetic",
        n_junctions = length(net.junctions),
        n_variables = exa.nlp.meta.nvar,
        n_constraints = exa.nlp.meta.ncon,
        jump_n_variables = num_variables(tnfo.model),
        jump_n_constraints = num_constraints(tnfo.model; count_variable_in_set_constraints = false),
        madnlp_status = string(sol.status),
        ipopt_status = string(termination_status(tnfo.model)),
        tolerance = TOL,
        objective_madnlp_W = sol.objective_W,
        objective_ipopt_W = ref.objective_W,
        rel_diff_objective = d.objective,
        max_rel_diff_pressure = d.pressure,
        max_rel_diff_pressure_steam = d.pressure_steam,
        max_rel_diff_pressure_water = d.pressure_water,
        max_rel_diff_temperature = d.temperature,
        max_rel_diff_flow = d.flow,
        rel_diff_plant_output = d.plant_output,
        madnlp_point_max_violation_in_jump = tnfo_max_violation(tnfo, sol),
        n_loads_with_excess = count(>(1.0), ref.excess_W),
        n_loads_with_shed = count(>(1.0), ref.shed_W),
        commit_sha = provenance.commit,
        generator_commit = provenance.generator,
        model_commit = provenance.model,
        source_hash = provenance.sources,
    )

    # Where a quantity differs by more than the threshold, measure how far it can move at all
    # without the objective rising above what the two solvers already disagree on.
    slack = max(2 * abs(sol.objective_W - ref.objective_W), 1.0e-9 * abs(ref.objective_W))
    bound = min(sol.objective_W, ref.objective_W) + slack
    faces = NamedTuple[]
    for prefix in ("pressure_steam", "pressure_water", "temperature", "flow")
        gap, item = worst(d.items, prefix)
        (item === nothing || gap <= THRESHOLD) && continue
        r = tnfo_face_range(tnfo, item.var, item.scale, bound)
        low_ok = end_verified(r.low_status, r.low_violation)
        high_ok = end_verified(r.high_status, r.high_violation)
        # An unverified end falls back to the solver values, which are known to be near-optimal.
        low = low_ok ? min(r.low, item.a, item.b) : min(item.a, item.b)
        high = high_ok ? max(r.high, item.a, item.b) : max(item.a, item.b)
        push!(faces, (
            instance = name, quantity = prefix, element = item.label,
            madnlp_value = item.a, ipopt_value = item.b, rel_diff = gap,
            solver_gap = abs(item.a - item.b), objective_slack_W = slack,
            face_low = r.low, low_status = r.low_status, low_violation = r.low_violation,
            low_verified = low_ok, face_high = r.high, high_status = r.high_status,
            high_violation = r.high_violation, high_verified = high_ok,
            verified_width = high - low, width_over_gap = (high - low) / abs(item.a - item.b),
        ))
    end
    return row, faces
end

function ladder_rows(name, net)
    return map(LADDER) do tol
        _, sol, tnfo, ref = solve_pair(net; tol)
        d = differences(tnfo, sol, ref)
        (
            instance = name, tolerance = tol, madnlp_status = string(sol.status),
            ipopt_status = string(termination_status(tnfo.model)),
            rel_diff_objective = d.objective, max_rel_diff_pressure_steam = d.pressure_steam,
            max_rel_diff_pressure_water = d.pressure_water, max_rel_diff_temperature = d.temperature,
            max_rel_diff_flow = d.flow, rel_diff_plant_output = d.plant_output,
        )
    end
end

function sweep_row(n)
    net = scaled_campus(n)
    _, sol, tnfo, ref = solve_pair(net; tol = TOL)
    return (
        n_junctions = n, madnlp_status = string(sol.status),
        ipopt_status = string(termination_status(tnfo.model)), objective_madnlp_W = sol.objective_W,
        objective_ipopt_W = ref.objective_W, madnlp_shed_W = sum(sol.load_shed_W),
        madnlp_excess_W = sum(sol.load_excess_W), plant_output_W = sol.plant_output_W,
        plant_rating_W = net.plant.rating_W, design_heat_W = sum(l.design_heat_W for l in net.loads),
    )
end

format_cell(x::AbstractFloat) = @sprintf("%.10e", x)
format_cell(x) = replace(string(x), ',' => ';')

function write_rows(name, rows)
    path = joinpath(REPO, "results", name)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(keys(first(rows)), ','))
        for row in rows
            println(io, join(format_cell.(values(row)), ','))
        end
    end
    return path
end

solved_by_both(row) = row.madnlp_status == "SOLVE_SUCCEEDED" && row.ipopt_status == "LOCALLY_SOLVED"

function main()
    isempty(git("status", "--porcelain", "--", "src", "validation")) ||
        error("Commit the changes under src/ and validation/ first, so the recorded commit is exact.")
    commit = git("rev-parse", "HEAD")
    generator = git("log", "-1", "--format=%H", "--", "src/generator", "data/synthetic")
    model = git("log", "-1", "--format=%H", "--", "src/model", "src/network.jl")
    sources = validation_source_hash(REPO)

    sweep = [sweep_row(n) for n in SWEEP_SIZES]
    solved = sort([row.n_junctions for row in sweep if solved_by_both(row)])
    length(solved) >= N_VALIDATED_SIZES || error("Fewer than $N_VALIDATED_SIZES sizes solved by both solvers.")
    sizes = solved[(end - N_VALIDATED_SIZES + 1):end]
    write_rows("validation_size_sweep.csv", [(; row..., validated = row.n_junctions in sizes) for row in sweep])

    instances = [
        "upstream_example" => upstream_example_network,
        "demo_campus" => demo_campus,
        ["scaled_campus_$n" => (() -> scaled_campus(n)) for n in sizes]...,
    ]
    rows, faces, ladder = NamedTuple[], NamedTuple[], NamedTuple[]
    for (name, build) in instances
        println("Validating ", name)
        net = build()
        row, face = validate_instance(name, net, (; commit, generator, model, sources))
        println(row)
        push!(rows, row)
        append!(faces, face)
        append!(ladder, ladder_rows(name, net))
    end
    write_rows("validation.csv", rows)
    write_rows("validation_tolerance_ladder.csv", ladder)
    isempty(faces) || write_rows("validation_optimal_face.csv", faces)
    return rows
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()

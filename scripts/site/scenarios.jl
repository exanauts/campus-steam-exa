# Writes the operational scenarios of the demo campus to site/data/scenarios/ and the new-building
# study to site/data/expansion.json. The JSON schemas are documented under "Scenarios" and "New
# building study" in docs/site-data.md.

using JSON

include("scenario_cases.jl")
include("expansion_cases.jl")
include("pool.jl")

write_json(path, doc) = write(path, JSON.json(doc))

function log_run(name, run)
    s = run.solution
    println(rpad(name, 26), rpad(string(s.status), 28), "iterations ", lpad(s.iterations, 4),
        "  time ", lpad(round(run.elapsed_s; digits = 1), 6), " s")
    solved_at_tolerance(s) || @warn "Scenario $name did not converge at tolerance $SCENARIO_TOL; its numbers are withheld"
    return run
end

# The independent solves of the scenario part. Each is (name for the log, case builder, uniform
# priority weights).
const SCENARIO_SOLVES = [
    ("pipe_out", pipe_out_case, false),
    ("plant_derate", plant_derate_case, false),
    ("baseline", baseline_case, false),
    ("plant_derate, uniform", plant_derate_case, true),
    ("cold_snap", cold_snap_case, false),
    ("deeper_derate", deeper_derate_case, false),
    ("deeper_derate, uniform", deeper_derate_case, true),
]
# The cases of the new-building study, by name (`expansion_cases`).
const EXPANSION_SOLVES = ["today", "tomorrow", "larger_main", "cross_tie", "insulation", "extra_boiler"]
# Pool items, longest first so that a small pool finishes early: (:scenario, index into
# SCENARIO_SOLVES) or (:expansion, case name).
const PART_SOLVES = [
    [(:scenario, i) for i in 1:2]; [(:scenario, 4)]; [(:expansion, name) for name in EXPANSION_SOLVES];
    [(:scenario, i) for i in (3, 5, 6, 7)]
]
item_name(item) = item[1] === :scenario ? SCENARIO_SOLVES[item[2]][1] : "new_building/$(item[2])"

# The network and the demand year, built once per process.
const SCENARIO_INPUTS = Ref{Any}(nothing)
function scenario_inputs()
    if SCENARIO_INPUTS[] === nothing
        net = demo_campus()
        SCENARIO_INPUTS[] = (; net, profiles = generate_profiles(net))
    end
    return SCENARIO_INPUTS[]
end

# The cases of the new-building study and the demand year of tomorrow's network, built once per
# process. Every case except today has the same buildings, so they share one demand year.
const EXPANSION_INPUTS = Ref{Any}(nothing)
function expansion_inputs()
    if EXPANSION_INPUTS[] === nothing
        (; net, profiles) = scenario_inputs()
        cases = expansion_cases(net)
        tomorrow = generate_profiles(cases[2].net)
        EXPANSION_INPUTS[] = (; cases, profiles_of = c -> c.name == "today" ? profiles : tomorrow)
    end
    return EXPANSION_INPUTS[]
end

"Solve one item of `PART_SOLVES`, in whichever process runs it."
function scenario_solve(item)
    kind, key = item
    if kind === :expansion
        (; cases, profiles_of) = expansion_inputs()
        c = only(c for c in cases if c.name == key)
        return expansion_solve_case(c, profiles_of(c))
    end
    _, build, uniform = SCENARIO_SOLVES[key]
    (; net, profiles) = scenario_inputs()
    weights = uniform ? fill(UNIFORM_PRIORITY_WEIGHT, length(net.loads)) : nothing
    return solve_case(net, build(net, profiles); priority_weight = weights)
end

"""
    run_scenarios(outdir; expansion_path = joinpath(dirname(outdir), "expansion.json"),
                  workers = site_workers(length(PART_SOLVES)))

Solve every scenario and the cases of the new-building study on the CPU. Writes `network.json` and
one JSON file per scenario to `outdir`, and the study to `expansion_path`. A solve that does not
converge at the stated tolerance is written with its solver status only. The solves are independent
and run on a pool of `workers` processes (`scripts/site/pool.jl`); the files are written afterwards,
in this process, and do not depend on the worker count.
"""
function run_scenarios(outdir; expansion_path = joinpath(dirname(outdir), "expansion.json"),
                       workers = site_workers(length(PART_SOLVES)))
    started = time()
    mkpath(outdir)
    pids = start_pool(workers, [joinpath(@__DIR__, "scenarios.jl")])
    println("scenarios: $(length(PART_SOLVES)) solves on $(max(length(pids), 1)) process(es)")
    runs = try
        pool_map(scenario_solve, PART_SOLVES, pids;
            after = (item, run) -> (log_run(item_name(item), run); flush(stdout)))
    finally
        stop_pool(pids)
    end
    run_of = Dict(item_name(item) => run for (item, run) in zip(PART_SOLVES, runs))

    (; net, profiles) = scenario_inputs()
    write_json(joinpath(outdir, "network.json"), network_payload(net))

    base = baseline_case(net, profiles)
    base_run = run_of["baseline"]
    write_json(joinpath(outdir, "baseline.json"), scenario_payload(net, base, base_run))

    cold = cold_snap_case(net, profiles)
    write_json(joinpath(outdir, "cold_snap.json"), scenario_payload(net, cold, run_of["cold_snap"]))

    derate = plant_derate_case(net, profiles)
    derate_run = run_of["plant_derate"]
    stress = deeper_derate_case(net, profiles)
    comparison = priority_comparison(net, derate_run, run_of["plant_derate, uniform"], stress,
        run_of["deeper_derate"], run_of["deeper_derate, uniform"])
    write_json(joinpath(outdir, "plant_derate.json"), scenario_payload(net, derate, derate_run;
        extras = Dict{String, Any}("priority_comparison" => comparison)))

    outage = pipe_out_case(net, profiles)
    outage_run = run_of["pipe_out"]
    extras = Dict{String, Any}()
    if solved_at_tolerance(outage_run.solution) && solved_at_tolerance(base_run.solution)
        extras["reroute"] = reroute_summary(net, outage, outage_run.solution, base_run.solution)
    end
    write_json(joinpath(outdir, "pipe_out.json"), scenario_payload(net, outage, outage_run; extras))

    (; cases, profiles_of) = expansion_inputs()
    outcomes = [expansion_outcome(c, run_of[item_name((:expansion, c.name))], profiles_of(c)) for c in cases]
    study = expansion_payload(expansion_hours(profiles), outcomes)
    write_json(expansion_path, study)
    println("New-building study: ", study["limit"]["kind"], "; ", round(filesize(expansion_path) / 1.0e3; digits = 1), " kB")

    bytes = sum(filesize(joinpath(outdir, f)) for f in readdir(outdir))
    println("Scenario data: ", round(bytes / 1.0e6; digits = 2), " MB in ", length(readdir(outdir)),
        " files; total time ", round(time() - started; digits = 1), " s")
    return nothing
end

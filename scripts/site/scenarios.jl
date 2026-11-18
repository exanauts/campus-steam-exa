# Writes the operational scenarios of the demo campus to site/data/scenarios/.
# The JSON schema is documented under "Scenarios" in docs/site-data.md.

using JSON

include("scenario_cases.jl")

write_json(path, doc) = write(path, JSON.json(doc))

function log_run(name, run)
    s = run.solution
    println(rpad(name, 26), rpad(string(s.status), 28), "iterations ", lpad(s.iterations, 4),
        "  time ", lpad(round(run.elapsed_s; digits = 1), 6), " s")
    solved_at_tolerance(s) || @warn "Scenario $name did not converge at tolerance $SCENARIO_TOL; its numbers are withheld"
    return run
end

"""
    run_scenarios(outdir)

Solve every scenario on the CPU and write `network.json` and one JSON file per scenario to `outdir`.
A scenario that does not converge at the stated tolerance is written with its solver status only.
"""
function run_scenarios(outdir)
    started = time()
    mkpath(outdir)
    net = demo_campus()
    profiles = generate_profiles(net)
    write_json(joinpath(outdir, "network.json"), network_payload(net))

    base = baseline_case(net, profiles)
    base_run = log_run("baseline", solve_case(net, base))
    write_json(joinpath(outdir, "baseline.json"), scenario_payload(net, base, base_run))

    cold = cold_snap_case(net, profiles)
    cold_run = log_run("cold_snap", solve_case(net, cold))
    write_json(joinpath(outdir, "cold_snap.json"), scenario_payload(net, cold, cold_run))

    derate = plant_derate_case(net, profiles)
    derate_run = log_run("plant_derate", solve_case(net, derate))
    uniform = log_run("plant_derate, uniform",
        solve_case(net, derate; priority_weight = fill(UNIFORM_PRIORITY_WEIGHT, length(net.loads))))
    stress = deeper_derate_case(net, profiles)
    stress_weighted = log_run("deeper_derate", solve_case(net, stress))
    stress_uniform = log_run("deeper_derate, uniform",
        solve_case(net, stress; priority_weight = fill(UNIFORM_PRIORITY_WEIGHT, length(net.loads))))
    comparison = priority_comparison(net, derate_run, uniform, stress, stress_weighted, stress_uniform)
    write_json(joinpath(outdir, "plant_derate.json"), scenario_payload(net, derate, derate_run;
        extras = Dict{String, Any}("priority_comparison" => comparison)))

    outage = pipe_out_case(net, profiles)
    outage_run = log_run("pipe_out", solve_case(net, outage))
    extras = Dict{String, Any}()
    if solved_at_tolerance(outage_run.solution) && solved_at_tolerance(base_run.solution)
        extras["reroute"] = reroute_summary(net, outage, outage_run.solution, base_run.solution)
    end
    write_json(joinpath(outdir, "pipe_out.json"), scenario_payload(net, outage, outage_run; extras))

    bytes = sum(filesize(joinpath(outdir, f)) for f in readdir(outdir))
    println("Scenario data: ", round(bytes / 1.0e6; digits = 2), " MB in ", length(readdir(outdir)),
        " files; total time ", round(time() - started; digits = 1), " s")
    return nothing
end

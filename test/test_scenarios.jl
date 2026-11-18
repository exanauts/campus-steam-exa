module ScenarioTests

using Test

include(joinpath(@__DIR__, "..", "scripts", "site", "scenario_cases.jl"))

const NET = demo_campus()
const PROFILES = generate_profiles(NET; hours = last(NORMAL_WEEK))

mwh(a) = sum(a) / 1.0e6

@testset "operational scenarios" begin
    @testset "the scenario hours match the generated weather" begin
        week = cold_snap_week(PROFILES)
        @test length(week) == 168
        @test !any(PROFILES.is_cold_snap[NORMAL_WEEK])
        @test one_boiler_out_W(NET) == 82.5e6
        @test maximum(sum(PROFILES.heat_W[week, :]; dims = 2)) > one_boiler_out_W(NET)
    end

    @testset "the surge builds within the plant ramp limit" begin
        factors = surge_factors(168, SURGE_PERIODS)
        @test count(==(SURGE_FACTOR), factors) == length(SURGE_PERIODS)
        @test factors[1] == 1 && factors[168] == 1
        @test maximum(abs.(diff(factors))) <= 0.125 + 1.0e-12
    end

    @testset "cold snap raises plant output without shedding" begin
        hours = NORMAL_WEEK[1:24]
        base = solve_case(NET, baseline_case(NET, PROFILES; hours)).solution
        cold = solve_case(NET, cold_snap_case(NET, PROFILES; hours, surge = 10:15)).solution
        @test solved_at_tolerance(base) && solved_at_tolerance(cold)
        @test all(cold.plant_output_W[10:15] .> 1.3 .* base.plant_output_W[10:15])
        @test cold.plant_output_W[1] ≈ base.plant_output_W[1] rtol = 0.02
        @test mwh(base.load_shed_W) < 1.0e-3
        @test mwh(cold.load_shed_W) < 1.0e-3
    end

    @testset "only the derate sheds, and the priority weights choose who" begin
        hours = cold_snap_week(PROFILES)[51:59]
        full = solve_case(NET, plant_derate_case(NET, PROFILES; hours, outage = 1:0)).solution
        case = plant_derate_case(NET, PROFILES; hours, outage = 1:9)
        weighted = solve_case(NET, case).solution
        uniform = solve_case(NET, case; priority_weight = fill(UNIFORM_PRIORITY_WEIGHT, length(NET.loads))).solution
        @test solved_at_tolerance(full) && solved_at_tolerance(weighted) && solved_at_tolerance(uniform)

        @test mwh(full.load_shed_W) < 1.0e-3
        @test all(weighted.plant_output_W .<= one_boiler_out_W(NET) + 10.0)
        shortfall = sum(case.heat_W) - sum(case.rating_W)
        @test sum(weighted.load_shed_W) >= shortfall
        @test mwh(weighted.load_shed_W[:, load_ids_of_type(NET, "critical")]) < 1.0e-3
        for type in ("critical", "lab", "housing")
            @test mwh(weighted.load_shed_W[:, load_ids_of_type(NET, type)]) < 1.0e-3
        end
        @test mwh(weighted.load_shed_W[:, load_ids_of_type(NET, "classroom")]) > 1.0
        # Equal weights move shed load from the classrooms onto the labs.
        @test mwh(uniform.load_shed_W[:, load_ids_of_type(NET, "lab")]) > 1.0
    end

    @testset "the priority weights protect critical load in a deeper derate" begin
        case = deeper_derate_case(NET, PROFILES)
        critical = load_ids_of_type(NET, "critical")
        weighted = solve_case(NET, case).solution
        uniform = solve_case(NET, case; priority_weight = fill(UNIFORM_PRIORITY_WEIGHT, length(NET.loads))).solution
        @test solved_at_tolerance(weighted) && solved_at_tolerance(uniform)
        @test mwh(weighted.load_shed_W[:, critical]) < 1.0e-3
        @test mwh(uniform.load_shed_W[:, critical]) > 10.0
    end

    @testset "flow reroutes around a steam main outage" begin
        hours = NORMAL_WEEK[49:60]
        periods = 4:9
        reference = solve_case(NET, baseline_case(NET, PROFILES; hours)).solution
        case = pipe_out_case(NET, PROFILES; hours, outage = periods)
        run = solve_case(NET, case)
        s = run.solution
        @test solved_at_tolerance(s)
        @test occursin("solve_multiperiod_oriented", run.method)
        @test mwh(s.load_shed_W) < 1.0e-3
        @test !any(s.pipe_in_service[periods, OUTAGE_PIPE])
        @test all(s.pipe_in_service[setdiff(1:12, periods), OUTAGE_PIPE])
        @test all(iszero, s.pipe_flow_kg_per_s[periods, OUTAGE_PIPE])

        steam = [p.id for p in NET.pipes if p.side == "steam" && p.id != OUTAGE_PIPE]
        change = abs.(s.pipe_flow_kg_per_s[periods, steam] .- reference.pipe_flow_kg_per_s[periods, steam])
        @test maximum(change) > 1.0
        summary = reroute_summary(NET, case, s, reference)
        @test !isempty(summary["reversed_steam_pipes"])
    end

    @testset "exported data" begin
        hours = NORMAL_WEEK[1:2]
        case = baseline_case(NET, PROFILES; hours)
        run = solve_case(NET, case)
        doc = scenario_payload(NET, case, run)
        @test doc["presented"] && doc["synthetic"]
        @test all(id -> NET.junctions[id].side == "steam", doc["nodes"]["ids"])
        @test length(doc["pipes"]["flow_kg_s"]) == 2
        @test doc["uniqueness"]["water_pressure"] == "not_exported"
        @test occursin("Example University", doc["data_label"])
        @test network_payload(NET)["plant"]["one_boiler_out_MW"] == 82.5

        @test runs([true, true, false, true]) == [[1, 2], [4, 4]]
        @test compact(1.04, 1) === 1
        @test compact(1.25, 1) == 1.2

        # A solve that stops short of the tolerance is reported without its numbers.
        short = (; solution = (; status = :SOLVED_TO_ACCEPTABLE_LEVEL, iterations = 5), method = "m", rounds = 1, elapsed_s = 1.0)
        withheld = scenario_payload(NET, case, short)
        @test !withheld["presented"]
        @test !haskey(withheld, "summary") && !haskey(withheld, "plant") && !haskey(withheld, "pipes")
    end
end

end # module

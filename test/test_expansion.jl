module ExpansionTests

using Test
using CampusSteam
using MadNLP: MadNLP

include(joinpath(@__DIR__, "..", "scripts", "site", "scenario_cases.jl"))
include(joinpath(@__DIR__, "..", "scripts", "site", "expansion_cases.jl"))

const NET = demo_campus()

same_except(a, b, ids) = all(a.pipes[i] == b.pipes[i] for i in eachindex(a.pipes) if !(i in ids))

@testset "network edits" begin
    @testset "a new building follows the generator's rules" begin
        tap = NEW_BUILDING_TAP
        net, ids = add_building(NET; tap, x_m = 600.0, y_m = 780.3, type = "lab", design_heat_W = 3.0e6)
        @test validate_network(net) === net
        @test length(net.loads) == length(NET.loads) + 1
        @test length(net.junctions) == length(NET.junctions) + 2
        @test length(net.pipes) == length(NET.pipes) + 2
        load = net.loads[ids.load]
        @test load.name == "Lab 17" && load.type == "lab" && load.priority_weight == 10.0
        @test load.steam_junction == ids.steam_junction && load.water_junction == ids.water_junction
        @test water_partner(net, ids.steam_junction) == ids.water_junction
        steam, water = net.pipes[ids.steam_pipe], net.pipes[ids.water_pipe]
        @test (steam.from, steam.to) == (tap, ids.steam_junction)
        @test (water.from, water.to) == (ids.water_junction, water_partner(NET, tap))
        @test !steam.is_loop && !water.is_loop
        # A 3 MW lab gets the same lateral sizes as the generated labs of about that size.
        similar = [l for l in NET.loads if l.type == "lab" && abs(l.design_heat_W - 3.0e6) < 0.25e6]
        @test !isempty(similar)
        lateral(l) = only(p for p in NET.pipes if p.side == "steam" && p.to == l.steam_junction)
        @test all(lateral(l).diameter_m == steam.diameter_m for l in similar)
        @test water.max_pump_boost_Pa > 0
        # Existing ids and pieces are unchanged.
        @test net.junctions[1:length(NET.junctions)] == NET.junctions
        @test net.loads[1:length(NET.loads)] == NET.loads
        @test all(net.pipes[i].diameter_m == NET.pipes[i].diameter_m for i in eachindex(NET.pipes))
        # Defaults: middle of the type's range and the next free name.
        housing, _ = add_building(NET; tap = 36, x_m = -670.0, y_m = 907.8, type = "housing")
        @test housing.loads[end].design_heat_W == 1.1e6 && housing.loads[end].name == "Housing 17"
        @test_throws ArgumentError add_building(NET; tap = 1, x_m = 0.0, y_m = -60.0, type = "lab")
        @test_throws ArgumentError add_building(NET; tap, x_m = 600.0, y_m = 780.3, type = "office")
        @test_throws ArgumentError add_building(NET; tap = NET.loads[1].steam_junction, x_m = 0.0, y_m = 0.0, type = "lab")
    end

    @testset "the profile generator gives the new building a profile of its type" begin
        net, ids = add_building(NET; tap = NEW_BUILDING_TAP, x_m = 600.0, y_m = 780.3, type = "lab", design_heat_W = 3.0e6)
        before = generate_profiles(NET; hours = 1200)
        after = generate_profiles(net; hours = 1200)
        @test after.heat_W[:, 1:length(NET.loads)] == before.heat_W
        new = after.heat_W[:, ids.load]
        @test all(>(0), new)
        # A lab's demand never falls below its weather-independent share, and peaks near design heat
        # in the cold snap.
        @test minimum(new) >= 0.9 * 0.30 * 0.90 * 3.0e6
        week = cold_snap_week(after)
        @test 0.95 * 3.0e6 <= maximum(new[week]) <= 1.3 * 3.0e6
    end

    @testset "a pipe pair closes a loop" begin
        net, ids = add_pipe_pair(NET, TIE_FROM, NEW_BUILDING_TAP; diameter_m = 0.3)
        @test validate_network(net) === net
        steam, water = net.pipes[ids.steam_pipe], net.pipes[ids.water_pipe]
        @test minmax(steam.from, steam.to) == minmax(TIE_FROM, NEW_BUILDING_TAP)
        @test minmax(water.from, water.to) == minmax(water_partner(NET, TIE_FROM), water_partner(NET, NEW_BUILDING_TAP))
        @test water.diameter_m == 0.12
        @test steam.is_loop && water.is_loop
        # The dead-end branch to the tap is now part of a loop.
        @test all(net.pipes[id].is_loop for id in (17, 38))
        @test !NET.pipes[38].is_loop
        @test_throws ArgumentError add_pipe_pair(NET, 2, 2; diameter_m = 0.3)
        @test_throws ArgumentError add_pipe_pair(NET, 2, 90; diameter_m = 0.3)
    end

    @testset "a larger pipe and better insulation change only those pipes" begin
        main = [id for id in steam_path(NET, NEW_BUILDING_TAP) if !NET.pipes[id].is_loop]
        @test main == [17, 38]
        @test first(steam_path(NET, NEW_BUILDING_TAP)) in (1, 2)
        big = resize_pipe(NET, main; diameter_m = 0.45)
        changed = Int[]
        for id in main
            p, q = NET.pipes[id], big.pipes[id]
            @test q.diameter_m == 0.45
            @test q.friction_factor < p.friction_factor
            @test q.heat_loss_W_per_m2K == p.heat_loss_W_per_m2K
            push!(changed, id)
            w = only(x for x in NET.pipes if x.side == "water" &&
                minmax(x.from, x.to) == minmax(water_partner(NET, p.from), water_partner(NET, p.to)))
            @test big.pipes[w.id].diameter_m == 0.18
            push!(changed, w.id)
        end
        @test same_except(NET, big, changed)

        trunk = [1, 2, 3]
        cool = scale_heat_loss(NET, trunk, 0.5)
        for id in trunk
            @test cool.pipes[id].heat_loss_W_per_m2K ≈ NET.pipes[id].heat_loss_W_per_m2K / 2 atol = 1.0e-4
        end
        @test same_except(NET, cool, trunk)
        @test_throws ArgumentError resize_pipe(NET, [findfirst(p -> p.side == "water", NET.pipes)]; diameter_m = 0.1)
    end

    @testset "an extra boiler raises the rating in proportion" begin
        net = add_boiler(NET)
        @test net.plant.n_boilers == 5 && net.plant.rating_W == 137.5e6
        @test net.plant.ramp_limit_W_per_h == 0.25 * net.plant.rating_W
        @test net.pipes == NET.pipes
    end

    @testset "the study's cases and one small solve" begin
        cases = expansion_cases(NET)
        @test [c.name for c in cases] == ["today", "tomorrow", "larger_main", "cross_tie", "insulation", "extra_boiler"]
        @test cases[1].net == NET
        @test all(length(c.net.loads) == length(NET.loads) + 1 for c in cases[2:end])
        @test cases[end].rating_W > cases[2].rating_W

        # Two peak hours of the cold-snap week, today and tomorrow.
        profiles = generate_profiles(cases[2].net; hours = 1100)
        hours = expansion_hours(profiles)
        peak = first(hours) - 1 .+ (argmax(vec(sum(profiles.heat_W[hours, :]; dims = 2))) .+ (0:1))
        outcomes = map(cases[1:2]) do c
            heat = profiles.heat_W[peak, 1:length(c.net.loads)]
            run = expansion_solve(c.net, heat, fill(c.rating_W, 2))
            @test solved_at_tolerance(run.solution)
            entry = expansion_outcome(c, run, profiles)
            @test entry["converged"]
            entry
        end
        @test outcomes[1]["summary"]["total_shed_MWh"] < SHED_REPORT_MIN_MWH
        @test outcomes[2]["new_building"]["peak_demand_MW"] > 0
        @test haskey(outcomes[2]["shed_by_type_MWh"], "lab")
        limit = limiting_factor(outcomes)
        @test limit["kind"] in ("none", "plant_capacity", "network", "plant_and_network")

        # A case that stops short of the tolerance is reported as such, without numbers.
        short = (; solution = (; status = :SOLVED_TO_ACCEPTABLE_LEVEL, iterations = 5), method = "m", rounds = 1, elapsed_s = 1.0)
        withheld = expansion_outcome(cases[2], short, profiles)
        @test !withheld["converged"] && !haskey(withheld, "summary") && !haskey(withheld, "shed_by_type_MWh")
        @test limiting_factor([withheld])["kind"] == "not_available"
    end
end

end # module

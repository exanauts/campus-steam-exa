using CampusSteam
using Test

const CS = CampusSteam
const DEMO_DIR = joinpath(dirname(@__DIR__), "data", "synthetic", "demo")

side_pipes(net, side) = [p for p in net.pipes if p.side == side]

# True when the directed pipes of one side contain no cycle (Kahn's algorithm).
function is_acyclic(net, side)
    pipes = side_pipes(net, side)
    indegree = zeros(Int, length(net.junctions))
    outgoing = [Int[] for _ in net.junctions]
    for p in pipes
        indegree[p.to] += 1
        push!(outgoing[p.from], p.to)
    end
    ready = [j.id for j in net.junctions if j.side == side && indegree[j.id] == 0]
    visited = 0
    while !isempty(ready)
        j = pop!(ready)
        visited += 1
        for i in outgoing[j]
            indegree[i] -= 1
            indegree[i] == 0 && push!(ready, i)
        end
    end
    return visited == count(j -> j.side == side, net.junctions)
end

function check_flow_directions(net)
    for side in ("steam", "water")
        @test is_acyclic(net, side)
        reached = CS._directed_reach(net, side)
        @test all(reached[CS._load_junction(l, side)] for l in net.loads)
    end
    plant = net.plant
    @test all(p.from == plant.steam_junction || p.to != plant.steam_junction
              for p in side_pipes(net, "steam"))
    @test all(p.to == plant.water_junction || p.from != plant.water_junction
              for p in side_pipes(net, "water"))
end

# Largest reversed flow, relative to the largest flow, when `heat` is served.
function reversed_flow(net, side, heat)
    pipes = side_pipes(net, side)
    local_id = zeros(Int, length(net.junctions))
    members = [j.id for j in net.junctions if j.side == side]
    local_id[members] = eachindex(members)
    injection = zeros(length(members))
    sign = side == "steam" ? -1.0 : 1.0
    for load in net.loads
        injection[local_id[CS._load_junction(load, side)]] += sign * heat[load.id] / 1e6
    end
    root = local_id[CS._plant_junction(net, side)]
    injection[root] -= sum(injection)
    _, phi = CS._solve_hydraulics(length(members), [local_id[p.from] for p in pipes],
                                  [local_id[p.to] for p in pipes],
                                  [CS._pipe_resistance(p) for p in pipes], injection, root)
    return max(0.0, -minimum(phi)) / maximum(abs, phi)
end

@testset "Generator" begin
    net = demo_campus()

    @testset "Schema conformance" begin
        @test fieldnames(Junction) == (:id, :side, :kind, :x_m, :y_m)
        @test fieldnames(CS.Pipe) == (:id, :side, :from, :to, :length_m, :diameter_m, :friction_factor,
                                   :heat_loss_W_per_m2K, :max_pump_boost_Pa, :is_loop)
        @test fieldnames(Load) == (:id, :name, :type, :steam_junction, :water_junction,
                                   :design_heat_W, :priority_weight)
        @test fieldnames(Plant) == (:steam_junction, :water_junction, :rating_W, :n_boilers,
                                    :ramp_limit_W_per_h, :supply_temp_K, :supply_pressure_Pa,
                                    :return_pressure_Pa)
        @test fieldnames(CampusNetwork) == (:junctions, :pipes, :loads, :plant)
        @test fieldnames(LoadProfiles) == (:outdoor_temp_C, :is_cold_snap, :heat_W)
        @test validate_network(net) === net

        mktempdir() do dir
            write_network(dir, net)
            profiles = generate_profiles(net; hours = 48)
            write_profiles(dir, profiles)
            header(name) = readline(joinpath(dir, name))
            @test header("junctions.csv") == "id,side,kind,x_m,y_m"
            @test header("pipes.csv") == "id,side,from,to,length_m,diameter_m,friction_factor," *
                                         "heat_loss_W_per_m2K,max_pump_boost_Pa,is_loop"
            @test header("loads.csv") == "id,name,type,steam_junction,water_junction," *
                                         "design_heat_W,priority_weight"
            @test header("plant.csv") == "steam_junction,water_junction,rating_W,n_boilers," *
                                         "ramp_limit_W_per_h,supply_temp_K,supply_pressure_Pa," *
                                         "return_pressure_Pa"
            @test header("weather.csv") == "hour,outdoor_temp_C,is_cold_snap"
            @test header("load_profiles.csv") == "hour,load_id,heat_W"
            @test read_network(dir) == net
            @test read_profiles(dir) == profiles
        end
    end

    @testset "Contiguous ids" begin
        @test [j.id for j in net.junctions] == 1:length(net.junctions)
        @test [p.id for p in net.pipes] == 1:length(net.pipes)
        @test [l.id for l in net.loads] == 1:length(net.loads)
    end

    @testset "Demo campus contents" begin
        @test 130 <= length(net.junctions) <= 140
        @test length(net.loads) == 45
        @test Set(l.type for l in net.loads) == Set(["lab", "housing", "classroom", "critical"])
        @test allunique(l.name for l in net.loads)
        @test count(p -> p.is_loop, side_pipes(net, "steam")) > 0
        @test count(p -> p.is_loop, side_pipes(net, "water")) > 0
        @test count(p -> p.max_pump_boost_Pa > 0, net.pipes) > 0
        @test all(p -> p.max_pump_boost_Pa == 0, side_pipes(net, "steam"))
        critical = maximum(l.priority_weight for l in net.loads if l.type == "critical")
        @test critical > maximum(l.priority_weight for l in net.loads if l.type != "critical")
    end

    @testset "Physical plausibility" begin
        @test all(0.05 <= p.diameter_m <= 1.2 for p in side_pipes(net, "steam"))
        @test all(0.05 <= p.diameter_m <= 1.2 for p in side_pipes(net, "water"))
        @test all(0.009 <= p.friction_factor <= 0.03 for p in net.pipes)
        @test all(1.0 <= p.heat_loss_W_per_m2K <= 2.0 for p in net.pipes)
        @test all(0.3e6 <= l.design_heat_W <= 4.5e6 for l in net.loads)
        design = sum(l.design_heat_W for l in net.loads)
        @test net.plant.rating_W >= 1.3 * design
        @test net.plant.supply_pressure_Pa > net.plant.return_pressure_Pa
    end

    @testset "Drawing layout" begin
        width, depth = BUILDING_FOOTPRINT_M
        buildings = [net.junctions[l.steam_junction] for l in net.loads]
        overlaps = 0
        for a in eachindex(buildings), b in (a + 1):length(buildings)
            dx = abs(buildings[a].x_m - buildings[b].x_m)
            dy = abs(buildings[a].y_m - buildings[b].y_m)
            overlaps += (dx < width && dy < depth)
        end
        @test overlaps == 0
    end

    @testset "Connectivity of both sides" begin
        check_flow_directions(net)
        for side in ("steam", "water")
            pipes = side_pipes(net, side)
            hops = CS._hops(length(net.junctions), [p.from for p in pipes], [p.to for p in pipes],
                            CS._plant_junction(net, side))
            @test all(hops[j.id] >= 0 for j in net.junctions if j.side == side)
        end
    end

    @testset "Determinism" begin
        bytes(dir) = Dict(name => read(joinpath(dir, name)) for name in readdir(dir))
        function files(seed)
            campus = demo_campus(; seed)
            dir = mktempdir()
            write_network(dir, campus)
            write_profiles(dir, generate_profiles(campus; seed, hours = 240))
            return bytes(dir)
        end
        first_run = files(1)
        @test first_run == files(1)
        @test first_run != files(2)
        @test scaled_campus(600; seed = 3) == scaled_campus(600; seed = 3)
    end

    @testset "Committed demo files match the generator" begin
        mktempdir() do dir
            write_network(dir, net)
            write_weather(dir, generate_profiles(net; hours = 8760))
            for name in ("junctions.csv", "pipes.csv", "loads.csv", "plant.csv", "weather.csv")
                @test read(joinpath(dir, name)) == read(joinpath(DEMO_DIR, name))
            end
        end
    end

    @testset "Scaled campuses" begin
        large = scaled_campus(10_000)
        @test length(large.junctions) == 10_000
        @test validate_network(large) === large
        check_flow_directions(large)
        @test sum(l.design_heat_W for l in large.loads) <= 250e6 * (1 + 1e-3)
        @test large.plant.rating_W >= 1.3 * sum(l.design_heat_W for l in large.loads)
        for n in (40, 134, 1_000)
            @test length(scaled_campus(n).junctions) == n
        end
        @test_throws ArgumentError scaled_campus(1_001)
        @test_throws ArgumentError scaled_campus(10)
    end

    @testset "Weather and load profiles" begin
        profiles = generate_profiles(net)
        @test size(profiles.heat_W) == (8760, length(net.loads))
        @test all(>=(0), profiles.heat_W)

        snap = findall(profiles.is_cold_snap)
        @test length(snap) == 168
        @test snap == snap[1]:snap[end]
        @test 15 * 24 < snap[1] && snap[end] <= 45 * 24 + 1
        @test minimum(profiles.outdoor_temp_C[snap]) == -22.0
        @test minimum(profiles.outdoor_temp_C[.!profiles.is_cold_snap]) >= -14.0

        total = vec(sum(profiles.heat_W; dims = 2))
        @test argmax(total) in snap
        @test maximum(total) <= net.plant.rating_W
        # Losing one boiler in the cold snap leaves too little capacity, but not otherwise.
        firm = net.plant.rating_W * (net.plant.n_boilers - 1) / net.plant.n_boilers
        @test maximum(total) > firm
        @test maximum(total[.!profiles.is_cold_snap]) < firm

        summer = 4000:4400
        winter = 1:300
        @test sum(total[winter]) / length(winter) > 2 * sum(total[summer]) / length(summer)

        classroom = findfirst(l -> l.type == "classroom", net.loads)
        hour_of(day, hod) = 24 * day + hod + 1
        weeks = 40:50
        weekday = sum(profiles.heat_W[hour_of(7w, 12), classroom] for w in weeks)
        weekend = sum(profiles.heat_W[hour_of(7w + 5, 12), classroom] for w in weeks)
        @test weekend < weekday

        short = generate_profiles(net; hours = 24)
        @test short.heat_W == profiles.heat_W[1:24, :]
        @test_throws ArgumentError generate_profiles(net; hours = 0)
        @test_throws ArgumentError generate_profiles(net; hours = 8761)

        # The intact network never needs a pipe to run backward during the year.
        worst = maximum(reversed_flow(net, side, view(profiles.heat_W, h, :))
                        for side in ("steam", "water"), h in 1:8760)
        @test worst == 0
    end

    @testset "orient_network" begin
        @test orient_network(net) == net
        loop_pipes = [p for p in net.pipes if p.is_loop]
        @test length(loop_pipes) == 66
        pumps = count(p -> p.max_pump_boost_Pa > 0, net.pipes)
        for out in loop_pipes
            oriented = orient_network(net; out_of_service = [out.id])
            @test length(oriented.pipes) == length(net.pipes) - 1
            @test validate_network(oriented) === oriented
            check_flow_directions(oriented)
            @test count(p -> p.max_pump_boost_Pa > 0, oriented.pipes) ==
                  pumps - (out.max_pump_boost_Pa > 0)
        end
    end

    @testset "Outages that disconnect a load" begin
        for side in ("steam", "water")
            lateral = first(p for p in side_pipes(net, side) if !p.is_loop)
            err = try
                orient_network(net; out_of_service = [lateral.id])
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("disconnects", err.msg)
            @test occursin(side, err.msg)
        end
        @test_throws ArgumentError orient_network(net; out_of_service = [length(net.pipes) + 1])
    end
end

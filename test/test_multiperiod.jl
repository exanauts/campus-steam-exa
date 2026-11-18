using CampusSteam
using Test

# `small_campus`, `maxabs` and `check_residuals` come from test_model.jl, which runs first.

design_heat(net) = [l.design_heat_W for l in net.loads]
heat_profile(net, scales) = reduce(vcat, (s .* design_heat(net)' for s in scales))

function check_periods(model, sol)
    for k in 1:sol.nperiod
        r = physical_residuals(model, sol, k)
        steam = findall(model.data.templates[model.data.template_of[k]].data.pipe_is_steam)
        from = model.data.templates[model.data.template_of[k]].data.pipe_from[steam]
        @test maxabs(r.mass_kg_per_s) < 1.0e-5
        @test maxabs(r.energy_W) < 10.0
        @test maxabs(r.mixing_K) < 1.0e-5
        @test maxabs(r.decay_K) < 1.0e-4
        @test maxabs(r.steam_pressure_Pa2 ./ (2 .* sol.junction_pressure_Pa[k, from])) < 0.1
        @test maxabs(r.water_pressure_Pa) < 0.1
        @test maxabs(r.load_heat_W) < 10.0
        @test maximum(r.load_pressure_Pa) < 0.1
        @test only(r.plant_cap_W) < 10.0
    end
    return nothing
end

@testset "multi-period steam model" begin
    @testset "one period matches the single-period model" begin
        for net in (small_campus(), demo_campus())
            single = solve_steam(build_steam_model(net))
            model = build_multiperiod_model(net; heat_W = heat_profile(net, [1.0]))
            multi = solve_multiperiod(model)

            @test multi.status === single.status
            @test multi.iterations == single.iterations
            @test multi.objective_Wh ≈ single.objective_W rtol = 1.0e-10
            @test vec(multi.junction_pressure_Pa) ≈ single.junction_pressure_Pa rtol = 1.0e-10
            @test vec(multi.junction_temperature_K) ≈ single.junction_temperature_K rtol = 1.0e-10
            @test vec(multi.pipe_flow_kg_per_s) ≈ single.pipe_flow_kg_per_s rtol = 1.0e-10
            @test vec(multi.load_shed_W) ≈ single.load_shed_W atol = 1.0e-6
            @test only(multi.plant_output_W) ≈ single.plant_output_W rtol = 1.0e-10

            reference = build_steam_model(net)
            @test model.nlp.meta.nvar == reference.nlp.meta.nvar
            @test model.nlp.meta.ncon == reference.nlp.meta.ncon
            @test model.nlp.meta.nnzj == reference.nlp.meta.nnzj
        end
    end

    @testset "problem size grows linearly and adds one ramp row per transition" begin
        net = small_campus()
        one = build_multiperiod_model(net; heat_W = heat_profile(net, [1.0])).nlp.meta
        four = build_multiperiod_model(net; heat_W = heat_profile(net, fill(1.0, 4))).nlp.meta
        @test four.nvar == 4 * one.nvar
        @test four.ncon == 4 * one.ncon + 3
        @test four.nnzj == 4 * one.nnzj + 6
    end

    @testset "uncoupled periods match independent solves" begin
        net = small_campus()
        scales = [0.6, 1.0, 0.8]
        heat = heat_profile(net, scales)
        model = build_multiperiod_model(net; heat_W = heat, ramp_limit_W_per_h = Inf)
        @test model.cons.ramp === nothing
        sol = solve_multiperiod(model)
        @test sol.converged
        for (k, s) in enumerate(scales)
            single = solve_steam(net; heat_W = s .* design_heat(net))
            @test sol.plant_output_W[k] ≈ single.plant_output_W rtol = 1.0e-5
            @test sol.pipe_flow_kg_per_s[k, :] ≈ single.pipe_flow_kg_per_s rtol = 1.0e-3
        end
    end

    @testset "a binding ramp limit changes the dispatch and is respected" begin
        net = small_campus()
        heat = heat_profile(net, [0.5, 0.5, 1.0, 1.0, 0.5, 0.5])
        free = solve_multiperiod(net; heat_W = heat, ramp_limit_W_per_h = Inf)
        @test maximum(abs, diff(free.plant_output_W)) > 2.0e6

        limit = 1.0e6
        model = build_multiperiod_model(net; heat_W = heat, ramp_limit_W_per_h = limit)
        limited = solve_multiperiod(model)
        @test limited.status === :SOLVE_SUCCEEDED
        check_periods(model, limited)

        @test maximum(abs, diff(limited.plant_output_W)) <= limit * (1 + 1.0e-5)
        @test maximum(abs, diff(limited.plant_output_W)) >= limit * (1 - 1.0e-5)
        @test maxabs(limited.plant_output_W .- free.plant_output_W) > 1.0e5
        # The ramp costs something: unserved or surplus heat appears around the step.
        @test sum(limited.load_shed_W) + sum(limited.load_excess_W) >
            sum(free.load_shed_W) + sum(free.load_excess_W) + 1.0e5
        @test limited.objective_Wh > free.objective_Wh
    end

    @testset "a period-varying rating sheds load only in those hours" begin
        net = small_campus()
        heat = heat_profile(net, fill(1.0, 6))
        rating = [8.0e6, 8.0e6, 3.0e6, 3.0e6, 8.0e6, 8.0e6]
        model = build_multiperiod_model(net; heat_W = heat, plant_rating_W = rating)
        sol = solve_multiperiod(model)
        audit = energy_audit(sol)

        @test sol.status === :SOLVE_SUCCEEDED
        check_periods(model, sol)
        @test all(audit.shed_W[3:4] .> 1.0e6)
        @test all(audit.shed_W[[1, 2, 5, 6]] .< 1.0)
        @test sol.plant_output_W[3:4] ≈ [3.0e6, 3.0e6] rtol = 1.0e-5
        @test sol.plant_rating_W == rating
    end

    @testset "a forced derate does not shed load ahead of the outage" begin
        net = small_campus()
        heat = heat_profile(net, fill(1.0, 5))
        rating = [8.0e6, 8.0e6, 3.0e6, 3.0e6, 3.0e6]
        limit = 0.5e6
        model = build_multiperiod_model(
            net; heat_W = heat, plant_rating_W = rating, ramp_limit_W_per_h = limit,
        )
        sol = solve_multiperiod(model)
        @test sol.status === :SOLVE_SUCCEEDED
        @test sol.ramp_down_W_per_h[2] == 5.0e6
        @test sol.ramp_up_W_per_h[2] == limit
        @test sum(sol.load_shed_W[1:2, :]) < 1.0
        @test sol.plant_output_W[2] - sol.plant_output_W[3] > limit
    end

    @testset "the priority weight protects critical loads" begin
        net = small_campus()
        critical = only(l.id for l in net.loads if l.type == "critical")
        housing = only(l.id for l in net.loads if l.type == "housing")
        heat = heat_profile(net, fill(1.0, 2))

        sol = solve_multiperiod(net; heat_W = heat, plant_rating_W = 3.0e6)
        @test sol.converged
        @test all(sol.load_shed_W[:, critical] .< 1.0)
        @test all(sol.load_shed_W[:, housing] .> 1.0e5)

        # Inverting the weights in period 2 only moves the shedding to the critical load there.
        weights = repeat([l.priority_weight for l in net.loads]', 2, 1)
        weights[2, critical] = 0.1
        swapped = solve_multiperiod(
            net; heat_W = heat, plant_rating_W = 3.0e6, priority_weight = weights,
        )
        @test swapped.converged
        @test swapped.load_shed_W[1, critical] < 1.0
        @test swapped.load_shed_W[2, critical] > 1.0e5
    end

    @testset "energy balance closes in every period" begin
        net = demo_campus()
        heat = generate_profiles(net; hours = 12).heat_W
        model = build_multiperiod_model(net; heat_W = heat)
        sol = solve_multiperiod(model)
        audit = energy_audit(sol)

        @test sol.status === :SOLVE_SUCCEEDED
        check_periods(model, sol)
        @test maxabs(audit.closure_W) < 10.0
        @test all(audit.pipe_loss_W .> 0)
        # Everything demanded is delivered or shed, and surplus delivery is reported as excess.
        balance = audit.delivered_W .+ audit.shed_W .- audit.excess_W .- vec(sum(heat; dims = 2))
        @test maxabs(balance) < 10.0
        @test maximum(abs, diff(sol.plant_output_W)) <= net.plant.ramp_limit_W_per_h * (1 + 1.0e-6)
    end

    @testset "a pipe outage reverses a loop pipe only while it lasts" begin
        # With pipe 3 (2 -> 4) out, junction 4 can only be fed through pipe 5 (4 -> 5), backwards.
        net = small_campus()
        heat = heat_profile(net, [0.8, 0.8, 0.8, 0.8])
        result = solve_multiperiod_oriented(net; heat_W = heat, out_of_service = [3 => 2:3])
        sol = result.solution

        @test sol.status === :SOLVE_SUCCEEDED
        check_periods(result.model, sol)
        @test maxabs(energy_audit(sol).closure_W) < 10.0
        @test sum(sol.load_shed_W) < 1.0

        @test result.reversed_pipes == [Int[], [5], [5], Int[]]
        @test sol.pipe_in_service[:, 3] == [true, false, false, true]
        @test sol.pipe_flow_kg_per_s[[2, 3], 3] == [0.0, 0.0]
        @test all(sol.pipe_flow_kg_per_s[[2, 3], 5] .< 0)
        @test all(sol.pipe_flow_kg_per_s[[1, 4], 5] .> 0)
        @test all(sol.pipe_flow_kg_per_s[[1, 4], 3] .> 0)

        # The periods have different pipe counts but stay coupled by the ramp limit.
        @test length(result.model.data.templates) == 2
        @test maximum(abs, diff(sol.plant_output_W)) <= net.plant.ramp_limit_W_per_h * (1 + 1.0e-6)

        # Each outage hour agrees with the single-period outage solve when the ramp does not bind.
        single = solve_oriented(net; heat_W = heat[2, :], out_of_service = [3])
        @test sol.plant_output_W[2] ≈ single.solution.plant_output_W rtol = 1.0e-4
    end

    @testset "a demand-dependent reversal on the demo campus" begin
        net = demo_campus()
        profiles = generate_profiles(net; hours = 2000)
        found = nothing
        for hour in 100:100:2000, pipe in findall(p -> p.is_loop, net.pipes)
            design = try
                orient_network(net; out_of_service = [pipe])
            catch err
                err isa ArgumentError || rethrow()
                continue
            end
            oriented = orient_for_demand(
                net; heat_W = profiles.heat_W[hour, :], out_of_service = [pipe],
            )
            if any(a.from != d.from for (a, d) in zip(oriented.pipes, design.pipes))
                found = (; pipe, hour)
                break
            end
        end
        @test found !== nothing

        heat = profiles.heat_W[(found.hour - 1):found.hour, :]
        result = solve_multiperiod_oriented(
            net; heat_W = heat, out_of_service = [found.pipe], max_iter = 500,
        )
        sol = result.solution
        @test sol.converged
        check_periods(result.model, sol)
        @test maxabs(energy_audit(sol).closure_W) < 10.0
        @test all(.!sol.pipe_in_service[:, found.pipe])

        # Reversed pipes are reported against the input network and carry negative flow.
        for k in 1:2, e in result.reversed_pipes[k]
            @test net.pipes[e].is_loop
            @test sol.pipe_flow_kg_per_s[k, e] < 0
        end
        @test any(!isempty, result.reversed_pipes)
    end

    @testset "rejects inconsistent inputs" begin
        net = small_campus()
        heat = heat_profile(net, [1.0, 1.0])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = design_heat(net))
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat[:, 1:2])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = -heat)
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat, plant_rating_W = [1.0e6])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat, ramp_limit_W_per_h = [1.0, 2.0])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat, priority_weight = [1.0])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat, out_of_service = [99])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat, out_of_service = [3 => 5:6])
        @test_throws ArgumentError build_multiperiod_model(net; heat_W = heat, out_of_service = [1])
    end
end

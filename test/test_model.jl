using CampusSteam
using MadNLP: MadNLP
using Test

include(joinpath(@__DIR__, "fixtures", "small_campus.jl"))

maxabs(x) = maximum(abs, x; init = 0.0)

function check_residuals(model, sol)
    r = physical_residuals(model, sol)
    p = sol.junction_pressure_Pa
    steam_ids = findall(model.data.pipe_is_steam)
    @test maxabs(r.mass_kg_per_s) < 1.0e-6
    @test maxabs(r.energy_W) < 1.0
    @test maxabs(r.mixing_K) < 1.0e-6
    @test maxabs(r.decay_K) < 1.0e-5
    # Squared-pressure residual expressed as an equivalent pressure error at the pipe inlet.
    @test maxabs(r.steam_pressure_Pa2 ./ (2 .* p[model.data.pipe_from[steam_ids]])) < 1.0e-2
    @test maxabs(r.water_pressure_Pa) < 1.0e-2
    @test maxabs(r.load_heat_W) < 1.0
    @test maximum(r.load_pressure_Pa) < 1.0e-2
    @test only(r.plant_cap_W) < 1.0
    return r
end

@testset "steady-state steam model" begin
    @testset "solves to optimality with the demand met" begin
        net = small_campus()
        model = build_steam_model(net)
        sol = solve_steam(model)

        @test sol.status === :SOLVE_SUCCEEDED
        @test sol.converged
        check_residuals(model, sol)

        @test sum(sol.load_shed_W) < 1.0
        @test sum(sol.load_excess_W) < 1.0
        @test sol.load_delivered_W ≈ [l.design_heat_W for l in net.loads] rtol = 1.0e-6
        @test all(>(0), sol.pipe_flow_kg_per_s)
        @test all(>(0), sol.pipe_heat_loss_W)
        @test all(sol.load_inlet_temp_K .>= 373.15 - 1.0e-4)
        @test all(sol.load_outlet_temp_K .<= 373.15 + 1.0e-4)
    end

    @testset "energy balance closes" begin
        sol = solve_steam(build_steam_model(small_campus()))
        audit = energy_audit(sol)
        @test abs(audit.closure_W) < 1.0
        @test audit.plant_output_W ≈ audit.delivered_W + audit.pipe_loss_W rtol = 1.0e-6
        @test audit.pipe_loss_W > 0
    end

    @testset "shed load appears when the plant cap binds" begin
        net = small_campus(; rating_W = 3.0e6)
        model = build_steam_model(net)
        sol = solve_steam(model)
        audit = energy_audit(sol)

        @test sol.converged
        check_residuals(model, sol)
        @test sol.plant_output_W ≈ 3.0e6 rtol = 1.0e-5
        @test audit.shed_W > 1.0e6
        @test abs(audit.closure_W) < 1.0
        # The demand balance holds: everything not delivered is reported as shed.
        @test audit.delivered_W + audit.shed_W - audit.excess_W ≈ sum(l.design_heat_W for l in net.loads) rtol = 1.0e-6
        # The critical load has the highest priority weight, so it is served first.
        @test sol.load_shed_W[3] < 1.0
        @test sol.load_shed_W[2] > sol.load_shed_W[3]
    end

    @testset "plant rating override and demand update" begin
        net = small_campus()
        capped = solve_steam(net; plant_rating_W = 3.0e6)
        @test capped.plant_output_W ≈ 3.0e6 rtol = 1.0e-5

        scaled = [0.8 * l.design_heat_W for l in net.loads]
        model = build_steam_model(net)
        set_demand!(model, scaled)
        updated = solve_steam(model)
        rebuilt = solve_steam(net; heat_W = scaled)
        @test updated.converged && rebuilt.converged
        @test updated.objective_W ≈ rebuilt.objective_W rtol = 1.0e-6
        @test updated.load_delivered_W ≈ scaled rtol = 1.0e-6
    end

    @testset "flow stays above the bound implied by the temperature limits" begin
        net = small_campus()
        model = build_steam_model(net)
        sol = solve_steam(model)
        lower = model.data.bounds.flow[1][1:model.data.npipe] .* model.data.options.flow_ref_kg_per_s
        @test all(lower .> 0)
        @test all(sol.pipe_flow_kg_per_s .>= lower .* (1 - 1.0e-6))
    end

    @testset "rejects networks that break the contract" begin
        net = small_campus()
        with_pipes(pipes) = CampusNetwork(net.junctions, pipes, net.loads, net.plant)
        rebuilt(p; from = p.from, to = p.to, loss = p.heat_loss_W_per_m2K) = CampusSteam.Pipe(
            p.id, p.side, from, to, p.length_m, p.diameter_m, p.friction_factor, loss,
            p.max_pump_boost_Pa, p.is_loop,
        )
        reversed = [p.id == 1 ? rebuilt(p; from = p.to, to = p.from) : p for p in net.pipes]
        @test_throws ArgumentError build_steam_model(with_pipes(reversed))
        @test_throws ArgumentError build_steam_model(with_pipes([rebuilt(p; loss = 0.0) for p in net.pipes]))
        @test_throws ArgumentError build_steam_model(net; heat_W = [1.0e6])
    end

    @testset "demo campus" begin
        net = demo_campus()
        model = build_steam_model(net)
        sol = solve_steam(model)
        @test sol.status === :SOLVE_SUCCEEDED
        check_residuals(model, sol)
        @test abs(energy_audit(sol).closure_W) < 10.0
        @test sum(sol.load_shed_W) < 1.0
    end

    @testset "demo campus part load stays within the excess-heat limit" begin
        net = demo_campus()
        design = [l.design_heat_W for l in net.loads]
        for share in (1.0, 0.75, 0.5, 0.35, 0.25)
            heat = share .* design
            model = build_steam_model(net; heat_W = heat)
            sol = solve_steam(model)
            @test sol.status === :SOLVE_SUCCEEDED
            check_residuals(model, sol)
            audit = energy_audit(sol)
            @test audit.excess_W <= 0.01 * sum(heat)
            @test audit.shed_W < 1.0
            @test audit.pipe_loss_W <= 0.05 * audit.plant_output_W
        end
    end

    @testset "outage with a reversed loop pipe" begin
        # With loop pipe 18 out, the flow in another loop pipe runs against its design direction
        # at hour 3326. A fixed design orientation cannot represent that flow.
        net = demo_campus()
        out, hour = 18, 3326
        heat = generate_profiles(net; hours = hour).heat_W[hour, :]

        design = orient_network(net; out_of_service = [out])
        at_demand = orient_for_demand(net; heat_W = heat, out_of_service = [out])
        @test length(at_demand.pipes) == length(net.pipes) - 1
        @test any(a.from != d.from for (a, d) in zip(at_demand.pipes, design.pipes))

        result = solve_oriented(net; heat_W = heat, out_of_service = [out], max_iter = 500)
        @test result.solution.status === :SOLVE_SUCCEEDED
        check_residuals(result.model, result.solution)
        @test abs(energy_audit(result.solution).closure_W) < 10.0
        @test sum(result.solution.load_shed_W) < 1.0

        # The reversal is reported against the input network, and only on loop pipes.
        @test !isempty(result.reversed_pipes)
        @test all(net.pipes[e].is_loop for e in result.reversed_pipes)
        @test all(result.source_flow_kg_per_s[result.reversed_pipes] .< 0)
        @test result.source_flow_kg_per_s[out] == 0
    end
end

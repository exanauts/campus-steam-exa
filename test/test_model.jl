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
        reversed = map(p -> p.id == 1 ? merge(p, (from = p.to, to = p.from)) : p, net.pipes)
        @test_throws ArgumentError build_steam_model(merge(net, (; pipes = reversed)))
        no_loss = map(p -> merge(p, (; heat_loss_W_per_m2K = 0.0)), net.pipes)
        @test_throws ArgumentError build_steam_model(merge(net, (; pipes = no_loss)))
        @test_throws ArgumentError build_steam_model(net; heat_W = [1.0e6])
    end

    if isdefined(CampusSteam, :demo_campus)
        @testset "demo campus" begin
            net = CampusSteam.demo_campus()
            model = build_steam_model(net)
            sol = solve_steam(model)
            @test sol.status === :SOLVE_SUCCEEDED
            check_residuals(model, sol)
            @test abs(energy_audit(sol).closure_W) < 10.0
        end
    end
end

using CampusSteam
using Test

@testset "CampusSteam" begin
    @test isdefined(CampusSteam, :gpu_extension_loaded)
    @test CampusSteam.gpu_extension_loaded() === false
end

include("test_generator.jl")
include("test_model.jl")

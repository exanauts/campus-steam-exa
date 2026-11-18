"""
    CampusSteam

Campus district-steam optimization on ExaModels.jl and MadNLP.jl.

This module is a stub. The network model is added by later work packages.
"""
module CampusSteam

using ExaModels: ExaModels
using MadNLP: MadNLP
using LinearAlgebra: Symmetric, cholesky, cholesky!
using SparseArrays: sparse

# `Pipe` is not exported because it would clash with `Base.Pipe`; use `CampusSteam.Pipe`.
export Junction, Load, Plant, CampusNetwork, LoadProfiles
export demo_campus, scaled_campus, generate_profiles, orient_network
export write_network, read_network, write_profiles, write_weather, read_profiles
export validate_network, BUILDING_FOOTPRINT_M, DESIGN_OUTDOOR_TEMP_C

include("network.jl")
include("generator/rng.jl")
include("generator/campus.jl")
include("generator/profiles.jl")

"""
    gpu_extension_loaded()

Return `true` when the GPU package extension is active, which requires CUDA,
CUDSS and MadNLPGPU to be loaded alongside this package.
"""
gpu_extension_loaded() = Base.get_extension(@__MODULE__, :CampusSteamGPUExt) !== nothing

include("model/model.jl")

end # module CampusSteam

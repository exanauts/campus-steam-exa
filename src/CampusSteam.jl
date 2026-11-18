"""
    CampusSteam

Campus district-steam optimization on ExaModels.jl and MadNLP.jl.

This module is a stub. The network model is added by later work packages.
"""
module CampusSteam

using ExaModels: ExaModels
using MadNLP: MadNLP

"""
    gpu_extension_loaded()

Return `true` when the GPU package extension is active, which requires CUDA,
CUDSS and MadNLPGPU to be loaded alongside this package.
"""
gpu_extension_loaded() = Base.get_extension(@__MODULE__, :CampusSteamGPUExt) !== nothing

end # module CampusSteam

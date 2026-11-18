"""
    SteamModelOptions(; kwargs...)

Physical constants, operating limits, objective weights and scaling references of the
single-period steady-state model. Every field is in SI units. Defaults follow Section 4.2 of
Hari et al., arXiv:2404.18868.

Carrier: `gas_constant_J_per_kgK`, `cp_steam_J_per_kgK`, `cp_water_J_per_kgK`,
`latent_heat_J_per_kg`, `water_density_kg_per_m3`.

Limits: `ambient_temp_K`, `saturation_temp_K`, `steam_temp_max_K`, `water_temp_min_K`,
`pressure_min_Pa`, `pressure_max_Pa`, `flow_floor_kg_per_s`.

Objective weights, in W of objective per unit of the term: `shed_weight` (multiplies each
load's `priority_weight`), `excess_weight`, `pressure_weight` (W/Pa), `flow_weight`
(W per kg/s), `temperature_weight` (W/K), `plant_power_weight` (W/W, zero in the paper).

Scaling references: `pressure_ref_Pa`, `temperature_ref_K`, `flow_ref_kg_per_s`, `power_ref_W`,
and `objective_ref_W`, which is smaller than `power_ref_W` so that the plant regularization terms
stay above the solver tolerance.
"""
Base.@kwdef struct SteamModelOptions
    gas_constant_J_per_kgK::Float64 = 461.5
    cp_steam_J_per_kgK::Float64 = 1996.0
    cp_water_J_per_kgK::Float64 = 4186.0
    latent_heat_J_per_kg::Float64 = 2.23e6
    water_density_kg_per_m3::Float64 = 1000.0

    ambient_temp_K::Float64 = 298.15
    saturation_temp_K::Float64 = 373.15
    steam_temp_max_K::Float64 = 423.15
    water_temp_min_K::Float64 = 353.15
    pressure_min_Pa::Float64 = 34473.8
    pressure_max_Pa::Float64 = 551581.0
    flow_floor_kg_per_s::Float64 = 1.0e-4

    shed_weight::Float64 = 1.0
    excess_weight::Float64 = 1.0
    pressure_weight::Float64 = 1.0
    flow_weight::Float64 = 1.0
    temperature_weight::Float64 = 1.0
    plant_power_weight::Float64 = 0.0

    pressure_ref_Pa::Float64 = 1.0e5
    temperature_ref_K::Float64 = 100.0
    flow_ref_kg_per_s::Float64 = 1.0
    power_ref_W::Float64 = 1.0e6
    objective_ref_W::Float64 = 1.0e4
end

# Steady-state steam model notes

This is a single-period, steady-state model of a district steam network. It has no pipe
transients and no valves: flows, pressures and temperatures are in equilibrium, and flow splits
follow from the physics and the optimization alone. All data is synthetic.

The physics follows Hari, Srinivasan, Zlotnik, Sundar and Ewers, "Optimization of District
Heating Network Parameters in Steady-State Operation", arXiv:2404.18868, with
[ThermalModels.jl](https://github.com/lanl-ansi/ThermalModels.jl) as the reference implementation.
The code here is a reimplementation on ExaModels.jl and MadNLP.jl. Equation numbers below refer to
the paper.

## Constraint families

Edges share one index space: pipes, then loads, then the plant. Each family is one ExaModels
generator over one array of parameters. The two balances start from empty rows and add one
augmentation layer per term type, so their expression patterns do not depend on junction degree.

| Family | Handle in `cons` | Equation | Scaled units |
|---|---|---|---|
| Junction mass balance | `mass_balance` | (18) | `flow_ref` |
| Junction energy balance | `energy_balance` | (19) | `flow_ref * temperature_ref` |
| Perfect mixing | `mixing` | (17) | `temperature_ref` |
| Exponential temperature decay | `temperature_decay` | (7) | `temperature_ref` |
| Steam pressure drop, squared pressures | `steam_pressure` | (14) | `pressure_ref^2` |
| Water pressure drop with pump boost | `water_pressure` | (16) | `pressure_ref` |
| Load heat release with slacks | `load_heat` | (2) | `power_ref` |
| Load pressure ordering | `load_pressure` | (5) | `pressure_ref` |
| Plant power | `plant_power` | (1) | `power_ref` |

The specific heat is uniform on each side of the network, so it cancels from the energy balance
rows. The objective is Eq. (20), with each shed term multiplied by the load's `priority_weight`.

## Numerical hazards

### `phi*abs(phi)` in the pressure loss

Flow is non-negative in each pipe's nominal `from -> to` direction, as the network contract
allows, so `phi*abs(phi)` is written as the smooth `phi^2`. A flow reversal is not representable
in a solve. `orient_network` handles rerouting by recomputing directions before the model is built.

### `exp(-k/(c*phi*A))` with flow in the denominator

Flow is kept bounded away from zero; the expression is not reformulated. Each pipe has the lower
bound

```
f_min = max(flow_floor, L * gamma / (c * log((T_in_max - T_amb) / (T_out_min - T_amb))))
```

The second term is implied by the temperature limits: a slower pipe could not keep its outlet above
`T_out_min` from an inlet at `T_in_max`. It removes no point that satisfies those limits, and it
caps the decay exponent at the logarithm above. `flow_floor` (default 1e-4 kg/s) is the only part
that can cut off a feasible point.

The bound has a physical consequence. A feeder must carry its minimum flow even when the load at
its end needs no heat, and that steam has to condense somewhere, so it appears as excess heat. In
the small test fixture, setting the demand of the leaf load 3 to zero produced 344958 W of excess.
Setting the demand of load 2 to zero produced none, because its junction also passes flow on to
junction 5.

The steam-side temperature lower bound is 100 C at every steam junction. The paper bounds
temperatures at 80 C and requires 100 C at load inlets. Temperature only falls along a pipe and all
steam ends at a load, so the tighter bound is implied.

### Pressures in Pa next to powers in W

Variables are scaled by fixed references: pressure 1e5 Pa, temperature 100 K, flow 1 kg/s and power
1e6 W. Constraint rows use the units in the table above. MadNLP's gradient-based NLP scaling stays
on as a second layer.

The objective has its own reference, `objective_ref_W = 1e4`. With the objective in MW, the plant
flow and temperature terms had gradients near 1e-6 and 1e-4, too close to the 1e-8 solver tolerance.
On the upstream example network, the solve stopped with a plant outlet temperature of 112.539 C.
With the 1e4 reference it reaches 112.492 C at the same tolerance, and tightening the tolerance to
1e-12 gives 112.4917 C.

`SteamSolution.objective_W` is recomputed from SI values after clamping the shed and excess slacks
at zero. MadNLP relaxes bounds slightly, and the slightly negative slacks otherwise shift the
reported objective by about 0.1 W on that network.

### The plant constraint

The plant cap could be written as a sum over all loads and pipes, which would be a dense row. It is
written instead on the plant edge alone, from the plant's flow and its inlet and outlet
temperatures, and defines a `plant_power` variable whose upper bound is the rating. The row has 4
nonzeros on every network. The network-wide coupling is carried by the sparse balance rows.

On a 45-load test network (934 variables, 830 constraints, 2822 Jacobian nonzeros) the densest
Jacobian row has 14 nonzeros, and it comes from a junction balance. No row grows with network size,
so the KKT system has no dense row or column from the plant.

### Redundant mass balance

The network is a closed circuit, so the junction mass balances sum to zero identically. The row at
the plant's water junction is dropped, and it holds implicitly. The equality Jacobian at the
solution has full row rank on both networks checked: rank 57 of 57 on the small fixture and 785 of
785 on the 45-load network.

## Verification against the reference code

The upstream example network was rebuilt through this model, with its pipe data and limits. This
was a one-off check and the upstream data is not stored in this repository.

| Quantity | ThermalModels.jl (Ipopt) | This model (MadNLP, tol 1e-8) |
|---|---|---|
| Objective | 310650.3699 | 310650.3668 |
| Plant outlet temperature | 112.49 C | 112.492 C |
| Plant flow | 0.93 kg/s | 0.9285 kg/s |
| Power lost in pipes | 17016.43 W | 17027.52 W |

The objectives differ by a relative 1.0e-8.

## Modeling limits

- Saturation is fixed at 100 C, as in the paper, regardless of pressure. Real steam at 2.7 bar
  saturates near 130 C, so the model can carry "steam" below its true saturation temperature.
- Steam is an ideal gas with constant specific heat, and water is incompressible.
- Friction factors are constants given per pipe, not functions of the Reynolds number.
- The ambient temperature is one constant, fixed when the model is built.
- Pump and compressor energy is not counted in the plant output.
- `plant_power` covers the heat added at the plant only. Boilers are not modeled individually.

## API

```julia
model = build_steam_model(net; heat_W, plant_rating_W, options, backend)
sol = solve_steam(model; print_level, tol, max_iter)   # other keywords go to madnlp
sol = solve_steam(net; heat_W, plant_rating_W)         # builds and solves
set_demand!(model, heat_W)                             # updates demand without a rebuild

physical_residuals(model, sol)   # residual of each family in SI units, computed independently
energy_audit(sol)                # plant output, delivered heat, pipe losses and closure
```

Multi-period models can assemble their own `ExaCore` from the pieces:

```julia
data = compile_steam_data(net; heat_W, options)
core, demand = add_par(core, data.demand)
core, vars = add_steam_variables(core, data)
core, cons = add_steam_constraints(core, data, vars, demand)
core = add_steam_objective(core, data, vars; scale = 1.0)
```

`vars.plant_power[1]` is the natural variable for linking periods with a ramp limit.
`extract_solution(model, result)` converts a MadNLP result to a `SteamSolution` for a `SteamModel`.

`build_steam_model` accepts any object with the contract's field names, so the fixture in
`test/fixtures/small_campus.jl` uses named tuples in place of the `CampusNetwork` structs.

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
within one solve, so reversals are handled by re-orienting pipes between solves. See
[Flow reversal and outages](#flow-reversal-and-outages).

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

On the demo campus (1008 variables, 868 constraints, 3071 Jacobian nonzeros) the densest Jacobian
row has 16 nonzeros. Only the junction balances vary in length, and they grow with junction degree
rather than network size, so the plant adds no dense row or column to the KKT system.

### Redundant mass balance

The network is a closed circuit, so the junction mass balances sum to zero identically. The row at
the plant's water junction is dropped, and it holds implicitly. The equality Jacobian at the
solution has full row rank on both networks checked: rank 57 of 57 on the small fixture and 823 of
823 on the demo campus.

## Flow reversal and outages

With a loop pipe out of service, the flow in another loop pipe can run against its design direction
at part load. A strict `phi >= 0` bound in the design direction can then distort the solution or
prevent convergence. The model re-orients per solve instead of allowing reverse flow in the NLP. A
smooth reversible formulation was rejected because the decay exponent is singular at zero flow and
the pipe inlet temperature would have to switch with the flow direction.

`solve_oriented` takes the network, the demand and the outage set, and does the following:

1. It solves from two starting orientations: the hydraulic flow direction at this hour's demand
   (`orient_for_demand`), and the design-load direction (`orient_network`).
2. A loop pipe that finishes pinned at its minimum flow is flipped and the model solved again. A
   flip is kept only if the solve converges with a lower objective.
3. The converged result with the lowest objective is returned.

**Accuracy.** No smoothing is involved, so each returned solution satisfies the same physics to the
same residuals as any other solve. The approximation is in the search: the direction pattern is a
heuristic and is not proven optimal. A pump on a pipe running against its installed direction gives
no boost.

Scanning the 66 single loop-pipe outages at 120 sampled hours found 1600 outage-hour pairs, across
24 outages, where the demand-based and design-based orientations differ. On 16 of those pairs, spaced
evenly through the list:

| Result on the 16 pairs | Design orientation only | `solve_oriented` |
|---|---|---|
| Converged | 15 | 16 |
| Lower objective than the other method | 0 | 9, counting the pair where design orientation failed |
| Same objective as the other method | 7 | 7 |

The objective differences are large in some cases, up to a factor of 3.6 (pipe 104 out at hour
4600). The test suite covers pipe 103 out at hour 2629, where design orientation alone reached the
500 iteration limit and `solve_oriented` converged in 88 iterations with no shed load.

## Demo campus results

Solved with the default options at the design heat of 79.695 MW, with the tolerance at 1e-8. The
CPU runs used one thread and the GPU runs one NVIDIA H200. Each backend was solved three times in
one session. Solve times exclude the first run, which includes compilation (7.4 s on CPU and 60.6 s
on GPU).

| Quantity | CPU | GPU |
|---|---|---|
| Status | `SOLVE_SUCCEEDED` | `SOLVE_SUCCEEDED` |
| Objective (W) | 1946093.89 | 1946092.62 |
| Iterations | 36 | 38 to 39 |
| Solve time after compilation (s) | 0.037 to 0.038 | 0.143 to 0.365 |
| Scaled constraint violation | 5.1e-12 | 4.7e-12 to 5.0e-12 |
| Energy closure (W) | 5.2e-7 | 0.42 |

The plant output is 82.61 MW, with 2.22 MW lost in pipes, 0.70 MW of excess heat at one load and no
shed load. The GPU objective differs from the CPU objective by a relative 6.5e-7.

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

## Part-load excess heat

The demo campus releases a large amount of excess heat at part load. The model follows the paper in
treating heat loss from a steam pipe as sensible cooling, with no condensation in the pipe. The
likely mechanism is that steam must still reach every load at 100 C or above, so a lightly loaded
network keeps its flow high, and the steam that flow carries has to condense at the loads. The
table supports this: the excess disappears at part load when the heat loss coefficient is lowered.

Intact demo campus, every load scaled by the same factor:

| Share of design heat | Demand (MW) | Excess, demo heat loss (MW) | Excess, paper heat loss (MW) |
|---|---|---|---|
| 100% | 79.7 | 0.70 | not converged in 1000 iterations |
| 75% | 59.8 | 1.55 | 0.00 |
| 50% | 39.8 | 3.22 | 0.00 |
| 35% | 27.9 | 6.37 | 0.00 |
| 25% | 19.9 | 10.11 | 0.00 |

"Demo heat loss" is the generator's coefficient, with a median of 0.648 W/(m K) on steam pipes.
"Paper heat loss" replaces it with the paper's 0.1 W/(m K) on steam pipes and 0.05 W/(m K) on water
pipes. With the demo coefficients the plant outlet sits at its 189.85 C limit in all five cases.

Treat excess heat at part load as an artifact of this modeling choice combined with the demo's heat
loss coefficients, and not as a prediction of real plant behavior.

## Modeling limits

- Saturation is fixed at 100 C, as in the paper, regardless of pressure. Real steam at 2.7 bar
  saturates near 130 C, so the model can carry "steam" below its true saturation temperature.
- Heat lost from steam pipes cools the steam and never condenses it.
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

# Outages and part load: chooses pipe directions, then solves. Returns an OrientedSolve.
result = solve_oriented(net; heat_W, out_of_service = [pipe_id])
result.solution, result.net, result.reversed_pipes, result.source_flow_kg_per_s

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

Pipe arrays in a `SteamSolution` follow the pipes of the network that was solved. After an outage
those ids are renumbered, so use `result.source_pipe` to map them back to the input network.

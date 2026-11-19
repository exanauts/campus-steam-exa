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

### The temperature integral in the steam pressure drop

Eq. (14) needs the integral of temperature along the pipe. It is usually written with the inlet and
outlet temperatures, as `T_amb * L + (c * phi / gamma) * (T_in - T_out)`. That form is exact only
where the decay law (7) holds. While the solver is away from that point, any error in `T_out` is
multiplied by `c * phi / gamma`, so a well-insulated pipe turns a small temperature error into a
large, possibly negative, friction term.

The model therefore substitutes the decay law into the integral and uses
`T_amb * L + (c * phi / gamma) * (T_in - T_amb) * (1 - exp(-L * gamma / (c * phi)))`. The two forms
are equal at every feasible point, so the physics is unchanged. `physical_residuals` still checks
each solution against the first form.

The effect on convergence was measured over 17 demand levels per campus on trial data with low heat
loss coefficients, on three seeds for four trial coefficient sets (204 solves, 400 iteration limit):

| Steam pressure row | Solved to optimality |
|---|---|
| Written with `T_out` | 150 of 204 |
| Written with the decay law | 204 of 204 |

With the `T_out` form, changing the coefficient by 1% was enough to turn converged cases into
failures at the 1000 iteration limit.

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

On the demo campus (1008 variables, 868 constraints, 2993 Jacobian nonzeros) the densest Jacobian
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

Scanning the 52 single loop-pipe outages of the demo campus (steam and water side) at 120 evenly
spaced hours found 658 outage-hour pairs, across 12 outages, where the demand-based and design-based
orientations differ. On 16 of those pairs, spaced evenly through the list:

| Result on the 16 pairs | Design orientation only | `solve_oriented` |
|---|---|---|
| Converged | 16 | 16 |
| Lower objective than the other method | 0 | 10 |
| Same objective as the other method | 6 | 6 |

The objective differences are large in some cases, up to a factor of 2.1 (pipe 4 out at hour
4933). The test suite covers pipe 18 out at hour 3326, where `solve_oriented` converges in 52
iterations with no shed load and three pipes reversed.

## Demo campus results

Solved with the default options at the design heat of 80.088 MW, with the tolerance at 1e-8, on the
CPU with one thread. Solve times exclude the first run, which includes compilation.

| Quantity | CPU |
|---|---|
| Status | `SOLVE_SUCCEEDED` |
| Objective (W) | 1250416.33 |
| Iterations | 52 |
| Solve time after compilation (s) | 0.081 |
| Scaled constraint violation | 6.5e-13 |
| Energy closure (W) | 1.5e-7 |

The plant output is 80.35 MW, with 0.27 MW lost in pipes, no excess heat and no shed load. GPU
results in [`docs/gpu-notes.md`](gpu-notes.md) were measured on the earlier street-grid layout of
this campus and have not been repeated.

## Verification against the reference code

The upstream example network was rebuilt through this model, with its pipe data and limits. This
was a one-off check and the upstream data is not stored in this repository.

| Quantity | ThermalModels.jl (Ipopt) | This model (MadNLP, tol 1e-8) |
|---|---|---|
| Objective | 310650.3699 | 310650.3668 |
| Plant outlet temperature | 112.49 C | 112.492 C |
| Plant flow | 0.93 kg/s | 0.9285 kg/s |
| Power lost in pipes | 17016.43 W | 17027.52 W |

The objectives differ by a relative 1.0e-8. This comparison predates the rewritten temperature
integral described under numerical hazards and has not been repeated since.

## Synthetic demo data

All network data is synthetic and describes the fictional Example University. It does not describe
any real campus. The demo campus has 166 junctions and 168 pipes over both sides and 45 buildings
(16 labs, 16 housing, 9 classrooms, 4 clinics). Two trunk mains leave the plant on the south edge,
two cross-ties close two loops, a clinic spur and a north spine hang off the middle of the ties, and
the rest is a tree with three long dead-end runs; see the layout section of
[`docs/network-schema.md`](network-schema.md).

| Quantity | Value |
|---|---|
| Plant supply | 1.0 MPa, 189.85 C, which is also the steam temperature limit |
| Steam pipe heat loss | 0.35 W/(m2 K) of pipe surface, and at least 0.20 W/(m K) per metre, with a 10% spread |
| Condensate pipe heat loss | 0.175 W/(m2 K) of pipe surface, with a 10% spread |
| Steam line coefficient on the demo campus | 0.18 to 0.68 W/(m K), median 0.218 |
| Plant rating | 110 MW from 4 boilers, 82.5 MW with one boiler out |
| Design heat | 80.1 MW |
| Peak demand | 88.3 MW in the cold snap, 76.7 MW outside it |

With one boiler out, the plant falls 5.80 MW short of the cold-snap peak demand. Outside the cold
snap it meets the peak with one boiler out.

The steam coefficients correspond to about 60 to 190 mm of insulation with a conductivity of
0.04 W/(m K). The paper uses 0.1 W/(m K) on steam pipes, which is lower than these values.

### Part-load results

Intact demo campus with every load scaled by the same factor, and the cold-snap peak:

| Case | Demand (MW) | Plant outlet (C) | Excess (MW) | Excess share of demand | Pipe loss (MW) | Pipe loss share of plant output |
|---|---|---|---|---|---|---|
| Cold-snap peak | 88.3 | 107.02 | 0.00 | 0.00% | 0.26 | 0.30% |
| 100% of design | 80.1 | 108.31 | 0.00 | 0.00% | 0.27 | 0.33% |
| 75% | 60.1 | 111.25 | 0.00 | 0.00% | 0.27 | 0.45% |
| 50% | 40.0 | 117.44 | 0.00 | 0.00% | 0.28 | 0.71% |
| 35% | 28.0 | 126.12 | 0.00 | 0.00% | 0.30 | 1.07% |
| 25% | 20.0 | 138.96 | 0.00 | 0.00% | 0.33 | 1.62% |

Excess heat appears when lightly loaded steam mains cannot stay above 100 C. The plant then sends
more steam than the buildings need, and the surplus is released at the loads. On the demo campus the
plant outlet stays below its 189.85 C limit down to 25% of design heat, so no excess appears in
these cases. Other results to keep in mind:

- Other seeds change the layout. Seed 3 shows no excess across 16 load levels from 25% to 100% of
  design heat and its cold-snap peak.
- Of 17 single loop-pipe outages sampled evenly from the 52, none produced excess heat at design
  heat. Outages at part load were not sampled.

### Scaled campuses

`scaled_campus` keeps total design heat at or below 250 MW while the pipe network keeps growing, so
large campuses have more pipe per unit of steam. The committed record of scaled solves covers 200 to 800
junctions: [`results/validation_size_sweep.csv`](../results/validation_size_sweep.csv), written by
[`validation/run_validation.jl`](../validation/run_validation.jl).

## Modeling limits

- Heat lost from a steam pipe only cools the steam. The model has no condensation in pipes, so it
  has no condensate traps or drip legs.
- Saturation is fixed at 100 C, as in the paper, regardless of pressure. Real steam at 1 MPa
  saturates near 180 C, so the model can carry "steam" well below its true saturation temperature.
- Because steam only has its superheat to lose, heat loss and part-load behavior are not predictions
  of how a real steam network behaves. Excess heat at part load is a consequence of this modeling
  choice.
- Steam is an ideal gas with constant specific heat, and water is incompressible.
- Friction factors are constants given per pipe, not functions of the Reynolds number.
- The ambient temperature is one constant, fixed when the model is built.
- Pump and compressor energy is not counted in the plant output.
- `plant_power` covers the heat added at the plant only. Boilers are not modeled individually.

## Multi-period model

`src/model/multiperiod.jl` stacks T hourly steady states into one NLP. Each hour has the
steady-state physics above, with no pipe transients and no valves. All inputs are synthetic.

### Formulation

**One generator per family.** Each period is compiled by `compile_steam_data`, and the per-period
arrays are concatenated with every index shifted by the offset of its period. The result is again a
`SteamData`, so `add_steam_variables`, `add_steam_constraints` and `add_steam_objective` build the
whole horizon without a loop over periods. The period is carried by the flat index, not by a second
array dimension, because the number of pipes differs between periods when a pipe is out for part of
the horizon. Periods with the same pipes share one compiled template.

**Time-varying inputs.** Heat demand is an ExaModels parameter indexed by period and load. The plant
rating is the upper bound of each period's `plant_power`. Priority weights are objective
coefficients per period and load.

**Objective.** The sum of the single-period objectives, reported as `objective_Wh`. It is not divided
by T, so the gradient of each variable, and with it the solver scaling, matches a single period. At
T = 1 the model is the single-period model, with the same iterates.

**Ramp limits.** One row per transition, `-down <= P[k+1] - P[k] <= up`, with `up` equal to
`ramp_limit_W_per_h` and `down = max(up, rating[k] - rating[k+1])`. A forced derate takes effect at
once. Without this relaxation the plant would have to shed load ahead of a boiler outage to get down
to the reduced rating in time. The return to service stays limited by `up`. The horizon has perfect
foresight, so the plant can still pre-position ahead of a demand step. There is no initial-output
condition on the first period.

**No storage term.** Thermal storage and pipe inventory are left out. A steady-state hour has no
state that carries heat into the next hour, so an inventory term would need physics this model does
not have. The ramp limit is the only coupling between periods.

### Outages and orientation per period

`out_of_service` takes pipe ids (out for the whole horizon), `pipe => periods` pairs, or one id list
per period. Each outage period has its own pipe directions, so a flow reversal is represented without
reverse flow in the NLP. Periods with no outage keep the input network unchanged.

`orient_periods` chooses the directions with one of three methods: `:search` (`solve_oriented` for
that hour), `:demand` (`orient_for_demand`) or `:design` (`orient_network`).
`solve_multiperiod_oriented` is the documented way to solve an outage case:

1. It solves the horizon from each starting orientation in `methods`, by default `:search` and
   `:design`.
2. Loop pipes pinned at their minimum flow in an outage period are flipped in that period and the
   horizon is solved again. A flip round is kept only if it converges with a lower objective.
3. The converged result with the lowest objective is returned. If no start converges, the result is
   not converged, so check `solution.converged`.

The direction pattern is a heuristic and is not proven optimal. `build_multiperiod_model` with
`out_of_service` and no `networks` uses `:demand`, which does no search.

Demo campus, hours 2600 to 2767 of the synthetic year, loop pipe 1 out in periods 20 to 60, CPU, with
a limit of 1000 iterations per solve. Pipe 1 is the west feeder from the plant. With the `:demand`
start, pipes 3, 18, 19, 20 and 27 to 31 run reversed in all 41 outage periods: the west trunk is fed
backward through both cross-ties. The other starts reverse the same pipes except pipe 27 in some or
all periods.

| Starting orientation | Status | Iterations | Objective (Wh) | Shed (MWh) |
|---|---|---|---|---|
| `:search` | `SOLVE_SUCCEEDED` | 127 | 2.11217e8 | 0.000 |
| `:demand` | `SOLVE_SUCCEEDED` | 118 | 2.10975e8 | 0.000 |
| `:design` | `SOLVE_SUCCEEDED` | 105 | 2.28808e8 | 0.001 |

Here the `:demand` start reached a slightly lower objective than `:search`, which shows that the
search is a heuristic.

### Measurements

**Superseded by [`docs/gpu-notes.md`](gpu-notes.md).** This table is an earlier measurement, kept for the record.
Use the GPU notes for the current CPU and GPU comparison.

Demo campus, first T hours of the synthetic profiles, default ramp limit, no outage. Generator commit
`a1e75b6`. Times exclude compilation. The tolerance is 1e-8 with a limit of 1000 iterations. The CPU
runs use MadNLP's default MUMPS solver. The GPU runs use one NVIDIA H200 with cuDSS and
`richardson_max_iter = 30, richardson_tol = 1e-12`. The violation is the unscaled maximum constraint
violation, and closure is the largest hourly energy balance error.

| T | Variables | Constraints | Jacobian nonzeros | Device | Status | Iterations | Build (s) | Solve (s) | Violation | Closure (W) |
|---|---|---|---|---|---|---|---|---|---|---|
| 24 | 24,192 | 20,855 | 71,878 | CPU | `SOLVE_SUCCEEDED` | 58 | 0.003 | 1.530 | 1.2e-13 | 2.5e-8 |
| 24 | 24,192 | 20,855 | 71,878 | GPU | `SOLVE_SUCCEEDED` | 94 | 0.040 | 3.736 | 9.2e-9 | 1.9e-3 |
| 168 | 169,344 | 145,991 | 503,158 | CPU | `SOLVE_SUCCEEDED` | 64 | 0.023 | 13.995 | 2.1e-12 | 3.1e-7 |
| 168 | 169,344 | 145,991 | 503,158 | GPU | `SOLVED_TO_ACCEPTABLE_LEVEL` | 374 | 0.090 | 19.038 | 7.4e-8 | 1.3e-2 |
| 720 | 725,760 | 625,679 | 2,156,398 | CPU | `SOLVE_SUCCEEDED` | 76 | 0.107 | 87.946 | 1.4e-9 | 2.0e-4 |
| 720 | 725,760 | 625,679 | 2,156,398 | GPU | `SOLVED_TO_ACCEPTABLE_LEVEL` | 149 | 0.250 | 12.980 | 7.6e-8 | 5.9e-3 |

The GPU runs at T = 168 and T = 720 stopped at MadNLP's acceptable level and did not reach 1e-8.
T = 8,760 was attempted once per device and neither solve finished, as recorded in
[`docs/gpu-notes.md`](gpu-notes.md) and the [log](../results/logs/benchmarks_year_attempt.txt).

### Multi-period API

```julia
model = build_multiperiod_model(net; heat_W, plant_rating_W, priority_weight, ramp_limit_W_per_h,
                                out_of_service, networks, options, backend)
sol = solve_multiperiod(model; print_level, tol, max_iter)   # other keywords go to madnlp

# Outages: chooses pipe directions per period, then solves. Returns an OrientedMultiPeriodSolve.
result = solve_multiperiod_oriented(net; heat_W, out_of_service = [pipe_id => periods])
result.solution, result.networks, result.reversed_pipes, result.method, result.rounds

energy_audit(sol)                  # one vector per quantity, with one entry per period
physical_residuals(model, sol, k)  # residuals of period k in SI units
period_solution(model, sol, k)     # period k as a SteamSolution
```

`heat_W` is indexed `(period, load)`, the same as `LoadProfiles.heat_W`. `MultiPeriodSolution` holds
matrices indexed `(period, id)` in SI units. Pipe ids always refer to the input network, flows are
negative against its direction, and every pipe quantity is zero where `pipe_in_service` is false.

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

For multi-period problems use `build_multiperiod_model`, described above. Custom models can assemble
their own `ExaCore` from the pieces:

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

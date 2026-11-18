# Reference validation notes

The ExaModels model in `src/model/` is compared with an independent JuMP + Ipopt statement of the
same problem in `validation/jump_model.jl`. All networks are synthetic. Run
`julia --project=validation validation/run_validation.jl` to regenerate every file cited here.

## Result

At the reference tolerance of 1e-8, the two models agree on the optimal objective to a relative
1.6e-6 or better on all four instances. At tolerance 1e-12 they agree to 7.7e-11 or better. The
MadNLP solution satisfies the constraints of the JuMP model, with Eq. (14) as printed in the paper,
to 1.8e-11 or better in that model's scaled rows. No formulation defect was found.

Many primal quantities differ by more than the 1e-6 threshold at tolerance 1e-8. Each one is
explained below. Most of them come from flat or nearly flat directions, where a quantity can move
far while the objective changes by a few watts or less. **Those solutions are not unique, so
individual values should not be read as predictions.** This applies above all to water-side
pressures, to temperatures on the return side, and to flows in lightly loaded pipes.

## Method

| Item | Choice |
|---|---|
| Upstream network | `example_network/` of ThermalModels.jl at commit `56ea809a570d3916d625c8433444ed55d4181052`, downloaded at run time and checked by SHA-256 |
| Formulation source | Hari, Srinivasan, Zlotnik, Sundar and Ewers, arXiv:2404.18868, and `docs/model-notes.md` |
| Solvers | MadNLP on the ExaModels model, Ipopt with MUMPS on the JuMP model, CPU only |
| Tolerance | 1e-8 on both, with the bound relaxation of both solvers set to zero |
| Relative difference | `abs(a - b) / max(abs(a), abs(b))` per element, then the maximum, in SI units |

The JuMP model shares only the network description with `src/model/`. It has its own constants,
bounds, scaling references, starting point and row selection. It states plant power as the
inequality of Eq. (1), so it has one variable fewer than the ExaModels model, and it drops the
redundant mass balance at the plant's steam junction where the ExaModels model drops the one at the
water junction. `run_validation.jl` stops with an error if the constants or bounds of the two models
differ.

Three choices affect how the results read:

- **Ipopt solves in two stages.** On the calibrated pipes, a cold start on Eq. (14) as printed ended
  in local infeasibility on the demo campus and on every scaled size. The first stage therefore
  substitutes Eq. (7) for `Tin - Tout` in that row, which is the form the ExaModels model has used
  since commit `71b0b1f`. Its solution starts the second stage, which solves Eq. (14) as printed.
  All reported Ipopt values come from the second stage, and no MadNLP value is used to start Ipopt.
- Ipopt uses the monotone barrier strategy.
- MadNLP runs with `bound_relax_factor = 0`, which is not its default.

## Provenance

Each row of `results/validation.csv` records the commit it was run on (`commit_sha`), the last
commits that changed the generator (`generator_commit`) and the model (`model_commit`), and a SHA-256
of the sources that determine the results (`source_hash`). `run_validation.jl` refuses to run with
uncommitted changes under `src/` or `validation/`.

`test/test_validation.jl` recomputes the hash and fails when it no longer matches. The hashed files
are listed in `validation/source_hash.jl`. A change to any of them, even one that does not alter the
numbers, requires rerunning the validation.

## Instance selection

The scaled instances are the two largest swept sizes that both solvers solve at tolerance 1e-8,
meaning MadNLP reports `SOLVE_SUCCEEDED` and Ipopt reports `LOCALLY_SOLVED`. The script applies this
rule, and the test checks it against `results/validation_size_sweep.csv`.

| Junctions | MadNLP | Ipopt | Objective, MadNLP (W) | Objective, Ipopt (W) | Validated |
|---|---|---|---|---|---|
| 200 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250481.30 | 1250480.29 | no |
| 300 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250486.45 | 1250485.32 | no |
| 400 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250496.16 | 1250494.72 | no |
| 500 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1726747.74 | 1726746.15 | no |
| 600 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1436077.26 | 1436074.95 | yes |
| 800 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1366686.25 | 1366685.32 | yes |

The sweep stops at 800 junctions because the project is scoped to campus-size networks.

## Files

| File | Contents |
|---|---|
| `results/validation.csv` | One row per instance at tolerance 1e-8 |
| `results/validation_tolerance_ladder.csv` | The same differences at tolerances 1e-8, 1e-10 and 1e-12 |
| `results/validation_optimal_face.csv` | Range of the worst-matching element of each quantity over near-optimal points |
| `results/validation_size_sweep.csv` | Solver outcome for every scaled size attempted |

The optimal-face check adds the constraint that the objective stays within a small slack of the
best value found, then minimizes and maximizes one quantity with Ipopt. The slack is twice the
objective gap between the two solvers, and at least 1e-9 of the objective. Each end is a local
solve, so the range is an inner estimate. An end counts as verified only if Ipopt converged and the
largest constraint violation is at most 1e-6. Every end cited below is verified.

## Explanations

The tags below are read by `test/test_validation.jl`. A row above 1e-6 fails the test unless it has
a tag here, and the `bound` caps the size of the difference that the explanation covers.

In the tables, "Pressure" is split by side. The `max_rel_diff_pressure` column of the CSV is the
larger of the two.

### Upstream example network

<!-- explains: instance=upstream_example metric=max_rel_diff_pressure bound=3e-4 -->
<!-- explains: instance=upstream_example metric=max_rel_diff_temperature bound=9e-3 -->
<!-- explains: instance=upstream_example metric=max_rel_diff_flow bound=6e-3 -->
<!-- explains: instance=upstream_example metric=rel_diff_plant_output bound=1.3e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 |
|---|---|---|---|
| Pressure, steam side | 1.5e-4 | 1.4e-7 | 3.0e-8 |
| Pressure, water side | 8.2e-6 | 7.8e-9 | 2.5e-8 |
| Temperature | 4.4e-3 | 7.4e-6 | 1.6e-6 |
| Flow | 2.8e-3 | 4.7e-6 | 1.0e-6 |
| Plant output | 6.2e-6 | 7.5e-9 | 1.6e-9 |

**Cause: a nearly flat direction, resolved as the tolerance tightens.** With a slack of 1.3e-3 W on
an objective of 310650 W, the water temperature at junction 18 can range from 353.89 K to 373.15 K,
and the flow in pipe 5 from 0.1077 kg/s to 0.1116 kg/s. The two solvers differ by 1.58 K and
3.1e-4 kg/s, inside those ranges. Temperature and flow are still 1.6e-6 and 1.0e-6 at tolerance
1e-12, slightly above the threshold.

### Demo campus

<!-- explains: instance=demo_campus metric=max_rel_diff_pressure bound=4e-3 -->
<!-- explains: instance=demo_campus metric=max_rel_diff_temperature bound=5e-2 -->
<!-- explains: instance=demo_campus metric=max_rel_diff_flow bound=0.67 -->
<!-- explains: instance=demo_campus metric=rel_diff_plant_output bound=5.1e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Pressure, steam side | 1.9e-3 | 8.6e-6 | 1.0e-7 | Nearly flat direction, resolved |
| Pressure, water side | 1.3e-3 | 1.3e-2 | 4.1e-2 | Flat direction |
| Temperature | 2.5e-2 | 1.7e-4 | 2.3e-4 | Flat direction, not resolved |
| Flow | 3.3e-1 | 1.7e-4 | 9.7e-3 | Flat direction, not resolved |
| Plant output | 2.5e-5 | 5.0e-8 | 3.5e-9 | Solver tolerance |

Within 1.24 W of an objective of 1250426 W:

| Quantity | Element | MadNLP | Ipopt | Near-optimal range |
|---|---|---|---|---|
| Steam pressure (Pa) | junction 38 | 927907 | 929705 | 924323 to 929716 |
| Water pressure (Pa) | junction 126 | 173884 | 173666 | 34474 to 268057 |
| Temperature (K) | junction 112 | 362.44 | 353.33 | 353.28 to 373.15 |
| Flow (kg/s) | pipe 111 | 0.0416 | 0.0277 | 0.0119 to 0.498 |

The largest flow difference, 33%, is on a pipe that carries about 0.03 kg/s. Water pressure,
temperature and flow do not settle as the tolerance tightens, which is what a flat direction does.
The objective contains only the plant's own pressures, flow and outlet temperature and the load
slacks, so it does not price these interior values directly.

### Scaled campus, 600 junctions

<!-- explains: instance=scaled_campus_600 metric=rel_diff_objective bound=3.3e-6 -->
<!-- explains: instance=scaled_campus_600 metric=max_rel_diff_pressure bound=1.3e-3 -->
<!-- explains: instance=scaled_campus_600 metric=max_rel_diff_temperature bound=2.4e-2 -->
<!-- explains: instance=scaled_campus_600 metric=max_rel_diff_flow bound=1.5e-2 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Objective | 1.6e-6 | 5.6e-9 | 7.7e-11 | Solver tolerance |
| Pressure, steam side | 6.4e-4 | 3.1e-4 | 3.2e-6 | Nearly flat direction |
| Pressure, water side | 6.9e-5 | 4.8e-5 | 3.7e-4 | Flat direction |
| Temperature | 1.2e-2 | 5.5e-3 | 5.6e-5 | Nearly flat direction, not resolved |
| Flow | 7.5e-3 | 3.6e-3 | 3.7e-5 | Nearly flat direction, not resolved |

**This is the only objective difference above the threshold.** MadNLP is 2.3 W above Ipopt on
1436075 W at tolerance 1e-8, and the difference falls by more than four orders of magnitude at
1e-12.

Within 4.6 W of the optimum, the pressure at water junction 415 ranges from 34474 Pa to 252278 Pa,
the temperature at junction 413 from 353.25 K to 373.15 K, and the flow in pipe 190 from 0.3611 kg/s
to 0.3736 kg/s. At tolerance 1e-10 Ipopt reports `ALMOST_LOCALLY_SOLVED`. At 1e-12 Ipopt reports the
same and MadNLP reports `SOLVED_TO_ACCEPTABLE_LEVEL`.

### Scaled campus, 800 junctions

<!-- explains: instance=scaled_campus_800 metric=max_rel_diff_pressure bound=0.16 -->
<!-- explains: instance=scaled_campus_800 metric=max_rel_diff_temperature bound=2.5e-2 -->
<!-- explains: instance=scaled_campus_800 metric=max_rel_diff_flow bound=1.5e-2 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Pressure, steam side | 3.3e-4 | 6.9e-6 | 1.8e-5 | Nearly flat direction, not resolved |
| Pressure, water side | 7.6e-2 | 1.4e-4 | 5.1e-1 | Flat direction |
| Temperature | 1.2e-2 | 1.1e-4 | 2.7e-4 | Nearly flat direction, not resolved |
| Flow | 7.4e-3 | 6.5e-5 | 1.6e-4 | Nearly flat direction, not resolved |

Within 1.9 W of an objective of 1366685 W, the pressure at water junction 570 ranges from 34474 Pa to
255574 Pa, the temperature at junction 657 from 353.30 K to 373.15 K, and the flow in pipe 361 from
0.2585 kg/s to 0.2675 kg/s. At tolerance 1e-12 Ipopt reports `ALMOST_LOCALLY_SOLVED`.

## Limits of this validation

- **Primal agreement to 1e-6 is not achieved.** At the tightest tolerance, temperature and flow
  remain above the threshold on all four instances, and water pressure on the demo campus and both
  scaled campuses. The flat directions are measured, but the physical mechanism behind each one was
  not separately identified.
- Local solvers cannot prove global optimality. Agreement between two solvers supports the result
  but does not prove that no better solution exists.
- The first Ipopt stage uses the same substitution as the ExaModels steam row, so the two solves are
  less independent in their path to the solution than in their final equations.
- The optimal-face ranges are inner estimates, and they were run only on the worst-matching element
  of each quantity.
- Networks above 800 junctions were not attempted.

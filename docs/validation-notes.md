# Reference validation notes

The ExaModels model in `src/model/` is compared with an independent JuMP + Ipopt statement of the
same problem in `validation/jump_model.jl`. All networks are synthetic. Run
`julia --project=validation validation/run_validation.jl` to regenerate every file cited here.

## Result

At the reference tolerance of 1e-8, the two models agree on the optimal objective to a relative
2.2e-6 or better on all four instances: 2.1e-9 on the upstream example, 5.0e-7 on the demo campus,
1.7e-6 on 600 junctions and 2.1e-6 on 800 junctions. At tolerance 1e-12 they agree to 9.6e-11 or
better. The MadNLP solution satisfies the constraints of the JuMP model, with Eq. (14) as printed in
the paper, to 8.5e-12 or better in that model's scaled rows. No formulation defect was found.

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
| 200 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250424.39 | 1250423.64 | no |
| 300 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250449.08 | 1250448.56 | no |
| 400 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250476.12 | 1250474.57 | no |
| 500 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250490.18 | 1250488.28 | no |
| 600 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250491.99 | 1250489.82 | yes |
| 800 | `SOLVE_SUCCEEDED` | `LOCALLY_SOLVED` | 1250494.98 | 1250492.30 | yes |

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

<!-- explains: instance=demo_campus metric=max_rel_diff_pressure bound=2e-2 -->
<!-- explains: instance=demo_campus metric=max_rel_diff_temperature bound=3e-2 -->
<!-- explains: instance=demo_campus metric=max_rel_diff_flow bound=0.65 -->
<!-- explains: instance=demo_campus metric=rel_diff_plant_output bound=5e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Pressure, steam side | 1.4e-3 | 3.0e-5 | 3.1e-5 | Nearly flat direction, not resolved |
| Pressure, water side | 1.6e-2 | 8.5e-3 | 1.0e-1 | Flat direction |
| Temperature | 2.3e-2 | 1.9e-3 | 3.1e-3 | Flat direction, not resolved |
| Flow | 6.0e-1 | 7.0e-1 | 1.2e-1 | Flat direction, not resolved |
| Plant output | 3.8e-5 | 3.2e-7 | 8.4e-9 | Solver tolerance |

Within 1.24 W of an objective of 1250416 W:

| Quantity | Element | MadNLP | Ipopt | Near-optimal range |
|---|---|---|---|---|
| Steam pressure (Pa) | junction 63 | 951275 | 952593 | 948996 to 952664 |
| Water pressure (Pa) | junction 152 | 155648 | 153205 | 34474 to 253435 |
| Temperature (K) | junction 160 | 361.80 | 353.38 | 353.22 to 373.15 |
| Flow (kg/s) | pipe 115 | 1.240 | 0.502 | 0.0046 to 3.000 |

The largest flow difference, 60%, is on pipe 115, a condensate pipe on the second cross-tie. Its flow
can range from almost zero to 3 kg/s within the slack, because the split of condensate around a loop
is priced by nothing in the objective. Water pressure, temperature and flow do not settle as the
tolerance tightens, which is what a flat direction does. The objective contains only the plant's
own pressures, flow and outlet temperature and the load slacks, so it does not price these interior
values directly.

### Scaled campus, 600 junctions

<!-- explains: instance=scaled_campus_600 metric=rel_diff_objective bound=2e-6 -->
<!-- explains: instance=scaled_campus_600 metric=max_rel_diff_pressure bound=3e-3 -->
<!-- explains: instance=scaled_campus_600 metric=max_rel_diff_temperature bound=3.5e-2 -->
<!-- explains: instance=scaled_campus_600 metric=max_rel_diff_flow bound=4e-2 -->
<!-- explains: instance=scaled_campus_600 metric=rel_diff_plant_output bound=6e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Objective | 1.7e-6 | 3.2e-9 | 9.6e-11 | Solver tolerance |
| Pressure, steam side | 2.1e-3 | 6.4e-5 | 1.4e-4 | Nearly flat direction, not resolved |
| Pressure, water side | 1.6e-3 | 6.8e-3 | 5.3e-2 | Flat direction |
| Temperature | 3.0e-2 | 1.9e-3 | 7.4e-3 | Flat direction, not resolved |
| Flow | 3.3e-2 | 4.6e-1 | 7.6e-1 | Flat direction, not resolved |
| Plant output | 5.0e-5 | 1.9e-7 | 2.0e-7 | Solver tolerance |

MadNLP is 2.2 W above Ipopt on 1250490 W at tolerance 1e-8, and the difference falls by more than
four orders of magnitude at 1e-12.

Within 4.4 W of the optimum, the steam pressure at junction 251 ranges from 930741 Pa to 935831 Pa,
the pressure at water junction 557 from 34474 Pa to 268273 Pa, the temperature at junction 513 from
353.20 K to 373.15 K, and the flow in condensate pipe 328 from 0.006 kg/s to 9.98 kg/s. At tolerance
1e-12 MadNLP reports `SOLVED_TO_ACCEPTABLE_LEVEL`.

### Scaled campus, 800 junctions

<!-- explains: instance=scaled_campus_800 metric=rel_diff_objective bound=2.5e-6 -->
<!-- explains: instance=scaled_campus_800 metric=max_rel_diff_pressure bound=0.3 -->
<!-- explains: instance=scaled_campus_800 metric=max_rel_diff_temperature bound=3e-2 -->
<!-- explains: instance=scaled_campus_800 metric=max_rel_diff_flow bound=0.45 -->
<!-- explains: instance=scaled_campus_800 metric=rel_diff_plant_output bound=8e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Objective | 2.1e-6 | 4.0e-9 | 8.2e-11 | Solver tolerance |
| Pressure, steam side | 1.9e-3 | 5.9e-5 | 4.4e-4 | Nearly flat direction, not resolved |
| Pressure, water side | 2.8e-1 | 6.2e-3 | 8.6e-2 | Flat direction |
| Temperature | 2.6e-2 | 2.3e-3 | 1.4e-2 | Flat direction, not resolved |
| Flow | 4.2e-1 | 4.2e-1 | 5.2e-1 | Flat direction, not resolved |
| Plant output | 7.2e-5 | 3.1e-7 | 3.5e-7 | Solver tolerance |

MadNLP is 2.7 W above Ipopt on 1250492 W at tolerance 1e-8, and the difference falls by more than
four orders of magnitude at 1e-12.

Within 5.3 W of the optimum, the steam pressure at junction 297 ranges from 939157 Pa to 943645 Pa,
the pressure at water junction 748 from 34474 Pa to 255290 Pa, the temperature at junction 747 from
353.24 K to 373.15 K, and the flow in condensate pipe 430 from 0.005 kg/s to 9.69 kg/s. At tolerance
1e-12 MadNLP reports `SOLVED_TO_ACCEPTABLE_LEVEL` and Ipopt `ALMOST_LOCALLY_SOLVED`.

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

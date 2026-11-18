# Reference validation notes

The ExaModels model in `src/model/` is compared with an independent JuMP + Ipopt statement of the
same problem in `validation/jump_model.jl`. All networks are synthetic. Run
`julia --project=validation validation/run_validation.jl` to regenerate every file cited here.

## Result

The two models agree on the optimal objective to a relative 2.3e-7 or better on all four instances,
and the MadNLP solution satisfies the constraints of the JuMP model to 1.5e-9 or better in that
model's scaled rows. No formulation defect was found.

Many primal quantities differ by more than the 1e-6 threshold at the reference tolerance of 1e-8.
Each one is explained below. The explanations are of two kinds: solver tolerance, where the
difference shrinks as the tolerance tightens, and flat or nearly flat directions, where the
quantity can move far without changing the objective. In the second case **the solution is not
unique, so the individual values should not be read as predictions**. This applies above all to
water-side pressures.

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

Two choices affect how the results read:

- Ipopt uses the monotone barrier strategy. With the adaptive strategy it reported local
  infeasibility on `scaled_campus_400`.
- MadNLP runs with `bound_relax_factor = 0`, which is not its default.

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
largest constraint violation is at most 1e-6. Where an end is unverified, the reported width uses
the solver values instead.

## Explanations

The tags below are read by `test/test_validation.jl`. A row above 1e-6 fails the test unless it has
a tag here, and the `bound` caps the size of the difference that the explanation covers.

### Upstream example network

<!-- explains: instance=upstream_example metric=max_rel_diff_pressure bound=3e-4 -->
<!-- explains: instance=upstream_example metric=max_rel_diff_temperature bound=1e-2 -->
<!-- explains: instance=upstream_example metric=max_rel_diff_flow bound=6e-3 -->
<!-- explains: instance=upstream_example metric=rel_diff_plant_output bound=2e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 |
|---|---|---|---|
| Pressure, steam side | 1.4e-4 | 1.1e-9 | 4.5e-7 |
| Temperature | 4.4e-3 | 6.0e-8 | 2.4e-5 |
| Flow | 2.8e-3 | 3.8e-8 | 1.5e-5 |
| Plant output | 6.1e-6 | 6.0e-11 | 2.4e-8 |

**Cause: a nearly flat direction, resolved only as far as the solver tolerance allows.** With a
slack of 1.3e-3 W on an objective of 310650 W, the water temperature at junction 18 can range over
19.3 K, from 353.89 K to 373.15 K, and the flow in pipe 5 over 3.9e-3 kg/s. Both ends of both ranges
are verified. The two solvers differ by 1.57 K and 3.1e-4 kg/s, well inside those ranges.

The differences do not fall steadily with the tolerance. They are smallest at 1e-10 and larger
again at 1e-12, which fits a direction that the objective barely constrains.

### Demo campus

<!-- explains: instance=demo_campus metric=max_rel_diff_pressure bound=6e-4 -->
<!-- explains: instance=demo_campus metric=max_rel_diff_temperature bound=4e-5 -->
<!-- explains: instance=demo_campus metric=max_rel_diff_flow bound=3e-5 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Pressure, water side | 2.9e-4 | 1.2e-4 | 1.2e-4 | Flat direction |
| Pressure, steam side | 1.7e-6 | 6.0e-9 | 8.8e-11 | Solver tolerance |
| Temperature | 1.9e-5 | 6.4e-8 | 9.5e-10 | Solver tolerance |
| Flow | 1.1e-5 | 3.9e-8 | 5.8e-10 | Solver tolerance |

**Water-side pressure is not unique.** Within 0.91 W of the optimum, the pressure at junction 92
ranges from 34474 Pa to 235207 Pa, with both ends verified. The solvers differ by 49 Pa. The
objective contains only the plant's own pressures, so it does not price the pressure at this
junction. The difference stays at 1.2e-4 when the tolerance is tightened, as expected for a
genuinely flat direction.

The other three differences fall to 1e-9 or below at tolerance 1e-12, so they are solver tolerance.
At 1e-12 Ipopt reports `ALMOST_LOCALLY_SOLVED`, not `LOCALLY_SOLVED`.

### Scaled campus, 300 junctions

<!-- explains: instance=scaled_campus_300 metric=max_rel_diff_pressure bound=9e-2 -->
<!-- explains: instance=scaled_campus_300 metric=max_rel_diff_temperature bound=1.1e-5 -->
<!-- explains: instance=scaled_campus_300 metric=max_rel_diff_flow bound=1e-3 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Pressure, water side | 4.2e-2 | 4.4e-2 | 3.1e-1 | Flat direction |
| Pressure, steam side | 3.2e-3 | 1.0e-3 | 1.4e-7 | Nearly flat direction |
| Temperature | 5.4e-6 | 7.0e-7 | 3.8e-8 | Solver tolerance |
| Flow | 4.8e-4 | 1.6e-4 | 6.3e-6 | Nearly flat direction, not resolved |

Within 2.2 W of an objective of 2.8e7 W, the pressure at water junction 295 ranges over 2.3e5 Pa and
the flow in pipe 180 over 0.97 kg/s, from 0.42 kg/s to 1.39 kg/s. Those ends are verified. The
steam-side range at junction 145 has one unverified end, because the lower solve hit the iteration
limit, so only the width of 5.8e5 Pa between the verified upper end and the solver values is cited.

**The flow difference stays above the threshold at the tightest tolerance**, at 6.3e-6. This
instance sheds load at 2 loads and releases excess heat at 17. Moving flow between loads that all
have excess heat would leave the objective unchanged, which could produce this flat direction, but
that mechanism was not tested separately.

### Scaled campus, 400 junctions

<!-- explains: instance=scaled_campus_400 metric=max_rel_diff_pressure bound=6e-3 -->
<!-- explains: instance=scaled_campus_400 metric=max_rel_diff_temperature bound=5e-6 -->
<!-- explains: instance=scaled_campus_400 metric=max_rel_diff_flow bound=6e-4 -->

| Metric | At 1e-8 | At 1e-10 | At 1e-12 | Cause |
|---|---|---|---|---|
| Pressure, water side | 2.6e-3 | 1.5e-4 | 2.6e-6 | Flat direction |
| Pressure, steam side | 2.3e-5 | 2.9e-5 | 1.2e-8 | Nearly flat direction |
| Temperature | 2.2e-6 | 7.3e-6 | 1.4e-7 | Solver tolerance |
| Flow | 2.8e-4 | 1.5e-3 | 2.7e-5 | Nearly flat direction, not resolved |

Within 1.1 W of an objective of 3.1e7 W, the pressure at water junction 375 ranges over 1.9e5 Pa and
the flow in pipe 269 over 3.0 kg/s, with all four ends verified. This instance sheds load at 3 loads
and releases excess heat at 14. At tolerance 1e-10 MadNLP stops at `SOLVED_TO_ACCEPTABLE_LEVEL`,
which is why that column is not monotone. As on the 300-junction campus, the flow difference stays
above the threshold at the tightest tolerance.

## Limits of this validation

- **Scaled sizes above 400 junctions are not validated.** In the size sweep, MadNLP reached its
  3000 iteration limit at 500 and 800 junctions, and Ipopt reported local infeasibility at 500, 600
  and 800. MadNLP converged at 600 junctions, but no second solver confirms that result. On those
  networks the plant runs at or near its rating with more than 70 MW of shed load, so these
  instances say little about the model until the generator's pipe data is recalibrated.
- The sizes 300 and 400 were chosen after the sweep, as the two largest that both solvers solved.
- Local solvers cannot prove global optimality. Agreement between two solvers from different
  starting points supports the result but does not prove that no better solution exists.
- The optimal-face ranges are inner estimates, and they were run only on the worst-matching element
  of each quantity.
- These results use the generator as of commit `d2c84e0b7960647759625770ede70d45ed30b7a0`.

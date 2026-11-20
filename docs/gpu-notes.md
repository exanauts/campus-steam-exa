# GPU notes

These notes record how the demo behaves on one GPU today. All networks, demand profiles and historian
data are synthetic and describe no real campus. Every number below comes from a run in this repository,
and each section names the file that holds it.

The demo stays at one plant and campus size. The GPU did not need to win here, and at most sizes it did
not.

**Two network layouts appear in these notes.** The campus generator was later changed from a street grid
to a trunk-and-branch layout, and the demo campus went from 132 to 166 junctions. The sections below
are marked as follows.

- **Repeated on the current layout, at commit `2ec4de5`:** "KKT behavior and regularization",
  "Variable scaling", "Bound relaxation on the GPU" and "Calibration problem".
- **Still from the earlier street-grid layout, at commit `6fd4ac9`:** the benchmark sweep and
  everything taken from it, that is the run setup, the like-for-like comparison, default settings,
  where the time goes, the Ipopt reference, agreement with the CPU, GPU memory, time to first solve,
  and the T = 8,760 attempt. The scaled campuses (200 to 800 junctions) also come from the generator,
  so they changed too. A repeat of the sweep on the current layout was started and stopped before it
  finished, because at the pace it ran it would not have fit in the time set aside for it. Its partial
  output was not committed and is not used here, so the current layout has no sweep result yet. Treat the numbers in these sections as a record of the
  earlier layout, not as a description of the current one.

## How the runs were made (earlier layout)

| Item | Value |
|---|---|
| Results | [`results/benchmarks.csv`](../results/benchmarks.csv), summarized in [`results/benchmarks_summary.json`](../results/benchmarks_summary.json) |
| Console log | [`results/logs/benchmarks_local_sweep.txt`](../results/logs/benchmarks_local_sweep.txt) |
| Commit and date | `6fd4ac9`, 2026-11-18 |
| GPU | One NVIDIA H200, driver 580.178.04, CUDA runtime 13.4.0 |
| CPU | INTEL(R) XEON(R) PLATINUM 8568Y+, one Julia thread, one BLAS thread in MadNLP |
| Packages | Julia 1.13.3, MadNLP 0.11.0, MadNLPGPU 0.11.1, CUDA 6.5.1, CUDSS 1.0.0, ExaModels 0.15.0 |
| Solvers | CPU: MadNLP with MUMPS. GPU: MadNLP with cuDSS on the condensed KKT system. Reference: Ipopt with MUMPS on the same ExaModel |
| Repeats | 5 per case, solver and tolerance |
| Other GPU work | No other compute process was seen on the GPU during any timed run |
| Compilation | Excluded by warm-up solves. The compile time recorded inside timed solves was 0 s in every run |

Times are medians, with the minimum and maximum over the repeats in brackets. A repeat counts as solved
only if MadNLP reports `SOLVE_SUCCEEDED`. The KKT residual is recomputed from the returned point on the
unscaled model with one function for all solvers, and the table shows the largest value over the repeats.

## Like-for-like comparison (earlier layout)

Both devices were asked for a tolerance of 1e-8 with MadNLP's acceptable termination switched off, and
with the same bound relaxation of 1e-8. Medians use the repeats that solved. Residuals count as matched
when the GPU's KKT residual is at most twice the CPU's.

| Case | Variables | CPU time (s) | GPU time (s) | GPU / CPU | GPU repeats solved | KKT residual, CPU | KKT residual, GPU | Residuals matched |
|---|---|---|---|---|---|---|---|---|
| Demo campus (132 junctions) | 1,008 | 0.057 (0.057 to 0.057) | 0.907 (0.439 to 1.24) | 15.93 | 5 of 5 | 2.5e-07 | 2.6e-07 | yes |
| Scaled campus, 200 junctions | 1,534 | 0.105 (0.105 to 0.108) | 0.370 (0.288 to 0.399) | 3.51 | 5 of 5 | 2.5e-07 | 2.6e-07 | yes |
| Scaled campus, 300 junctions | 2,322 | 0.207 (0.205 to 0.211) | 0.454 (0.413 to 0.508) | 2.20 | 5 of 5 | 2.5e-07 | 2.5e-07 | yes |
| Scaled campus, 400 junctions | 3,110 | 0.250 (0.250 to 0.254) | 0.778 (0.748 to 0.884) | 3.11 | 5 of 5 | 9.1e-08 | 2.6e-07 | no |
| Scaled campus, 500 junctions | 3,898 | 0.313 (0.313 to 0.370) | 0.689 (0.560 to 2.08) | 2.20 | 5 of 5 | 2.5e-07 | 1.5e-06 | no |
| Scaled campus, 600 junctions | 4,686 | 0.364 (0.363 to 0.364) | 0.945 (0.841 to 1.05) | 2.60 | 5 of 5 | 2.5e-07 | 2.5e-07 | yes |
| Scaled campus, 800 junctions | 6,268 | 0.629 (0.629 to 0.637) | 1.06 (0.894 to 1.56) | 1.69 | 5 of 5 | 2.5e-07 | 3.4e-07 | yes |
| Demo campus, T = 24 | 24,192 | 1.50 (1.49 to 1.50) | 4.59 (3.69 to 5.11) | 3.07 | 5 of 5 | 2.5e-07 | 1.5e-07 | yes |
| Demo campus, T = 168 | 169,344 | 14.3 (13.9 to 20.9) | 16.6 (11.6 to 22.9) | 1.16 | 5 of 5 | 2.5e-07 | 1.6e-07 | yes |
| Demo campus, T = 720 | 725,760 | 88.2 (88.0 to 97.6) | 41.8 (10.1 to 71.4) | 0.47 | 4 of 5 | 2.5e-07 | 1.7e-07 | yes |

**No crossover was observed under the rule used here,** which requires the GPU to be faster at a size
and every larger size, with every repeat solved and residuals matched.

- **Network size.** The GPU was slower at all seven sizes, single period. The ratio fell from
  15.9 times the CPU time on the demo campus to 1.69 times at 800 junctions. At 400 and 500 junctions the
  GPU's residual was also more than twice the CPU's.
- **Number of periods.** The GPU was 3.07 times the CPU time at T = 24 and 1.16 times at T = 168.
- **T = 720 is the one case where the GPU's median was lower**, at 41.8 s against 88.2 s
  on the CPU. One of its five repeats did not solve: it stopped at the 1000-iteration limit after
  81.5 s. Counting that repeat as well, the median of all five GPU runs is 69.5 s. The solved repeats
  ranged from 10.1 s to 71.4 s, so this is not a dependable speedup.

The tolerance of 1e-6 is in the results file but is not used for a comparison. At T = 24, 168 and 720
the GPU's KKT residual at that setting was about seven times the CPU's, so those runs are not like for
like.

## Default settings (earlier layout)

These runs use each solver's defaults at a requested tolerance of 1e-8, so acceptable termination is
on. They are the known unequal comparison: the GPU often stops at `SOLVED_TO_ACCEPTABLE_LEVEL` while the
CPU reaches 1e-8. The achieved residual is shown beside each time.

| Case | CPU status | CPU time (s) | CPU KKT residual | GPU repeats at 1e-8 | GPU repeats at acceptable level | GPU time (s) | GPU KKT residual |
|---|---|---|---|---|---|---|---|
| Demo campus (132 junctions) | `SOLVE_SUCCEEDED` | 0.057 (0.057 to 0.057) | 2.5e-07 | 5 of 5 | 0 of 5 | 0.541 (0.437 to 8.25) | 2.6e-07 |
| Scaled campus, 200 junctions | `SOLVE_SUCCEEDED` | 0.109 (0.106 to 0.111) | 2.5e-07 | 5 of 5 | 0 of 5 | 0.424 (0.289 to 0.562) | 2.6e-07 |
| Scaled campus, 300 junctions | `SOLVE_SUCCEEDED` | 0.206 (0.206 to 0.213) | 2.5e-07 | 5 of 5 | 0 of 5 | 0.443 (0.393 to 0.468) | 2.6e-07 |
| Scaled campus, 400 junctions | `SOLVE_SUCCEEDED` | 0.311 (0.257 to 0.441) | 9.1e-08 | 5 of 5 | 0 of 5 | 0.882 (0.705 to 1.37) | 2.6e-07 |
| Scaled campus, 500 junctions | `SOLVE_SUCCEEDED` | 0.387 (0.321 to 0.389) | 2.5e-07 | 5 of 5 | 0 of 5 | 0.733 (0.559 to 0.801) | 2.9e-07 |
| Scaled campus, 600 junctions | `SOLVE_SUCCEEDED` | 0.363 (0.363 to 0.392) | 2.5e-07 | 5 of 5 | 0 of 5 | 0.903 (0.848 to 1.04) | 2.6e-07 |
| Scaled campus, 800 junctions | `SOLVE_SUCCEEDED` | 0.629 (0.628 to 0.639) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.14 (0.849 to 3.09) | 1.0e-06 |
| Demo campus, T = 24 | `SOLVE_SUCCEEDED` | 1.59 (1.51 to 2.59) | 2.5e-07 | 0 of 5 | 5 of 5 | 2.31 (1.61 to 3.07) | 5.4e-07 |
| Demo campus, T = 168 | `SOLVE_SUCCEEDED` | 13.9 (13.8 to 20.2) | 2.5e-07 | 1 of 5 | 4 of 5 | 6.16 (2.25 to 9.25) | 3.1e-07 |
| Demo campus, T = 720 | `SOLVE_SUCCEEDED` | 88.1 (88.1 to 88.4) | 2.5e-07 | 1 of 5 | 4 of 5 | 25.7 (12.2 to 66.3) | 3.4e-07 |

## Where the time goes (earlier layout)

Strict runs at 1e-8, as medians over all five repeats, including the T = 720 repeat that stopped at the
iteration limit. "Other" is the rest of the solve, including building the condensed KKT system, which
MadNLP does not count as linear solver time.

| Case | Device | Total (s) | Linear solver (s) | Function evaluation (s) | Other (s) | Iterations |
|---|---|---|---|---|---|---|
| Demo campus (132 junctions) | CPU | 0.057 | 0.049 | 0.002 | 0.006 | 51 (51 to 51) |
| Demo campus (132 junctions) | GPU | 0.907 | 0.688 | 0.042 | 0.178 | 115 (83 to 138) |
| Scaled campus, 800 junctions | CPU | 0.629 | 0.558 | 0.018 | 0.053 | 87 (87 to 87) |
| Scaled campus, 800 junctions | GPU | 1.06 | 0.672 | 0.066 | 0.326 | 151 (147 to 186) |
| Demo campus, T = 168 | CPU | 14.3 | 12.0 | 0.884 | 1.35 | 64 (64 to 64) |
| Demo campus, T = 168 | GPU | 16.6 | 13.6 | 0.406 | 2.60 | 523 (343 to 732) |
| Demo campus, T = 720 | CPU | 88.2 | 76.4 | 3.27 | 8.51 | 76 (76 to 76) |
| Demo campus, T = 720 | GPU | 69.5 | 59.0 | 1.01 | 9.50 | 888 (127 to 1000) |

## Ipopt reference (earlier layout)

Ipopt runs on the CPU with default settings and a tolerance of 1e-8.

| Case | Ipopt time (s) | Ipopt iterations | MadNLP CPU time (s) | MadNLP CPU iterations |
|---|---|---|---|---|
| Demo campus (132 junctions) | 0.093 (0.093 to 0.096) | 52 | 0.057 (0.057 to 0.057) | 51 |
| Scaled campus, 200 junctions | 0.169 (0.169 to 0.171) | 57 | 0.109 (0.106 to 0.111) | 53 |
| Scaled campus, 300 junctions | 0.387 (0.383 to 0.390) | 74 | 0.206 (0.206 to 0.213) | 62 |
| Scaled campus, 400 junctions | 0.413 (0.412 to 0.415) | 75 | 0.311 (0.257 to 0.441) | 71 |
| Scaled campus, 500 junctions | 0.813 (0.813 to 0.815) | 104 | 0.387 (0.321 to 0.389) | 78 |
| Scaled campus, 600 junctions | 0.865 (0.864 to 0.868) | 83 | 0.363 (0.363 to 0.392) | 75 |
| Scaled campus, 800 junctions | 1.21 (1.20 to 1.22) | 87 | 0.629 (0.628 to 0.639) | 87 |
| Demo campus, T = 24 | 1.83 (1.82 to 2.06) | 58 | 1.59 (1.51 to 2.59) | 58 |
| Demo campus, T = 168 | 20.5 (20.5 to 20.7) | 72 | 13.9 (13.8 to 20.2) | 64 |
| Demo campus, T = 720 | 190.0 (185.5 to 201.6) | 115 | 88.1 (88.1 to 88.4) | 76 |

## Agreement with the CPU (earlier layout)

The largest difference over all ten cases and all solved or unsolved GPU repeats at 1e-8:

| Quantity | Largest relative difference from the CPU |
|---|---|
| Objective | 9.0e-06 |
| Plant output | 2.7e-05 |
| Steam-side pressure | 9.4e-04 |
| Steam-side temperature | 1.1e-03 |
| Flow in steam pipes above 1% of plant flow | 1.3e-02 |

The quantities below are reported separately because
[`docs/validation-notes.md`](validation-notes.md) shows they are not unique at the optimum. Differences
of tens of percent are expected between correct solutions, so they do not measure solver accuracy.

| Quantity, not unique at the optimum | Largest relative difference from the CPU |
|---|---|
| Water-side pressure | 2.2e-01 |
| Return-side temperature | 1.9e-02 |
| Flow in pipes below 1% of plant flow | 9.1e-01 |

## GPU iteration counts vary between runs

The CPU took the same number of iterations in every repeat. The GPU did not. In the sweep on the earlier
layout, at T = 720 and 1e-8, it took between 127 and 1000 iterations on identical input. On the current
layout the diagnostics above show the same pattern on a smaller scale: at T = 24 with gradient scaling off
the GPU took 41 to 155 iterations, while the CPU took 46 every time.

In an exploration on the current layout with the bound relaxation held at 1e-8, one of three GPU repeats
at T = 24 and a tolerance of 1e-7 ended with `INFEASIBLE_PROBLEM_DETECTED`, while the two other repeats
solved ([log](../results/logs/relaxation_pinned.txt)). The problem is feasible.

## KKT behavior and regularization

Current layout. From [`results/gpu_diagnostics.csv`](../results/gpu_diagnostics.csv), produced by
[`scripts/site/gpu_diagnostics.jl`](../scripts/site/gpu_diagnostics.jl) at commit `2ec4de5` on
2026-11-20, with three repeats per row after one untimed warm-up solve. All runs ask for a tolerance of
1e-8 with acceptable termination off and a bound relaxation of 1e-8. The regularization share is the
number of iterations with inertia regularization divided by all iterations, over the three repeats.
Restoration iterations are the sum over the three repeats. The machine, GPU model and package versions
are those listed for the earlier sweep above. The host was shared with other users' jobs during these
runs, so their solve times are not used in these notes.

| Case | Variant | Device | Repeats solved | Iterations | Iterations with inertia regularization | Restoration iterations (sum over repeats) | Mean refinement steps | Largest refinement steps |
|---|---|---|---|---|---|---|---|---|
| Demo campus (166 junctions) | Default | CPU | 3 of 3 | 52 to 52 | 52% | 0 | 1.0 | 1 |
| Demo campus (166 junctions) | Default | GPU | 3 of 3 | 39 to 47 | 88% | 0 | 8.5 | 30 |
| Demo campus (166 junctions) | Solver gradient scaling off | CPU | 3 of 3 | 57 to 57 | 9% | 0 | 1.1 | 2 |
| Demo campus (166 junctions) | Solver gradient scaling off | GPU | 3 of 3 | 70 to 100 | 77% | 0 | 11.7 | 30 |
| Demo campus (166 junctions) | SI units, no fixed references | CPU | 3 of 3 | 78 to 78 | 13% | 0 | 1.0 | 2 |
| Demo campus (166 junctions) | SI units, no fixed references | GPU | 3 of 3 | 124 to 413 | 100% | 0 | 13.0 | 30 |
| Demo campus, T = 24 | Default | CPU | 3 of 3 | 86 to 86 | 67% | 0 | 1.0 | 2 |
| Demo campus, T = 24 | Default | GPU | 3 of 3 | 75 to 80 | 94% | 0 | 6.2 | 30 |
| Demo campus, T = 24 | Solver gradient scaling off | CPU | 3 of 3 | 46 to 46 | 11% | 0 | 1.1 | 2 |
| Demo campus, T = 24 | Solver gradient scaling off | GPU | 3 of 3 | 41 to 155 | 81% | 21 | 9.3 | 30 |
| Demo campus, T = 24 | SI units, no fixed references | CPU | 3 of 3 | 786 to 786 | 90% | 18 | 1.0 | 2 |
| Demo campus, T = 24 | SI units, no fixed references | GPU | 1 of 3 | 741 to 1000 | 78% | 2 | 18.7 | 30 |

- With default settings the GPU applied inertia regularization on 88% of iterations on the demo campus and
  94% at T = 24. The CPU applied it on 52% and 67%. On the earlier layout the CPU figures were 12% and
  19%, so the CPU now regularizes much more often than it did, while the GPU still regularizes on
  almost every iteration.
- The GPU needed many more iterative refinement steps than the CPU and reached the limit of 30 that
  these runs set in every configuration. The CPU never used more than 2.
- With default settings the GPU took about as many iterations as the CPU here (39 to 47 against 52 on
  the demo campus, 75 to 80 against 86 at T = 24), and no repeat entered restoration. On the earlier
  layout the GPU took 85 to 190 and 330 to 395 iterations and entered restoration in both cases.
- The cause of the frequent regularization was not isolated. The two devices differ in KKT form
  (condensed on the GPU, augmented on the CPU) as well as in the linear solver, and these runs do not
  separate those effects.

## Bound relaxation on the GPU

MadNLP's GPU default ties the bound relaxation to the requested tolerance. At loose tolerances the GPU
therefore solves a visibly different problem. In an exploration at commit `cfa873a`, at T = 24 and a tolerance of 1e-4 the GPU objective was
2836.22, against 3003.02 on the CPU ([log](../results/logs/relaxation_tied_to_tol.txt)). With the relaxation
held at 1e-8 the GPU objective was 3003.02 ([log](../results/logs/relaxation_pinned.txt)). The strict
runs above hold it at 1e-8 on both devices.

## Variable scaling

Current layout. The table above also shows two scaling changes.

- **Solver gradient scaling off.** Both devices solved every repeat. On the GPU at T = 24 one repeat took
  155 iterations, and the three repeats spent 21 iterations in restoration between them. On the earlier
  layout two of three GPU repeats at T = 24 stopped at the iteration limit.
- **SI units, without the model's fixed references.** The demo campus solved on both devices, but the
  GPU's KKT residual on the unscaled model was 0.014 to 7.1 against 0.0025 on the CPU, so its reported
  success does not mean the same accuracy. At T = 24 the CPU solved all three repeats but needed 786
  iterations, against 86 with the fixed references. The GPU solved one of three repeats, in 741
  iterations, and the other two stopped at the 1000-iteration limit.

The fixed references in `SteamModelOptions` matter. Without them the T = 24 problem took about nine
times as many iterations on the CPU and mostly failed on the GPU. On the earlier layout it did not
solve on either device.

## GPU memory (earlier layout)

Peak memory of one solve in a fresh process, as reported by `nvidia-smi`, sampled every 200 ms. It includes
everything the process holds on the GPU.

| Case | Variables | Peak GPU memory (MiB) |
|---|---|---|
| Demo campus (132 junctions) | 1,008 | 786 |
| Scaled campus, 200 junctions | 1,534 | 788 |
| Scaled campus, 300 junctions | 2,322 | 852 |
| Scaled campus, 400 junctions | 3,110 | 920 |
| Scaled campus, 500 junctions | 3,898 | 1,048 |
| Scaled campus, 600 junctions | 4,686 | 1,112 |
| Scaled campus, 800 junctions | 6,268 | 1,274 |
| Demo campus, T = 24 | 24,192 | 2,376 |
| Demo campus, T = 168 | 169,344 | 36,044 |
| Demo campus, T = 720 | 725,760 | 36,138 |

Peak memory was almost the same at T = 168 and T = 720. This was not explained, so these values should not
be extrapolated to other sizes. The sampler also counted one other process on the GPU during these
memory runs. The likely source is the parent sweep process, which holds its own GPU context. The per-process
reading above excludes it.

## Time to first solve (earlier layout)

Demo campus, fresh process, median of three runs, with packages already precompiled.

| Device | Package load (s) | First build and solve (s) | Second build and solve (s) | Whole process (s) |
|---|---|---|---|---|
| CPU | 1.21 | 14.1 | 0.055 | 18.4 |
| GPU | 5.40 | 73.2 | 0.381 | 82.8 |

## Calibration problem

Current layout. The calibration problem runs on a synthetic 40-junction campus (`scaled_campus(40)`,
42 pipes, 9 loads). Outcomes are read from the CI site build of commit `2ec4de5` (site workflow run
44576986084), in [`results/calibration_ci_excerpt.json`](../results/calibration_ci_excerpt.json), and
the benchmark step does not solve it again. These notes make no claim about accuracy against months of
data.

| 25 tags | Variables | CPU | GPU |
|---|---|---|---|
| 1 month | 187,616 | `SOLVE_SUCCEEDED`, 21 iterations | `SOLVE_SUCCEEDED`, 19 iterations |
| 3 months | 562,836 | `SOLVE_SUCCEEDED`, 24 iterations | Not run in any recorded build |
| 6 months | 1,125,666 | `SOLVE_SUCCEEDED`, 59 iterations | Not run in any recorded build |

The site build attempts the GPU only at 25 tags and 1 month.

## What was not run

- **The benchmark sweep on the current layout** has not been completed. A run was started and stopped
  before it finished; see the top of these notes.
- **Calibration on the GPU at 25 tags and 3 months** has not been run in any recorded build.
- **T = 8,760 did not finish on the earlier layout and was not run on the current one.** One attempt per
  device at commit `6fd4ac9`, with limits of 1800 s and 1000 iterations. The CPU stopped at the time limit
  after 101 iterations, and the GPU stopped at the iteration limit after 780 s
  ([log](../results/logs/benchmarks_year_attempt.txt)).
- **Single precision** was not tested, because the model builders use `Float64`.
- **A multi-threaded CPU** was not tested. The CPU times use one thread.
- **The augmented KKT system on the GPU** was not tested.
- **Asynchronous cuDSS in the strict runs** was not tested. The strict GPU runs use synchronous cuDSS so that
  MadNLP reports linear solver time. In the default-settings runs on the earlier layout the asynchronous
  mode, which is the package default, had the lower median in 9 of 10 cases, so the strict GPU times may
  be somewhat pessimistic.

## Where the GPU may pay off later

Nothing in this section has produced a result, and no speedup is projected. Year-long horizons were attempted
once, on the earlier layout, and did not finish. The other items have not been run. Each item states what would need to be
true for it to pay off.

| Opportunity | Status | What would need to be true |
|---|---|---|
| Year-long horizons | Did not finish | The one attempt at T = 8,760, on the earlier layout, did not finish on either device. The GPU must converge reliably at that size. Iteration counts must stop varying as widely as they did at T = 720 on the earlier layout, and the factorization must fit in GPU memory |
| Many-scenario contingency screening | Not run | Scenarios must share one sparsity pattern so that one symbolic analysis and batched factorization can be reused, and each scenario must converge without manual restarts |
| Calibration over full historian history | Not run | The GPU must solve the longer records that the CPU solves, and the problem must fit in GPU memory. The 3-month case has not been run on the GPU in any recorded build |
| Embedded learned load models | Not run | The learned model must be expressed in forms ExaModels can evaluate on the GPU, and function evaluation must become a large share of solve time. Today it is a small share |

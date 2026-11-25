# GPU notes

These notes record how the demo behaves on one GPU today. All networks, demand profiles and historian
data are synthetic and describe no real campus. Every number below comes from a run in this repository,
and each section names the file that holds it.

The demo stays at one plant and campus size. The GPU did not need to win here. In the committed sweep it
was slower than the CPU on every single-period network, and faster on every multi-period horizon that
was run (T = 24, 168 and 720 hours on the demo campus).

**Network layout.** The campus generator was changed from a street grid to a trunk-and-branch layout,
and the demo campus went from 132 to 166 junctions. Every measurement in these notes is from the
current layout except the T = 8,760 attempt under "What was not run", which is marked "earlier layout".
The benchmark sweep was repeated on the current layout at commit `1b2130c` and replaces the sweep from
the earlier layout at commit `6fd4ac9`. A few sentences contrast a result with the earlier layout and
say so.

**The host was loaded during the sweep.** The machine is shared, and other users' jobs ran throughout.
The 1-minute load average recorded with each timed run ranged from 17 to 102, with a median of 55, on a
machine with 192 logical CPUs. The CPU solves use one thread, and the GPU solves also do work on the
host, so both can be slowed by other jobs; how much was not measured. One visible sign: at T = 24 the
CPU took 86 iterations in every repeat, yet its time ranged from 3.43 s to 5.88 s. Read every time below
as taken on a loaded host.

## How the runs were made

| Item | Value |
|---|---|
| Results | [`results/benchmarks.csv`](../results/benchmarks.csv), summarized in [`results/benchmarks_summary.json`](../results/benchmarks_summary.json) |
| Console log | [`results/logs/benchmarks_local_sweep.txt`](../results/logs/benchmarks_local_sweep.txt) |
| Commit and date | `1b2130c`, 2026-11-20 |
| Sweep runtime | 16,602 s (4.6 hours), including warm-up, Ipopt, GPU memory and time-to-first-solve runs |
| GPU | One NVIDIA H200, driver 580.178.04, CUDA runtime 13.4.0 |
| CPU | INTEL(R) XEON(R) PLATINUM 8568Y+, one Julia thread, one BLAS thread in MadNLP |
| Packages | Julia 1.13.3, MadNLP 0.11.0, MadNLPGPU 0.11.1, CUDA 6.5.1, CUDSS 1.0.0, ExaModels 0.15.0 |
| Solvers | CPU: MadNLP with MUMPS. GPU: MadNLP with cuDSS on the condensed KKT system. Reference: Ipopt with MUMPS on the same ExaModel |
| Repeats | 5 per case, solver and tolerance |
| Host load | 1-minute load average 17 to 102, median 55, on 192 logical CPUs (column `host_load_1min`) |
| Other GPU work | One other compute process was seen on the GPU during the five GPU runs at T = 720 with a tolerance of 1e-6. Those runs are in the results file but are not used in any comparison below. No other process was seen during any other timed run, including every run in the tables below |
| Compilation | Excluded by warm-up solves. The compile time recorded inside timed solves was 0 s in every run |

Times are medians, with the minimum and maximum over the repeats in brackets. A repeat counts as solved
only if MadNLP reports `SOLVE_SUCCEEDED`. The KKT residual is recomputed from the returned point on the
unscaled model with one function for all solvers, and the table shows the largest value over the repeats.

## Like-for-like comparison

Both devices were asked for a tolerance of 1e-8 with MadNLP's acceptable termination switched off, and
with the same bound relaxation of 1e-8. Medians use the repeats that solved. Residuals count as matched
when the GPU's KKT residual is at most twice the CPU's. The GPU counts as faster at a size only if its
median is lower, every repeat solved on both devices, and the residuals matched.

| Case | Variables | CPU time (s) | GPU time (s) | GPU / CPU | CPU repeats solved | GPU repeats solved | KKT residual, CPU | KKT residual, GPU | Residuals matched | GPU faster |
|---|---|---|---|---|---|---|---|---|---|---|
| Demo campus (166 junctions) | 1,112 | 0.150 (0.150 to 0.154) | 0.454 (0.392 to 2.50) | 3.01 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.5e-07 | yes | no |
| Scaled campus, 200 junctions | 1,348 | 0.241 (0.240 to 0.243) | 0.972 (0.417 to 1.89) | 4.04 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.5e-07 | yes | no |
| Scaled campus, 300 junctions | 2,052 | 0.429 (0.427 to 0.433) | 3.38 (2.46 to 5.25) | 7.88 | 5 of 5 | 5 of 5 | 9.1e-08 | 5.5e-07 | no | no |
| Scaled campus, 400 junctions | 2,744 | 0.394 (0.393 to 0.398) | 1.34 (0.836 to 18.7) | 3.40 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.5e-07 | yes | no |
| Scaled campus, 500 junctions | 3,442 | 0.593 (0.589 to 0.595) | 0.794 (0.631 to 1.15) | 1.34 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.7e-07 | yes | no |
| Scaled campus, 600 junctions | 4,134 | 0.938 (0.926 to 0.950) | 1.46 (0.570 to 2.18) | 1.55 | 5 of 5 | 5 of 5 | 2.5e-07 | 3.9e-07 | yes | no |
| Scaled campus, 800 junctions | 5,530 | 1.06 (1.06 to 1.08) | 1.48 (0.722 to 2.40) | 1.40 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.7e-07 | yes | no |
| Demo campus, T = 24 | 26,688 | 5.82 (3.43 to 5.88) | 1.13 (0.811 to 44.9) | 0.19 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.6e-07 | yes | yes |
| Demo campus, T = 168 | 186,816 | 52.8 (52.7 to 67.2) | 3.59 (2.47 to 70.2) | 0.07 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.6e-07 | yes | yes |
| Demo campus, T = 720 | 800,640 | 426.0 (399.4 to 486.3) | 9.47 (7.21 to 24.3) | 0.02 | 5 of 5 | 5 of 5 | 2.5e-07 | 2.7e-07 | yes | yes |

Every repeat of every case solved on both devices at 1e-8, so no repeat failed in this table.

**Crossover.** Under the rule used here, which requires the GPU to be faster at a size and at every
larger size of the same family, the GPU crossed over in the number of periods but not in network size.

- **Number of periods: the GPU was faster at T = 24, 168 and 720**, every horizon that was run. Its
  median was 0.19 times the CPU's at T = 24 (1.13 s against 5.82 s), 0.07 times at T = 168 (3.59 s
  against 52.8 s) and 0.02 times at T = 720 (9.47 s against 426.0 s). T = 24 is the shortest horizon in
  the sweep, so the crossover lies at or below 24 hours. The only shorter point is the single-period
  demo campus, where the GPU was slower; horizons between 1 and 24 hours were not run, so the crossover
  is not located more closely than that.
- **Network size: no crossover.** The GPU was slower at all seven single-period sizes, from 1.34 times
  the CPU time at 500 junctions to 7.88 times at 300 junctions. At 300 junctions the GPU's residual was
  also more than twice the CPU's.
- **T = 720 is the clearest case.** Every GPU repeat (7.21 s to 24.3 s) was faster than every CPU repeat
  (399.4 s to 486.3 s).
- **At T = 24 and T = 168 the medians hide two slow GPU repeats each.** The first two GPU repeats took
  15.8 s and 44.9 s at T = 24, and 33.9 s and 70.2 s at T = 168, against 0.81 s to 3.59 s for the other
  three. Most of that time was in the linear solver. At T = 24 both slow repeats were slower than every
  CPU repeat, and at T = 168 one was. The cause was not isolated; the host was loaded throughout, and
  these runs cannot separate load from solver behavior. The GPU median is lower at these horizons, but a
  single GPU solve there is not dependably faster.
- **The CPU took more iterations on the current layout at long horizons**, 151 at T = 168 and 216 at
  T = 720, against GPU medians of 87 and 89. At T = 720 the CPU also took longer per iteration
  (1.97 s) than on the earlier layout (1.16 s), with 10% more variables. These runs do not separate the
  effect of the layout from that of the host load.

The tolerance of 1e-6 is in the results file but is not used for a comparison. At that setting the
GPU's KKT residual was more than twice the CPU's at 200, 400 and 500 junctions and at T = 168 and 720,
up to 8.1 times at 200 junctions, so those runs are not like for like.

## Default settings

These runs use each solver's defaults at a requested tolerance of 1e-8, so acceptable termination is
on, and the GPU's bound relaxation follows its default. They are the known unequal comparison: on the
earlier layout the GPU often stopped at `SOLVED_TO_ACCEPTABLE_LEVEL` while the CPU reached 1e-8. In this
sweep every synchronous GPU repeat reached 1e-8. The achieved residual is shown beside each time.

| Case | CPU status | CPU time (s) | CPU KKT residual | GPU repeats at 1e-8 | GPU repeats at acceptable level | GPU time (s) | GPU KKT residual |
|---|---|---|---|---|---|---|---|
| Demo campus (166 junctions) | `SOLVE_SUCCEEDED` | 0.090 (0.089 to 0.107) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.29 (0.913 to 3.51) | 2.9e-07 |
| Scaled campus, 200 junctions | `SOLVE_SUCCEEDED` | 0.239 (0.237 to 0.243) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.62 (0.406 to 3.69) | 2.5e-07 |
| Scaled campus, 300 junctions | `SOLVE_SUCCEEDED` | 0.429 (0.424 to 0.432) | 9.1e-08 | 5 of 5 | 0 of 5 | 0.927 (0.801 to 2.09) | 2.6e-07 |
| Scaled campus, 400 junctions | `SOLVE_SUCCEEDED` | 0.392 (0.392 to 0.395) | 2.5e-07 | 5 of 5 | 0 of 5 | 0.869 (0.639 to 3.48) | 2.5e-07 |
| Scaled campus, 500 junctions | `SOLVE_SUCCEEDED` | 0.592 (0.589 to 0.596) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.70 (0.692 to 4.92) | 2.6e-07 |
| Scaled campus, 600 junctions | `SOLVE_SUCCEEDED` | 0.934 (0.928 to 0.938) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.08 (0.644 to 2.30) | 2.5e-07 |
| Scaled campus, 800 junctions | `SOLVE_SUCCEEDED` | 1.07 (0.627 to 1.08) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.54 (0.687 to 4.86) | 2.6e-07 |
| Demo campus, T = 24 | `SOLVE_SUCCEEDED` | 4.45 (3.40 to 5.87) | 2.5e-07 | 5 of 5 | 0 of 5 | 1.55 (0.857 to 3.52) | 2.6e-07 |
| Demo campus, T = 168 | `SOLVE_SUCCEEDED` | 58.0 (51.9 to 70.6) | 2.5e-07 | 5 of 5 | 0 of 5 | 3.14 (2.31 to 76.8) | 2.6e-07 |
| Demo campus, T = 720 | `SOLVE_SUCCEEDED` | 398.0 (358.2 to 399.7) | 2.5e-07 | 5 of 5 | 0 of 5 | 11.3 (7.87 to 105.8) | 2.7e-07 |

The GPU columns are synchronous cuDSS, as in the strict runs. With asynchronous cuDSS, the package
default, one repeat at T = 168 stopped at the acceptable level and every other repeat reached 1e-8; its
times are in the results file. With default settings the synchronous GPU's median was lower than the
CPU's at T = 24, 168 and 720 and higher at every single-period size, as in the strict runs. The
asynchronous GPU's median was also lower than the CPU's at 600 junctions (0.616 s against 0.934 s) and
800 junctions (0.916 s against 1.07 s), with every repeat at 1e-8 and residuals within twice the CPU's.
Those are default-settings runs, with acceptable termination on, so they are not part of the
like-for-like comparison, and asynchronous cuDSS was not run in the strict mode.

## Where the time goes

Strict runs at 1e-8, as medians over all five repeats; every repeat solved. "Other" is the rest of the
solve, including building the condensed KKT system, which MadNLP does not count as linear solver time.

| Case | Device | Total (s) | Linear solver (s) | Function evaluation (s) | Other (s) | Iterations |
|---|---|---|---|---|---|---|
| Demo campus (166 junctions) | CPU | 0.150 | 0.136 | 0.003 | 0.011 | 52 (52 to 52) |
| Demo campus (166 junctions) | GPU | 0.454 | 0.328 | 0.022 | 0.104 | 45 (40 to 46) |
| Scaled campus, 800 junctions | CPU | 1.06 | 0.948 | 0.024 | 0.090 | 101 (101 to 101) |
| Scaled campus, 800 junctions | GPU | 1.48 | 1.06 | 0.047 | 0.484 | 85 (82 to 93) |
| Demo campus, T = 24 | CPU | 5.82 | 5.34 | 0.099 | 0.385 | 86 (86 to 86) |
| Demo campus, T = 24 | GPU | 1.13 | 0.489 | 0.048 | 0.589 | 76 (68 to 136) |
| Demo campus, T = 168 | CPU | 52.8 | 47.3 | 1.64 | 3.85 | 151 (151 to 151) |
| Demo campus, T = 168 | GPU | 3.59 | 2.07 | 0.083 | 1.44 | 87 (70 to 147) |
| Demo campus, T = 720 | CPU | 426.0 | 387.5 | 9.91 | 28.6 | 216 (216 to 216) |
| Demo campus, T = 720 | GPU | 9.47 | 3.71 | 0.102 | 5.84 | 89 (88 to 307) |

On the CPU the linear solver took about 90% of the time in every case. On the GPU at T = 720 the
linear solver took 3.71 s of 9.47 s, and the rest of the solve, mostly outside the linear solver and
function evaluation, took 5.84 s. Function evaluation was a small share on both devices.

## Ipopt reference

Ipopt runs on the CPU with default settings and a tolerance of 1e-8. Every Ipopt repeat solved.

| Case | Ipopt time (s) | Ipopt iterations | MadNLP CPU time (s) | MadNLP CPU iterations |
|---|---|---|---|---|
| Demo campus (166 junctions) | 0.177 (0.176 to 0.179) | 52 | 0.090 (0.089 to 0.107) | 52 |
| Scaled campus, 200 junctions | 0.267 (0.266 to 0.326) | 67 | 0.239 (0.237 to 0.243) | 68 |
| Scaled campus, 300 junctions | 0.469 (0.467 to 0.471) | 83 | 0.429 (0.424 to 0.432) | 84 |
| Scaled campus, 400 junctions | 0.443 (0.441 to 0.447) | 68 | 0.392 (0.392 to 0.395) | 68 |
| Scaled campus, 500 junctions | 0.669 (0.666 to 0.676) | 86 | 0.592 (0.589 to 0.596) | 88 |
| Scaled campus, 600 junctions | 0.639 (0.621 to 0.656) | 105 | 0.934 (0.928 to 0.938) | 104 |
| Scaled campus, 800 junctions | 0.911 (0.854 to 1.30) | 103 | 1.07 (0.627 to 1.08) | 101 |
| Demo campus, T = 24 | 6.69 (6.67 to 6.72) | 86 | 4.45 (3.40 to 5.87) | 86 |
| Demo campus, T = 168 | 65.2 (62.4 to 82.5) | 151 | 58.0 (51.9 to 70.6) | 151 |
| Demo campus, T = 720 | 475.9 (449.6 to 550.9) | 216 | 398.0 (358.2 to 399.7) | 216 |

Ipopt and MadNLP on the CPU took the same or nearly the same number of iterations in every case. MadNLP
had the lower median in eight of ten cases; Ipopt had the lower median at 600 and 800 junctions. On a
loaded host, differences of this size between two CPU solvers should not be read as a ranking.

## Agreement with the CPU

The largest difference over all ten cases and all GPU repeats at 1e-8, every one of which solved:

| Quantity | Largest relative difference from the CPU |
|---|---|
| Objective | 1.1e-06 |
| Plant output | 2.8e-05 |
| Steam-side pressure | 6.7e-04 |
| Steam-side temperature | 2.5e-04 |
| Flow in steam pipes above 1% of plant flow | 8.1e-03 |

The quantities below are reported separately because
[`docs/validation-notes.md`](validation-notes.md) shows they are not unique at the optimum. Differences
of tens of percent are expected between correct solutions, so they do not measure solver accuracy.

| Quantity, not unique at the optimum | Largest relative difference from the CPU |
|---|---|
| Water-side pressure | 1.4e-01 |
| Return-side temperature | 1.1e-02 |
| Flow in pipes below 1% of plant flow | 1.1e-02 |

## GPU iteration counts vary between runs

The CPU took the same number of iterations in every repeat. The GPU did not. In the sweep, at 1e-8 and
on identical input, it took between 88 and 307 iterations at T = 720, 68 to 136 at T = 24, and 57 to
144 at 200 junctions. Every one of those repeats solved. The diagnostics below show the same pattern:
at T = 24 with gradient scaling off the GPU took 41 to 155 iterations, while the CPU took 46 every time.

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
are those listed for the sweep above. The host was shared with other users' jobs during these
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

Current layout. MadNLP's GPU default ties the bound relaxation to the requested tolerance. At loose
tolerances the GPU therefore solves a visibly different problem. In an exploration at commit `2ec4de5`,
at T = 24 and a tolerance of 1e-4 the GPU objective was 2836.22, against 3003.04 on the CPU
([log](../results/logs/relaxation_tied_to_tol.txt)). With the relaxation held at 1e-8 the GPU objective
was 3003.01 ([log](../results/logs/relaxation_pinned.txt)). The strict runs in these notes hold it at
1e-8 on both devices. The conclusion is the same as on the earlier layout.

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

## GPU memory

Peak memory of one solve in a fresh process, as reported by `nvidia-smi`, sampled every 200 ms. It includes
everything the process holds on the GPU. Every one of these solves reported `SOLVE_SUCCEEDED`.

| Case | Variables | Peak GPU memory (MiB) |
|---|---|---|
| Demo campus (166 junctions) | 1,112 | 788 |
| Scaled campus, 200 junctions | 1,348 | 820 |
| Scaled campus, 300 junctions | 2,052 | 916 |
| Scaled campus, 400 junctions | 2,744 | 918 |
| Scaled campus, 500 junctions | 3,442 | 982 |
| Scaled campus, 600 junctions | 4,134 | 1,076 |
| Scaled campus, 800 junctions | 5,530 | 1,174 |
| Demo campus, T = 24 | 26,688 | 2,852 |
| Demo campus, T = 168 | 186,816 | 11,926 |
| Demo campus, T = 720 | 800,640 | 36,824 |

The largest case, T = 720, used about 36 GiB of the H200's memory. These are single samples of one
solve each, so they should not be extrapolated to other sizes. The sampler also counted one other
process on the GPU during every memory run. The likely source is the parent sweep process, which holds
its own GPU context. The per-process reading above excludes it.

## Time to first solve

Demo campus, fresh process, median of three runs, with packages already precompiled. These runs were
also made on the loaded host.

| Device | Package load (s) | First build and solve (s) | Second build and solve (s) | Whole process (s) |
|---|---|---|---|---|
| CPU | 1.29 | 14.3 | 0.084 | 20.1 |
| GPU | 5.30 | 83.3 | 0.513 | 93.9 |

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

- **Horizons between 1 and 24 hours** were not run, so the point where the GPU starts to be faster in
  the number of periods is not located more closely than "at or below T = 24".
- **Calibration on the GPU at 25 tags and 3 months** has not been run in any recorded build.
- **T = 8,760 (earlier layout) did not finish and was not run on the current layout.** One attempt per
  device at commit `6fd4ac9`, with limits of 1800 s and 1000 iterations. The CPU stopped at the time limit
  after 101 iterations, and the GPU stopped at the iteration limit after 780 s
  ([log](../results/logs/benchmarks_year_attempt.txt)).
- **Single precision** was not tested, because the model builders use `Float64`.
- **A multi-threaded CPU** was not tested. The CPU times use one thread.
- **The augmented KKT system on the GPU** was not tested.
- **Asynchronous cuDSS in the strict runs** was not tested. The strict GPU runs use synchronous cuDSS so that
  MadNLP reports linear solver time. In the default-settings runs of this sweep the asynchronous mode,
  which is the package default, had a lower median than the synchronous mode in 3 of 10 cases (500, 600
  and 800 junctions) and the higher median in the other 7, so this sweep does not show the strict GPU
  times to be pessimistic or optimistic in general.

## Where the GPU may pay off later

Nothing in this section has produced a result, and no speedup is projected beyond the horizons that
were measured. Year-long horizons were attempted once, on the earlier layout, and did not finish. The other items have not been run. Each item states what would need to be
true for it to pay off.

| Opportunity | Status | What would need to be true |
|---|---|---|
| Year-long horizons | Did not finish | The one attempt at T = 8,760, on the earlier layout, did not finish on either device. The GPU must converge reliably at that size. At T = 720 on the current layout it solved every repeat, but its iteration count still ranged from 88 to 307 on identical input, and that solve already used about 36 GiB of GPU memory. The factorization at T = 8,760 must fit in GPU memory |
| Many-scenario contingency screening | Not run | Scenarios must share one sparsity pattern so that one symbolic analysis and batched factorization can be reused, and each scenario must converge without manual restarts |
| Calibration over full historian history | Not run | The GPU must solve the longer records that the CPU solves, and the problem must fit in GPU memory. The 3-month case has not been run on the GPU in any recorded build |
| Embedded learned load models | Not run | The learned model must be expressed in forms ExaModels can evaluate on the GPU, and function evaluation must become a large share of solve time. Today it is a small share |

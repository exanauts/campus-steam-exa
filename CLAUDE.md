# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

`CampusSteam` is a Julia package that optimizes a district steam network (one plant, steam out,
condensate back) with ExaModels.jl and MadNLP.jl, on CPU and GPU. The campus, Example University, is
fictional and every number is synthetic. A static site under `site/` shows the results and is published
at <https://exanauts.github.io/campus-steam-exa/>.

The model is steady-state physics for each hour. A run of hours is solved as one problem, linked only by
the plant ramp limit. There are no pipe transients and no valves. Read `README.md` first, then
`docs/model-notes.md` for the equations.

## Setup

- Julia 1.13 only.
- `julia --project=. -e 'using Pkg; Pkg.instantiate()'` installs the package environment.
- A GPU is optional. The CUDA packages are weak dependencies and load from the `scripts` environment.
  On a shared machine, pick a free GPU with `CUDA_VISIBLE_DEVICES` and check `nvidia-smi` first.

## Playing with the model

A single hour on the demo campus, on the CPU:

```julia
using CampusSteam, MadNLP
net = demo_campus()
heat = [0.6 * l.design_heat_W for l in net.loads]   # every building at 60% of its design heat
r = solve_oriented(net; heat_W = heat, print_level = MadNLP.ERROR)
s = r.solution
println(s.status, ": ", sum(s.load_delivered_W) / 1e6, " MW delivered, ",
        sum(s.load_shed_W) / 1e6, " MW shed, ", sum(s.pipe_heat_loss_W) / 1e6, " MW lost in pipes")
```

Things to change:

- **Demand:** pass any `heat_W` vector, one entry per building in `net.loads`.
- **Plant capacity:** `plant_rating_W = 82.5e6` takes one of four boilers out.
- **Pipe outage:** `out_of_service = [id]` with the id of a steam main from `net.pipes`.
- **Network size:** `scaled_campus(400)` builds a larger campus by the same rules.
- **A week of hours:** `generate_profiles(net)` gives hourly demand for a synthetic year, and
  `solve_multiperiod_oriented` solves a run of hours. `scripts/site/scenario_cases.jl` defines the four
  scenarios on the site and is the best starting point for a new one.
- **Network edits:** `add_building`, `add_pipe_pair`, `resize_pipe`, `scale_heat_loss` and `add_boiler`
  (in `src/expansion.jl`) return an edited, oriented copy of a network; `generate_profiles` then gives a
  new building its own hourly demand. `scripts/site/expansion_cases.jl` defines the new-building study
  on the site.
- **GPU:** pass `backend = CUDABackend()` after `using CUDA, MadNLPGPU`, from the `scripts` environment.

Always check `solution.converged` before reading results.

## Commands

| Task | Command |
|---|---|
| Tests | `julia --project=. -e 'using Pkg; Pkg.test()'` |
| Everything the site shows (about 15 minutes with a GPU and many cores) | `julia --project scripts/run_all.jl` |
| One part of the site data | `julia --project=scripts scripts/run_site.jl scenarios` (or `calibration`, `benchmarks`, then `merge`) |
| Validation against JuMP and Ipopt | `julia --project=validation validation/run_validation.jl` |
| Local benchmark sweep (long) | `julia --project=scripts scripts/site/benchmarks.jl local` |
| Preview the site | run `scripts/run_all.jl`, then `python3 -m http.server -d site` |

## Layout

- `src/network.jl`, `src/generator/`: network types and the synthetic campus and load generator.
- `src/model/`: the optimization model, pipe orientation, and the multi-period model.
- `src/expansion.jl`: network edits for capacity-planning studies. Kept apart from the generator and the
  core model, which the validation hash covers.
- `src/historian.jl`, `src/calibration.jl`: historian-style CSV ingest and pipe coefficient fitting.
- `ext/CampusSteamGPUExt.jl`: GPU support.
- `scripts/site/`: scenarios, the new-building study, calibration and benchmarks that write
  `site/data/`, `merge.jl`, which
  combines them, and `pool.jl`, the worker pool for independent solves. `scripts/run_site.jl` runs one
  part or the merge.
- `site/`: the static page. `site/data/` is generated and not committed.
- `validation/`: an independent JuMP and Ipopt model in its own environment.
- `docs/`: model notes, validation notes, GPU notes, and the data schemas (`network-schema.md`,
  `site-data.md`).
- `results/`: committed validation and benchmark results.

## Rules that are easy to break

- **Validation hash.** `validation/source_hash.jl` hashes the generator, the core model and the
  validation code. After editing any of them, `Pkg.test()` fails until `validation/run_validation.jl`
  has been run again and its results committed.
- **Site numbers come from the build.** Every number and plot on the site is read from files that CI
  generates for the deployed commit. Do not hard-code results in `site/`, and do not copy local results
  into `site/data/`. Anything not run is omitted or marked "Not run", never estimated.
- **Non-unique quantities.** Water-side pressures, return-side temperatures, flows in lightly loaded
  pipes, and the split of shed load between buildings of one type are not unique at the optimum. Do not
  present them as predictions. Report shed load by building type.
- **Site build environment.** `scripts/Manifest.toml` is committed. If the package gains a dependency,
  update that manifest too, or the site build fails.
- **Keep the model label honest:** steady state per hour with ramp coupling, no transients, no valves.

## Public repository rules

- Everything is synthetic. Do not use or imitate a real campus map, building names or utility drawings.
- Do not name a real university, person, email address, vendor or internal system in files, commit
  messages or issues. "Historian-style CSV" is the only description of the data source.
- No logos, and no claim of endorsement or partnership.
- Never commit real plant data. Keep any real export outside the repository.
- Cite the reference paper (arXiv 2404.18868) and ThermalModels.jl, and do not copy upstream code.

## CI

- `test.yml` runs the tests on GitHub-hosted runners.
- `site.yml` builds the site data in three parallel jobs (scenarios, calibration, benchmarks) on
  self-hosted GPU runners of one machine, merges their artifacts in a `merge` job, and publishes to the
  `gh-pages` branch, which GitHub Pages serves. Scenarios and calibration run their independent solves
  on a pool of worker processes (`SITE_WORKERS`, default a quarter of the CPU threads, 1 runs serially);
  the benchmarks stay serial. The longest job took about 6 minutes locally. See `docs/site-data.md` under
  "Build".
  - `scripts/ci/select_gpu.sh` gives the benchmark job a GPU that no other build job holds; the other two
    share one. GPUs 0 and 1 are never used (`GPU_EXCLUDE`). `scripts/ci/cpu_set.sh` pins each job to
    its own CPU cores.
  - Pooled output must not depend on the worker count: workers return results, and the files are written
    afterwards by the part's own process.
  - Each part has a time budget that a normal build stays well inside. Anything that does not fit is
    reported as not run, never as not converged. If a part grows, raise its budget or move work between
    parts rather than letting points be skipped.
  - A commit on `main` replaces the public site.
  - A pull request from a branch of this repository gets a full preview at
    `https://exanauts.github.io/campus-steam-exa/preview/pr-<number>/`, linked in a comment on the
    request. The preview is removed when the request is merged or closed.
  - Pull requests from forks are not built, so outside code never runs on the GPU runner. Keep that
    condition, and keep the build and merge jobs at read-only `permissions`.
  - A newer commit on a branch cancels the build of the older one.

## Branches and pull requests

- Do not commit to `main` directly. Create a branch for any change or experiment, however small.
- Open a pull request to bring a branch into `main`. The tests run on it, and the site is rebuilt for it
  and published as a preview, so look at the preview link before merging.
- Experiments that are not meant for the site can stay on a branch without a pull request. Nothing is
  built or published for a branch until a pull request is opened.
- Before merging, run `Pkg.test()` and, for changes to the model, generator, scripts or `site/`, run
  `julia --project scripts/run_all.jl` and look at the page locally.

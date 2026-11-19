# Regenerates everything the site shows, with the same steps as .github/workflows/site.yml:
#
#   julia --project scripts/run_all.jl
#
# The steps run in their own processes in the scripts environment, whichever project started this
# file. CI runs the three parts as parallel jobs on separate GPUs; here they run one after another on
# one GPU, so that the benchmark timings are not disturbed by the other parts. The scenario and
# calibration parts run their solves on a pool of worker processes; set SITE_WORKERS to choose its size
# (1 runs them serially, the default is a quarter of the CPU threads, at most 8). Results are written to
# site/data/. Set CUDA_VISIBLE_DEVICES to choose the GPU.

const SCRIPTS_DIR = @__DIR__
const REPO_ROOT = dirname(SCRIPTS_DIR)
const JULIA = `$(Base.julia_cmd()) --project=$SCRIPTS_DIR`
const RUN_SITE = joinpath(SCRIPTS_DIR, "run_site.jl")

run(`$JULIA -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'`)
# Results of an earlier run are removed, so that the merged files come from this run only.
rm(joinpath(REPO_ROOT, "site", "data"); recursive = true, force = true)
for part in ("scenarios", "calibration", "benchmarks", "merge")
    run(`$JULIA $RUN_SITE $part`)
end
run(Cmd(`bash $(joinpath(SCRIPTS_DIR, "ci", "finish_site_data.sh"))`; dir = REPO_ROOT))

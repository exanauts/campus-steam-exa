# Regenerates everything the site shows, with the same steps as .github/workflows/site.yml:
#
#   julia --project scripts/run_all.jl
#
# The steps run in their own processes in the scripts environment, whichever project started this
# file. Results are written to site/data/. Set CUDA_VISIBLE_DEVICES to choose the GPU.

const SCRIPTS_DIR = @__DIR__
const REPO_ROOT = dirname(SCRIPTS_DIR)
const JULIA = `$(Base.julia_cmd()) --project=$SCRIPTS_DIR`

run(`$JULIA -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'`)
run(`$JULIA $(joinpath(SCRIPTS_DIR, "run_site.jl"))`)
run(Cmd(`bash $(joinpath(SCRIPTS_DIR, "ci", "finish_site_data.sh"))`; dir = REPO_ROOT))

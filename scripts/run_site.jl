# Builds one part of the site data, or merges the parts. The site workflow runs the three parts as
# parallel jobs and then merges them; scripts/run_all.jl runs the same commands one after another.
#
#   julia --project=scripts scripts/run_site.jl scenarios     site/data/scenarios/
#   julia --project=scripts scripts/run_site.jl calibration   site/data/calibration.json, tag_template.csv
#   julia --project=scripts scripts/run_site.jl benchmarks    site/data/benchmarks.json, benchmarks.csv
#   julia --project=scripts scripts/run_site.jl merge         site/data/build_info.json
#
# Each part also writes site/data/parts/<part>.json with how and where it ran. Only generic hardware
# model names are written. `merge` combines those records into build_info.json, removes parts/, and
# copies the calibration outcome into benchmarks.json. scripts/ci/finish_site_data.sh then writes
# files.json.

using Dates
using JSON
using Pkg

const REPO_ROOT = dirname(@__DIR__)
const DATA_DIR = joinpath(REPO_ROOT, "site", "data")
const PARTS_DIR = joinpath(DATA_DIR, "parts")
const PARTS = ("scenarios", "calibration", "benchmarks")

const USAGE = "usage: run_site.jl scenarios|calibration|benchmarks|merge"
length(ARGS) == 1 && (ARGS[1] in PARTS || ARGS[1] == "merge") || error(USAGE)
const PART = ARGS[1]

utc_now() = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"

function command_output(cmd::Cmd)
    try
        return strip(read(pipeline(cmd; stderr = devnull), String))
    catch
        return nothing
    end
end

csv_rows(text) = [strip.(split(line, ',')) for line in split(text, '\n') if !isempty(strip(line))]

"""
State of the selected GPU, read before this process touches the device. GPU
UUIDs and process IDs are used for matching only and are never returned.
"""
function selected_gpu_snapshot()
    snapshot = Dict{String,Any}(
        "gpu_model" => nothing,
        "driver_version" => nothing,
        "selected_gpu_index" => nothing,
        "selected_gpu_memory_used_mib_at_start" => nothing,
        "other_compute_processes_at_start" => nothing,
        "other_processes_on_gpu_at_start" => nothing,
    )
    gpus = command_output(
        `nvidia-smi --query-gpu=index,uuid,name,driver_version,memory.used --format=csv,noheader,nounits`,
    )
    gpus === nothing && return snapshot
    rows = csv_rows(gpus)
    isempty(rows) && return snapshot

    selected = tryparse(Int, get(ENV, "CUDA_VISIBLE_DEVICES", ""))
    row = something(findfirst(r -> tryparse(Int, r[1]) == selected, rows), 1)
    index, uuid, name, driver, memory_used = rows[row]
    snapshot["gpu_model"] = String(name)
    snapshot["driver_version"] = String(driver)
    snapshot["selected_gpu_index"] = parse(Int, index)
    memory = tryparse(Int, memory_used)
    snapshot["selected_gpu_memory_used_mib_at_start"] = memory

    apps = command_output(`nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader`)
    if apps !== nothing
        count = sum((r[1] == uuid for r in csv_rows(apps)); init = 0)
        snapshot["other_compute_processes_at_start"] = count
        snapshot["other_processes_on_gpu_at_start"] = count > 0
    end
    return snapshot
end

function cpu_model()
    isfile("/proc/cpuinfo") || return nothing
    for line in eachline("/proc/cpuinfo")
        startswith(line, "model name") && return String(strip(split(line, ':'; limit = 2)[2]))
    end
    return nothing
end

function commit_sha()
    sha = get(ENV, "GITHUB_SHA", "")
    isempty(sha) || return sha
    return command_output(`git -C $REPO_ROOT rev-parse HEAD`)
end

function package_versions(names)
    found = Dict(info.name => string(info.version) for info in values(Pkg.dependencies())
                 if info.name in names && info.version !== nothing)
    return Dict(name => get(found, name, nothing) for name in names)
end

"Refuse to publish anything that identifies the machine or account."
function assert_public_safe(text)
    home = homedir()
    forbidden = filter(s -> length(s) >= 3, unique([
        gethostname(),
        first(split(gethostname(), '.')),
        get(ENV, "USER", ""),
        get(ENV, "LOGNAME", ""),
        home == "/" ? "" : home,
        REPO_ROOT,
    ]))
    for value in forbidden
        occursin(value, text) && error("build_info.json would expose a machine-specific value")
    end
    return nothing
end

function write_build_info(info)
    text = JSON.json(info, 2)
    assert_public_safe(text)
    write(joinpath(DATA_DIR, "build_info.json"), text)
    rm(PARTS_DIR; recursive = true, force = true)
    println(text)
end

# Each step below is its own top-level statement, so that functions from an included file can be
# called by the next one.
PART == "merge" && include(joinpath(@__DIR__, "site", "merge.jl"))
PART == "merge" && (write_build_info(merge_site_data(DATA_DIR, PARTS_DIR, PARTS)); exit(0))

# Taken before CUDA is loaded so that this process cannot affect the reading.
const GPU_SNAPSHOT = selected_gpu_snapshot()
const STARTED = time()
const STARTED_AT = utc_now()

using CampusSteam
using CUDA
using CUDSS
using ExaModels
using MadNLP
using MadNLPGPU

function part_info(wall_s)
    functional = CUDA.functional()
    info = Dict{String,Any}(
        "part" => PART,
        "commit_sha" => commit_sha(),
        "run_date" => STARTED_AT,
        "wall_s" => round(wall_s; digits = 1),
        "cpu_model" => cpu_model(),
        "julia_version" => string(VERSION),
        "package_versions" => package_versions(["CUDA", "CUDSS", "ExaModels", "MadNLP", "MadNLPGPU"]),
        "cuda_functional" => functional,
        "cuda_device" => functional ? CUDA.name(CUDA.device()) : nothing,
        "cuda_runtime_version" => functional ? string(CUDA.runtime_version()) : nothing,
        "gpu_extension_loaded" => CampusSteam.gpu_extension_loaded(),
    )
    return merge(info, GPU_SNAPSHOT)
end

if haskey(ENV, "GITHUB_ACTIONS") && !CUDA.functional()
    error("CUDA is not functional on the GPU runner")
end

include(joinpath(@__DIR__, "site", "$PART.jl"))
PART == "scenarios" ? run_scenarios(joinpath(DATA_DIR, "scenarios")) :
    PART == "calibration" ? run_calibration(DATA_DIR) : run_benchmarks(DATA_DIR)

let text = JSON.json(part_info(time() - STARTED), 2)
    assert_public_safe(text)
    mkpath(PARTS_DIR)
    write(joinpath(PARTS_DIR, "$PART.json"), text)
    println(text)
end

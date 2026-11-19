# Combines the parts of a site build. Called by `scripts/run_site.jl merge` after the scenario,
# calibration and benchmark parts have written their files to site/data/, in one process or as
# separate CI jobs. Needs only JSON, so it does not load CUDA. See docs/site-data.md.

using JSON

# The benchmark part leaves this entry in `not_run`; the merge removes it when it adds the outcome.
const CALIBRATION_NOT_MERGED = "Calibration CPU and GPU outcome"

"""
The CPU and GPU outcomes that `run_calibration` wrote to `calibration.json` in `datadir`, at 25 tags.
Calibration is not solved again by the benchmarks, so it adds no runtime to them.
"""
function calibration_outcome(datadir)
    path = joinpath(datadir, "calibration.json")
    isfile(path) || return nothing
    data = JSON.parsefile(path)
    keys_kept = ("tags", "months", "hours", "run", "solver_status", "converged", "iterations",
                 "variables", "constraints", "jacobian_nonzeros", "solve_s", "reason")
    keep(cell) = Dict{String, Any}(k => cell[k] for k in keys_kept if haskey(cell, k))
    gpu = data["gpu"]
    return Dict{String, Any}(
        "source" => "calibration.json",
        "network_junctions" => data["network"]["junctions"],
        "cpu" => [keep(c) for c in data["grid"]["cells"] if c["tags"] == 25 && get(c, "run", false)],
        "gpu" => merge(keep(gpu), Dict{String, Any}("attempted" => get(gpu, "attempted", false))),
        "note" => "Read from the calibration part of this build. The site build attempts the GPU at one grid point.",
    )
end

"Copy the calibration outcome into benchmarks.json, when both files exist."
function merge_calibration_into_benchmarks(datadir)
    path = joinpath(datadir, "benchmarks.json")
    isfile(path) || return nothing
    document = JSON.parsefile(path)
    outcome = calibration_outcome(datadir)
    outcome === nothing && return nothing
    document["calibration"] = outcome
    document["not_run"] = [e for e in document["not_run"] if get(e, "item", nothing) != CALIBRATION_NOT_MERGED]
    write(path, JSON.json(document, 2))
    return nothing
end

"""
    merge_site_data(datadir, partsdir, parts) -> Dict

Merge the records in `partsdir/<part>.json` into the contents of build_info.json. The top-level
keys keep their meaning from the single-job build: the environment and the GPU snapshot are those of
the benchmark part, whose timings depend on them, or of the first part present. `run_date` is the
earliest start of a part. `parts` holds each part's own record, including its GPU and wall time.
"""
function merge_site_data(datadir, partsdir, parts)
    records = Dict{String, Any}()
    for part in parts
        path = joinpath(partsdir, "$part.json")
        isfile(path) && (records[part] = JSON.parsefile(path))
    end
    missing_parts = [p for p in parts if !haskey(records, p)]
    isempty(missing_parts) || @warn "Site parts missing from this build" missing_parts
    isempty(records) && error("no site parts found in $(basename(partsdir))/")
    commits = unique(r["commit_sha"] for r in values(records))
    length(commits) == 1 || error("the site parts were built from different commits")

    main_part = haskey(records, "benchmarks") ? "benchmarks" : first(p for p in parts if haskey(records, p))
    info = Dict{String, Any}(k => v for (k, v) in records[main_part] if !(k in ("part", "wall_s")))
    info["run_date"] = minimum(r["run_date"] for r in values(records))
    info["environment_from_part"] = main_part
    info["parts"] = Dict{String, Any}(
        p => Dict{String, Any}(k => records[p][k] for k in (
            "run_date", "wall_s", "selected_gpu_index", "selected_gpu_memory_used_mib_at_start",
            "other_compute_processes_at_start", "other_processes_on_gpu_at_start", "cuda_device",
        ) if haskey(records[p], k))
        for p in keys(records)
    )
    info["parts_missing"] = missing_parts
    merge_calibration_into_benchmarks(datadir)
    return info
end

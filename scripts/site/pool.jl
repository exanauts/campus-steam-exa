# A small pool of worker processes for independent solves, used by the scenario and calibration parts
# of the site build. Each idle worker takes the next item from a queue, and results are collected in
# the order of the items, so the output does not depend on which worker finished first. With one worker
# the items run in this process, one after another.
#
# The worker count comes from the environment variable SITE_WORKERS, and defaults to a quarter of the
# CPU threads, between 1 and 8. Workers load the packages from the precompile cache of the scripts
# environment, which run_all.jl and the site workflow fill before any part starts.

using Distributed

"Number of workers for a pool of `items` independent items."
function site_workers(items::Integer)
    requested = get(ENV, "SITE_WORKERS", "")
    n = isempty(requested) ? clamp(Sys.CPU_THREADS ÷ 4, 1, 8) : parse(Int, requested)
    n >= 1 || throw(ArgumentError("SITE_WORKERS must be at least 1"))
    return min(n, items)
end

"""
    start_pool(n, files) -> Vector{Int}

Start `n` worker processes in the active project and include `files` on each. Returns no workers when
`n` is 1, so that the items run in this process. The workers inherit the CPU affinity of this
process.
"""
function start_pool(n::Integer, files)
    n <= 1 && return Int[]
    flags = `--project=$(Base.active_project()) --startup-file=no --color=no`
    pids = addprocs(n; exeflags = flags)
    for file in files
        Distributed.remotecall_eval(Main, pids, :(include($file)))
    end
    return pids
end

stop_pool(pids) = isempty(pids) || rmprocs(pids)

"""
    pool_map(f, items, pids; before = item -> nothing, after = (item, result) -> nothing) -> Vector

Apply `f` to each item, on the workers `pids` or, with no workers, in this process. `f` must be
defined on the workers. `before(item)` runs in this process when the item is about to start; if it
returns something other than `nothing`, that is the item's result and `f` is not called. `after` runs in
this process when an item finishes, for logging. Results are returned in the order of `items`.
"""
function pool_map(f, items, pids; before = item -> nothing, after = (item, result) -> nothing)
    results = Vector{Any}(undef, length(items))
    function one(i, run)
        result = before(items[i])
        result === nothing && (result = run(items[i]))
        results[i] = result
        after(items[i], result)
        return nothing
    end
    if isempty(pids)
        for i in eachindex(items)
            one(i, f)
        end
        return results
    end
    next = Channel{Int}(length(items))
    foreach(i -> put!(next, i), eachindex(items))
    close(next)
    @sync for pid in pids
        @async for i in next
            one(i, item -> remotecall_fetch(f, pid, item))
        end
    end
    return results
end

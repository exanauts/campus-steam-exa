# Per-solve pipe orientation. The NLP needs a fixed flow direction in every pipe, so a looped main
# whose flow reverses at part load or during an outage is re-oriented before the solve.

"""
    orient_for_demand(net::CampusNetwork; heat_W = nothing, out_of_service = Int[]) -> CampusNetwork

Orient `net` along the flow at the given heat demand instead of the design demand, using
`orient_network`. Pipes in `out_of_service` are removed and the rest renumbered. A pump on a pipe
that ends up reversed provides no boost. The returned network keeps the design heat of `net`.
"""
function orient_for_demand(net::CampusNetwork; heat_W = nothing, out_of_service = Int[])
    heat = heat_W === nothing ? [l.design_heat_W for l in net.loads] : collect(heat_W)
    length(heat) == length(net.loads) || throw(ArgumentError("heat_W must have one entry per load"))
    # A small floor keeps every load in the hydraulic solve when its demand is zero.
    loads = [
        Load(l.id, l.name, l.type, l.steam_junction, l.water_junction,
            max(Float64(heat[l.id]), 1.0e-3 * l.design_heat_W), l.priority_weight)
        for l in net.loads
    ]
    source = CampusNetwork(net.junctions, net.pipes, loads, net.plant)
    oriented = orient_network(source; out_of_service)
    return CampusNetwork(oriented.junctions, oriented.pipes, net.loads, net.plant)
end

"""
    OrientedSolve

Result of [`solve_oriented`](@ref).

- `net`, `model`, `solution`: the oriented network, its model and its [`SteamSolution`](@ref).
- `source_pipe`: for each pipe of `net`, its id in the input network.
- `direction`: `+1` where the pipe runs in its input direction, `-1` where it is reversed.
- `reversed_pipes`: input ids of the pipes that run against their input direction.
- `source_flow_kg_per_s`: flow per input pipe, signed by the input direction, and zero for pipes
  that are out of service.
- `pinned_pipes`: pipes of `net` that finished at their minimum flow.
- `rounds`: number of NLP solves performed across both starting orientations.
"""
struct OrientedSolve{M <: SteamModel}
    net::CampusNetwork
    model::M
    solution::SteamSolution
    source_pipe::Vector{Int}
    direction::Vector{Int}
    reversed_pipes::Vector{Int}
    source_flow_kg_per_s::Vector{Float64}
    pinned_pipes::Vector{Int}
    rounds::Int
end

_flipped(p::Pipe) = Pipe(p.id, p.side, p.to, p.from, p.length_m, p.diameter_m, p.friction_factor,
    p.heat_loss_W_per_m2K, 0.0, p.is_loop)

# Matches each oriented pipe to its input pipe by side, end points and geometry.
function _match_source_pipes(source::CampusNetwork, oriented::CampusNetwork)
    key(p) = (p.side, minmax(p.from, p.to), p.length_m, p.diameter_m)
    available = Dict{Any, Vector{Int}}()
    for p in source.pipes
        push!(get!(available, key(p), Int[]), p.id)
    end
    matched = [popfirst!(available[key(p)]) for p in oriented.pipes]
    direction = [
        source.pipes[matched[k]].from == p.from ? 1 : -1 for (k, p) in enumerate(oriented.pipes)
    ]
    return matched, direction
end

function _pinned_pipes(model::SteamModel, sol::SteamSolution)
    lower = model.data.bounds.flow[1][1:model.data.npipe] .* model.data.options.flow_ref_kg_per_s
    return findall(sol.pipe_flow_kg_per_s .<= 1.01 .* lower)
end

"""
    solve_oriented(net::CampusNetwork; heat_W = nothing, out_of_service = Int[],
                   plant_rating_W = nothing, options = SteamModelOptions(), backend = nothing,
                   max_rounds = 4, solver options...) -> OrientedSolve

Solve one steady state with pipe directions chosen for this demand and outage set. The search
starts from two orientations, [`orient_for_demand`](@ref) and the design-load `orient_network`. A
loop pipe that finishes pinned at its minimum flow is pushing against the direction the physics
wants, so it is flipped and the model solved again. A round is kept only when it converges with a
lower objective, and each start stops after `max_rounds` solves. The converged result with the
lowest objective is returned. This is a heuristic: the direction pattern is not proven optimal.
"""
function solve_oriented(
        net::CampusNetwork;
        heat_W = nothing,
        out_of_service = Int[],
        plant_rating_W = nothing,
        options::SteamModelOptions = SteamModelOptions(),
        backend = nothing,
        max_rounds::Int = 4,
        kwargs...,
    )
    build(candidate) = build_steam_model(candidate; heat_W, plant_rating_W, options, backend)
    better(a, b) = a.converged && (!b.converged || a.objective_W < b.objective_W)

    function search(start)
        current_net, current_model = start, build(start)
        current = solve_steam(current_model; kwargs...)
        count = 1
        while count < max_rounds
            pinned = [e for e in _pinned_pipes(current_model, current) if current_net.pipes[e].is_loop]
            isempty(pinned) && break
            pipes = copy(current_net.pipes)
            pipes[pinned] .= _flipped.(pipes[pinned])
            candidate = CampusNetwork(current_net.junctions, pipes, current_net.loads, current_net.plant)
            model = try
                build(candidate)
            catch err
                # A flip can strand a junction; the previous orientation then stands.
                err isa ArgumentError || rethrow()
                break
            end
            sol = solve_steam(model; kwargs...)
            count += 1
            better(sol, current) || break
            current_net, current_model, current = candidate, model, sol
        end
        return current_net, current_model, current, count
    end

    best_net, best_model, best, rounds = search(orient_for_demand(net; heat_W, out_of_service))
    design = orient_network(net; out_of_service)
    if design.pipes != best_net.pipes
        other_net, other_model, other, other_rounds = search(design)
        rounds += other_rounds
        if better(other, best)
            best_net, best_model, best = other_net, other_model, other
        end
    end

    source_pipe, direction = _match_source_pipes(net, best_net)
    source_flow = zeros(length(net.pipes))
    source_flow[source_pipe] .= direction .* best.pipe_flow_kg_per_s
    return OrientedSolve(
        best_net, best_model, best, source_pipe, direction, source_pipe[direction .< 0],
        source_flow, _pinned_pipes(best_model, best), rounds,
    )
end

# Case definitions and solver-independent checks shared by scripts/site/benchmarks.jl and
# validation/ipopt_benchmark.jl. All network and demand data is synthetic.

using CampusSteam: CampusSteam, MultiPeriodModel, demo_campus, scaled_campus, generate_profiles,
    build_steam_model, build_multiperiod_model
using ExaModels: ExaModels
using LinearAlgebra: norm

const BenchNLP = ExaModels.NLPModels

# A pipe counts as lightly loaded below this share of the plant flow of its period.
const LIGHT_FLOW_SHARE = 0.01

"""
    bench_case(id; backend = nothing) -> SteamModel or MultiPeriodModel

Build the model of a benchmark case. `demo` is the demo campus at design heat, `scaled-N` is
`scaled_campus(N)` at design heat, and `horizon-T` is the demo campus over the first `T` hours of
the synthetic demand year with the default ramp limit.
"""
function bench_case(id::AbstractString; backend = nothing)
    id == "demo" && return build_steam_model(demo_campus(); backend)
    if startswith(id, "scaled-")
        return build_steam_model(scaled_campus(parse(Int, id[8:end])); backend)
    elseif startswith(id, "horizon-")
        net = demo_campus()
        heat_W = generate_profiles(net; hours = parse(Int, id[9:end])).heat_W
        return build_multiperiod_model(net; heat_W, backend)
    end
    throw(ArgumentError("unknown benchmark case $id"))
end

"Number of junctions and periods of a benchmark case."
function bench_case_size(id::AbstractString)
    id == "demo" && return (junctions = length(demo_campus().junctions), periods = 1)
    startswith(id, "scaled-") && return (junctions = parse(Int, id[8:end]), periods = 1)
    startswith(id, "horizon-") &&
        return (junctions = length(demo_campus().junctions), periods = parse(Int, id[9:end]))
    throw(ArgumentError("unknown benchmark case $id"))
end

_worst(v) = maximum(v; init = 0.0)

"""
    kkt_residuals(nlp, x, y, zl, zu) -> NamedTuple

First-order residuals of a returned point, recomputed on the host from the model's own callbacks in
the model's scaled units, without any solver scaling or bound relaxation. `primal` is the largest
violation of a constraint or bound, `dual` the infinity norm of `grad f + J'y - zl + zu`, and
`complementarity` the largest product of a multiplier and its distance to the bound. A point beyond
its bound, which the solvers' bound relaxation allows, counts as primal violation and has distance
zero here; otherwise a large multiplier times the 1e-8 relaxation would hide every other term. `kkt` is the largest of the
three. Every solver is measured with this one function, so the values can be compared directly.
`nlp` must be a CPU model.
"""
function kkt_residuals(nlp, x, y, zl, zu)
    meta = nlp.meta
    lvar, uvar, lcon, ucon = meta.lvar, meta.uvar, meta.lcon, meta.ucon
    c = BenchNLP.cons(nlp, x)
    primal = max(
        _worst(max.(lcon .- c, c .- ucon, 0.0)),
        _worst(max.(lvar .- x, x .- uvar, 0.0)),
    )
    dual = norm(BenchNLP.grad(nlp, x) .+ BenchNLP.jtprod(nlp, x, y) .- zl .+ zu, Inf)
    bound_gap = max(
        _worst(abs(zl[i]) * max(x[i] - lvar[i], 0.0) for i in eachindex(x) if isfinite(lvar[i])),
        _worst(abs(zu[i]) * max(uvar[i] - x[i], 0.0) for i in eachindex(x) if isfinite(uvar[i])),
    )
    row_gap = _worst(
        abs(y[i]) * min(max(c[i] - lcon[i], 0.0), max(ucon[i] - c[i], 0.0))
        for i in eachindex(c) if lcon[i] < ucon[i]
    )
    complementarity = max(bound_gap, row_gap)
    return (; primal, dual, complementarity, kkt = max(primal, dual, complementarity))
end

_block(v, x) = x[(v.offset + 1):(v.offset + v.length)]

"""
    bench_quantities(model, x) -> NamedTuple

Physical quantities of a solution vector in SI units, repeated over the periods of the model, with
the masks that separate the steam side from the water side.
"""
function bench_quantities(model, x)
    multi = model isa MultiPeriodModel
    d = multi ? model.data.templates[1].data : model.data
    T = multi ? model.data.nperiod : 1
    opt = d.options
    edge_period = repeat(1:T; inner = d.nedge)
    plant_edges = d.nedge .* (1:T)
    flow = _block(model.vars.flow, x) .* opt.flow_ref_kg_per_s
    return (
        pressure = _block(model.vars.pressure, x) .* opt.pressure_ref_Pa,
        temperature = _block(model.vars.temperature, x) .* opt.temperature_ref_K,
        flow,
        plant_output = _block(model.vars.plant_power, x) .* opt.power_ref_W,
        plant_flow = flow[plant_edges],
        edge_period,
        junction_is_steam = repeat(d.junction_is_steam, T),
        pipe_is_steam = repeat(vcat(d.pipe_is_steam, falses(d.nedge - d.npipe)), T),
        is_pipe = repeat(vcat(trues(d.npipe), falses(d.nedge - d.npipe)), T),
    )
end

# Same relative difference as docs/validation-notes.md: per element, then the maximum.
function _max_rel(a, b, mask = trues(length(a)))
    return _worst(
        abs(a[i] - b[i]) / max(abs(a[i]), abs(b[i]), eps()) for i in eachindex(a) if mask[i]
    )
end

"""
    solution_agreement(model, x, reference_x) -> NamedTuple

Compare a solution with the reference solution of the same case. The `*_rel` fields in the first
group are the agreement measures: objective, plant output, steam-side pressure and temperature, and
flow in steam pipes that carry at least `LIGHT_FLOW_SHARE` of the plant flow in the reference.

The `nonunique_*` fields are water-side pressure, return-side temperature, and flow in lightly
loaded pipes on either side. docs/validation-notes.md shows that these are not unique at the
optimum, so differences of tens of percent between correct solutions are expected there. They are
reported for completeness and are not a measure of solver accuracy.
"""
function solution_agreement(model, x, reference_x)
    a, r = bench_quantities(model, x), bench_quantities(model, reference_x)
    fa, fr = BenchNLP.obj(model.nlp, x), BenchNLP.obj(model.nlp, reference_x)
    light = r.flow .< LIGHT_FLOW_SHARE .* r.plant_flow[r.edge_period]
    return (
        objective_rel = abs(fa - fr) / max(abs(fa), abs(fr)),
        plant_output_rel = _max_rel(a.plant_output, r.plant_output),
        steam_pressure_rel = _max_rel(a.pressure, r.pressure, r.junction_is_steam),
        steam_temperature_rel = _max_rel(a.temperature, r.temperature, r.junction_is_steam),
        steam_flow_rel = _max_rel(a.flow, r.flow, r.pipe_is_steam .& .!light),
        nonunique_water_pressure_rel = _max_rel(a.pressure, r.pressure, .!r.junction_is_steam),
        nonunique_return_temperature_rel = _max_rel(a.temperature, r.temperature, .!r.junction_is_steam),
        nonunique_light_flow_rel = _max_rel(a.flow, r.flow, r.is_pipe .& light),
    )
end

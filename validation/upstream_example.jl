# The small synthetic example network published with ThermalModels.jl, read at run time from a
# pinned upstream commit. The upstream files are never stored in this repository.
#
# Source: https://github.com/lanl-ansi/ThermalModels.jl, directory `example_network/`.
# Formulation: Hari, Srinivasan, Zlotnik, Sundar and Ewers, arXiv:2404.18868.

using Downloads: Downloads
using SHA: sha256

const UPSTREAM_COMMIT = "56ea809a570d3916d625c8433444ed55d4181052"
const UPSTREAM_BASE = "https://raw.githubusercontent.com/lanl-ansi/ThermalModels.jl/$UPSTREAM_COMMIT/example_network/"
const UPSTREAM_SHA256 = Dict(
    "edges.csv" => "b1e1cc078ed8c0c4175d6d12492376cbef3cacdee323666085375c94fcf452a1",
    "junctions.csv" => "6ee181b3a7aebcb5684758536c047d678489e4835eff28b2cb425be08e3455b5",
    "loads.csv" => "15e495239a52c00a5491fd079b85a8d7b5f05ef9846c69c1280105a84ec0e91f",
)

# Upstream scenario values for this network, in SI units.
const UPSTREAM_STEAM_FRICTION = 0.013
const UPSTREAM_WATER_FRICTION = 2.0e-3
const UPSTREAM_STEAM_GAMMA_W_PER_MK = 0.1
const UPSTREAM_WATER_GAMMA_W_PER_MK = 0.05
const UPSTREAM_PUMP_BOOST_PA = 34473.8
const UPSTREAM_PLANT_RATING_W = 30.0e6
const UPSTREAM_PLANT_OUTLET_PRESSURE_PA = 275790.0
const UPSTREAM_PLANT_INLET_PRESSURE_PA = 34473.8
const UPSTREAM_MAX_TEMP_K = 423.15

function download_upstream_example(dir::AbstractString)
    for (name, expected) in UPSTREAM_SHA256
        path = joinpath(dir, name)
        Downloads.download(UPSTREAM_BASE * name, path)
        actual = bytes2hex(open(sha256, path))
        actual == expected || error("Checksum mismatch for upstream file $name: $actual")
    end
    return dir
end

_csv_rows(path) = [split(line, ',') for line in readlines(path)[2:end] if !isempty(strip(line))]

"""
    upstream_example_network() -> CampusNetwork

Download the upstream example network and express it in this repository's network contract. Every
outgoing junction and pipe gets a return twin, and return pipes run opposite to the steam.
"""
function upstream_example_network()
    return mktempdir() do dir
        download_upstream_example(dir)
        parse_upstream_example(dir)
    end
end

function parse_upstream_example(dir::AbstractString)
    node_rows = _csv_rows(joinpath(dir, "junctions.csv"))
    edge_rows = _csv_rows(joinpath(dir, "edges.csv"))
    load_rows = _csv_rows(joinpath(dir, "loads.csv"))

    node_ids = [parse(Int, r[1]) for r in node_rows]
    index = Dict(id => k for (k, id) in enumerate(node_ids))
    n = length(node_ids)

    plant_row = only(r for r in load_rows if r[3] == "Plant")
    plant_node = index[parse(Int, plant_row[2])]
    demand_rows = [r for r in load_rows if r[3] != "Plant"]
    load_nodes = Set(index[parse(Int, r[2])] for r in demand_rows)

    kind(k) = k == plant_node ? "plant" : k in load_nodes ? "load" : "junction"
    junctions = Junction[]
    for (side, offset) in (("steam", 0), ("water", n)), (k, r) in enumerate(node_rows)
        push!(junctions, Junction(k + offset, side, kind(k), parse(Float64, r[2]), parse(Float64, r[3])))
    end

    pipes = CampusSteam.Pipe[]
    for r in edge_rows
        from, to = index[parse(Int, r[2])], index[parse(Int, r[3])]
        d, len = parse(Float64, r[4]), parse(Float64, r[6])
        push!(pipes, CampusSteam.Pipe(length(pipes) + 1, "steam", from, to, len, d,
            UPSTREAM_STEAM_FRICTION, UPSTREAM_STEAM_GAMMA_W_PER_MK / (pi * d), 0.0, false))
    end
    for r in edge_rows
        from, to = index[parse(Int, r[2])], index[parse(Int, r[3])]
        d, len = parse(Float64, r[5]), parse(Float64, r[6])
        boost = parse(Float64, r[7]) >= 0.01 ? UPSTREAM_PUMP_BOOST_PA : 0.0
        push!(pipes, CampusSteam.Pipe(length(pipes) + 1, "water", to + n, from + n, len, d,
            UPSTREAM_WATER_FRICTION, UPSTREAM_WATER_GAMMA_W_PER_MK / (pi * d), boost, false))
    end

    loads = [
        Load(l, "Load $l", "classroom", index[parse(Int, r[2])], index[parse(Int, r[2])] + n,
            parse(Float64, r[4]), 1.0)
        for (l, r) in enumerate(demand_rows)
    ]
    plant = Plant(plant_node, plant_node + n, UPSTREAM_PLANT_RATING_W, 1, UPSTREAM_PLANT_RATING_W,
        UPSTREAM_MAX_TEMP_K, UPSTREAM_PLANT_OUTLET_PRESSURE_PA, UPSTREAM_PLANT_INLET_PRESSURE_PA)
    return validate_network(CampusNetwork(junctions, pipes, loads, plant))
end

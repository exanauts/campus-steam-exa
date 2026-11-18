# Generate a synthetic campus and write its CSV files.
#
#   julia --project=. scripts/generate_campus.jl
#   julia --project=. scripts/generate_campus.jl --n-junctions 10000 --seed 2 --out data/synthetic/large
#
# Without --n-junctions this writes the demo campus to data/synthetic/demo. The file
# load_profiles.csv is about 7 MB for the demo campus and is not committed.

using CampusSteam

function parse_arguments(args)
    options = Dict{String,String}()
    i = 1
    while i <= length(args)
        key = args[i]
        key in ("--n-junctions", "--seed", "--out") && i < length(args) ||
            error("Usage: generate_campus.jl [--n-junctions N] [--seed S] [--out DIR]")
        options[key] = args[i + 1]
        i += 2
    end
    return options
end

function main(args)
    options = parse_arguments(args)
    seed = parse(Int, get(options, "--seed", "1"))
    scaled = haskey(options, "--n-junctions")
    default_dir = joinpath("data", "synthetic", scaled ? "scaled" : "demo")
    relative_dir = get(options, "--out", default_dir)
    dir = isabspath(relative_dir) ? relative_dir : joinpath(dirname(@__DIR__), relative_dir)

    elapsed = @elapsed net = if scaled
        scaled_campus(parse(Int, options["--n-junctions"]); seed)
    else
        demo_campus(; seed)
    end
    profiles = generate_profiles(net; seed)
    write_network(dir, net)
    write_profiles(dir, profiles)

    design = sum(load.design_heat_W for load in net.loads)
    println("Network generated in ", round(elapsed; digits = 2), " s and written to ", relative_dir)
    println("Junctions:   ", length(net.junctions))
    println("Pipes:       ", length(net.pipes), " (", count(p -> p.is_loop, net.pipes), " in loops)")
    println("Loads:       ", length(net.loads))
    println("Design heat: ", round(design / 1e6; digits = 2), " MW")
    println("Plant:       ", round(net.plant.rating_W / 1e6; digits = 2), " MW, ",
            net.plant.n_boilers, " boilers")
    return nothing
end

main(ARGS)

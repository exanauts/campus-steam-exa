# Fast checks of the committed reference validation. The solves live in validation/run_validation.jl,
# which has its own environment, so this file only reads results/validation.csv and the notes.

using Test

include(joinpath(dirname(@__DIR__), "validation", "source_hash.jl"))

const VALIDATION_THRESHOLD = 1.0e-6
const VALIDATION_METRICS = (
    "rel_diff_objective",
    "max_rel_diff_pressure",
    "max_rel_diff_temperature",
    "max_rel_diff_flow",
    "rel_diff_plant_output",
)
const VALIDATION_COLUMNS = (
    "instance", "data", "n_variables", "n_constraints", "madnlp_status", "ipopt_status",
    "objective_madnlp_W", "objective_ipopt_W", VALIDATION_METRICS..., "commit_sha",
    "generator_commit", "model_commit", "source_hash",
)

function read_validation_csv(path)
    lines = filter(!isempty, strip.(readlines(path)))
    header = String.(split(lines[1], ','))
    return header, [Dict(zip(header, String.(split(line, ',')))) for line in lines[2:end]]
end

# Explanations are tagged in the notes as
# <!-- explains: instance=NAME metric=COLUMN bound=VALUE -->
function read_explanations(path)
    pattern = r"<!--\s*explains:\s*instance=(\S+)\s+metric=(\S+)\s+bound=(\S+)\s*-->"
    return Dict((m[1], m[2]) => parse(Float64, m[3]) for m in eachmatch(pattern, read(path, String)))
end

@testset "Reference validation results" begin
    root = dirname(@__DIR__)
    csv = joinpath(root, "results", "validation.csv")
    notes = joinpath(root, "docs", "validation-notes.md")
    @test isfile(csv)
    @test isfile(notes)
    header, rows = read_validation_csv(csv)
    explained = read_explanations(notes)

    @testset "columns and coverage" begin
        @test all(in(header), VALIDATION_COLUMNS)
        names = [r["instance"] for r in rows]
        @test allunique(names)
        @test "upstream_example" in names
        @test "demo_campus" in names
        @test count(startswith("scaled_campus_"), names) >= 2
    end

    @testset "row $(r["instance"])" for r in rows
        @test r["data"] == "synthetic"
        @test occursin(r"^[0-9a-f]{40}$", r["commit_sha"])
        @test parse(Int, r["n_variables"]) > 0
        @test parse(Int, r["n_constraints"]) > 0
        @test r["madnlp_status"] == "SOLVE_SUCCEEDED"
        @test r["ipopt_status"] == "LOCALLY_SOLVED"
        for metric in VALIDATION_METRICS
            value = parse(Float64, r[metric])
            @test isfinite(value)
            value <= VALIDATION_THRESHOLD && continue
            # A difference above the threshold needs a written explanation that covers its size.
            bound = get(explained, (r["instance"], metric), nothing)
            @test bound !== nothing
            bound === nothing || @test value <= bound
        end
    end

    @testset "results match the current sources" begin
        # On failure, rerun validation/run_validation.jl and review docs/validation-notes.md.
        @test all(r -> r["source_hash"] == validation_source_hash(root), rows)
    end

    @testset "scaled sizes follow the selection rule" begin
        _, sweep = read_validation_csv(joinpath(root, "results", "validation_size_sweep.csv"))
        solved = sort([
            parse(Int, r["n_junctions"]) for r in sweep
            if r["madnlp_status"] == "SOLVE_SUCCEEDED" && r["ipopt_status"] == "LOCALLY_SOLVED"
        ])
        expected = ["scaled_campus_$n" for n in solved[max(end - 1, 1):end]]
        @test sort(filter(startswith("scaled_campus_"), [r["instance"] for r in rows])) == sort(expected)
    end

    @testset "solver packages stay out of the main environment" begin
        project = read(joinpath(root, "Project.toml"), String)
        @test !occursin("JuMP", project)
        @test !occursin("Ipopt", project)
    end
end

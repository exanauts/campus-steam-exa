# Fingerprint of the sources that determine results/validation*.csv. Shared by the validation run,
# which records it, and by test/test_validation.jl, which detects results that have gone stale.

using SHA: SHA2_256_CTX, update!, digest!

const VALIDATION_SOURCES = (
    "src/network.jl",
    "src/generator/campus.jl",
    "src/generator/profiles.jl",
    "src/generator/rng.jl",
    "src/model/data.jl",
    "src/model/formulation.jl",
    "src/model/options.jl",
    "src/model/solution.jl",
    "validation/jump_model.jl",
    "validation/run_validation.jl",
    "validation/upstream_example.jl",
)

"SHA-256 over the path and bytes of each file in `VALIDATION_SOURCES`, below the repository `root`."
function validation_source_hash(root::AbstractString)
    ctx = SHA2_256_CTX()
    for path in VALIDATION_SOURCES
        update!(ctx, Vector{UInt8}(path * "\0"))
        update!(ctx, read(joinpath(root, path)))
    end
    return bytes2hex(digest!(ctx))
end

# A self-contained SplitMix64 generator. Base's default RNG and `hash` may change
# between Julia versions, so neither is used anywhere in the generator.

mutable struct SplitMix64
    state::UInt64
end

function _next!(rng::SplitMix64)
    rng.state += 0x9e3779b97f4a7c15
    z = rng.state
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return z ⊻ (z >> 31)
end

# Independent stream for a seed and a purpose tag.
function _stream(seed::Integer, tag::Integer)
    rng = SplitMix64((seed % UInt64) * 0x9e3779b97f4a7c15 + (tag % UInt64) * 0xd1342543de82ef95)
    _next!(rng)
    return rng
end

# Uniform on [0, 1) using the top 53 bits.
_uniform!(rng::SplitMix64) = Float64(_next!(rng) >> 11) * 2.0^-53
_uniform!(rng::SplitMix64, a::Real, b::Real) = a + (b - a) * _uniform!(rng)

# Uniform integer on a:b. The modulo bias is negligible for the small ranges used here.
_uniform_int!(rng::SplitMix64, a::Int, b::Int) = a + Int(_next!(rng) % UInt64(b - a + 1))

# Standard normal variate by the Box-Muller transform.
function _normal!(rng::SplitMix64)
    u = 1.0 - _uniform!(rng)
    v = _uniform!(rng)
    return sqrt(-2 * log(u)) * cos(2 * pi * v)
end

function _shuffle!(rng::SplitMix64, items::Vector)
    for i in length(items):-1:2
        j = _uniform_int!(rng, 1, i)
        items[i], items[j] = items[j], items[i]
    end
    return items
end

# Synthetic weather year and hourly building heat demand.
#
# The fictional climate has a mean of 9 C, a 14 C seasonal swing and a 4 C daily swing,
# plus slowly varying weather noise. Hour 1 is a Monday at 00:00 on 1 January. One
# 168-hour cold snap starts between day 15 and day 38, reaches -22 C and is flagged in
# `is_cold_snap`; all other hours stay at or above -14 C.
#
# Heat demand is `design * (base + (1 - base) * f(T)) * pattern * (1 + noise)`, where
# `f` is 0 at the 18 C balance point and 1 at the design temperature of -15 C.

"Outdoor temperature at which a load draws its `design_heat_W`."
const DESIGN_OUTDOOR_TEMP_C = -15.0

const _BALANCE_TEMP_C = 18.0
const _HOURS_PER_YEAR = 8760
const _SNAP_HOURS = 168
const _SNAP_RAMP_HOURS = 24
const _SNAP_MEAN_C = -19.0
const _SNAP_SWING_C = 3.0
const _NON_SNAP_MIN_C = -14.0

# Share of design heat that does not depend on weather (hot water, process, reheat).
const _BASE_FRACTION = Dict("lab" => 0.30, "housing" => 0.15, "classroom" => 0.08,
                            "critical" => 0.35)

function _weather_year(seed::Integer)
    rng = _stream(seed, 3)
    temps = Vector{Float64}(undef, _HOURS_PER_YEAR)
    noise = 0.0
    for h in 1:_HOURS_PER_YEAR
        day = (h - 1) / 24
        hod = (h - 1) % 24
        noise = 0.985 * noise + 0.6 * _normal!(rng)
        temps[h] = max(_NON_SNAP_MIN_C,
                       9.0 - 14.0 * cos(2 * pi * (day - 20) / 365) -
                       4.0 * cos(2 * pi * (hod - 3) / 24) + noise)
    end
    first_hour = _uniform_int!(rng, 15, 38) * 24 + 1
    is_snap = fill(false, _HOURS_PER_YEAR)
    is_snap[first_hour:(first_hour + _SNAP_HOURS - 1)] .= true
    for i in 0:(_SNAP_HOURS - 1)
        h = first_hour + i
        ramp = min(1.0, (i + 1) / _SNAP_RAMP_HOURS, (_SNAP_HOURS - i) / _SNAP_RAMP_HOURS)
        snap = _SNAP_MEAN_C + _SNAP_SWING_C * cos(2 * pi * (((h - 1) % 24) - 15) / 24)
        temps[h] = (1 - ramp) * temps[h] + ramp * snap
    end
    return round.(temps; digits = 2), is_snap
end

# Bump centred on hour `c` of the day with a width of about `w` hours.
function _daily_bump(hod, c, w)
    d = abs(hod - c)
    d = min(d, 24 - d)
    return exp(-(d / w)^2)
end

# Occupancy pattern by type, for hour of day `hod` and day of week `dow` (0 is Monday).
function _pattern(type::String, hod::Int, dow::Int)
    weekend = dow >= 5
    if type == "lab"
        return weekend ? 0.90 + 0.03 * _daily_bump(hod, 13, 5) :
               0.92 + 0.08 * _daily_bump(hod, 13, 5)
    elseif type == "housing"
        return 0.86 + 0.19 * _daily_bump(hod, 7, 2.5) + 0.14 * _daily_bump(hod, 19, 3)
    elseif type == "classroom"
        weekend && return 0.62
        hod < 6 && return 0.70
        hod < 8 && return 0.70 + 0.15 * (hod - 5)
        hod < 18 && return 1.0
        hod < 21 && return 1.0 - 0.10 * (hod - 17)
        return 0.70
    else
        return 0.97 + 0.03 * _daily_bump(hod, 13, 6)
    end
end

"""
    generate_profiles(net; seed = 1, hours = 8760) -> LoadProfiles

Hourly weather and heat demand for every load of `net`. Outdoor temperature drives
demand, on top of daily and weekly patterns that depend on the load type. A shorter
`hours` returns the first hours of the same year. The 168-hour cold snap starts
between day 15 and day 38 of the year and is flagged in `is_cold_snap`.
"""
function generate_profiles(net::CampusNetwork; seed::Integer = 1, hours::Integer = _HOURS_PER_YEAR)
    1 <= hours <= _HOURS_PER_YEAR ||
        throw(ArgumentError("hours must be between 1 and $_HOURS_PER_YEAR; got $hours."))
    temps, is_snap = _weather_year(seed)
    heat = Matrix{Float64}(undef, hours, length(net.loads))
    span = _BALANCE_TEMP_C - DESIGN_OUTDOOR_TEMP_C
    for (k, load) in enumerate(net.loads)
        rng = _stream(seed, 1000 + load.id)
        base = _BASE_FRACTION[load.type]
        noise = 0.0
        for h in 1:hours
            noise = 0.9 * noise + 0.01 * (_uniform!(rng) - 0.5)
            weather = max(0.0, (_BALANCE_TEMP_C - temps[h]) / span)
            pattern = _pattern(load.type, (h - 1) % 24, ((h - 1) ÷ 24) % 7)
            heat[h, k] = round(load.design_heat_W * (base + (1 - base) * weather) * pattern *
                               (1 + noise))
        end
    end
    return LoadProfiles(temps[1:hours], is_snap[1:hours], heat)
end

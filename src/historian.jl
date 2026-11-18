# Reader for historian-style CSV in the narrow format `DateTime,TagName,Value,Quality`.
#
# One row holds one sample of one tag. The reader keeps every row as written. `align_historian` then
# applies the quality policy and returns an hourly matrix in which each excluded or missing sample is
# `NaN` and carries a status code saying why, so nothing is silently filled in.

using Dates: Dates, DateTime, Hour, Millisecond, @dateformat_str

export HistorianTable, HistorianSeries, read_historian, align_historian, historian_counts
export write_historian_header, write_historian_row, HISTORIAN_HEADER
export SAMPLE_GOOD, SAMPLE_BAD, SAMPLE_UNCERTAIN, SAMPLE_BLANK, SAMPLE_ABSENT

"Header line of the narrow historian format."
const HISTORIAN_HEADER = "DateTime,TagName,Value,Quality"

const _HISTORIAN_TIME_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

# Status of one aligned sample. Only `SAMPLE_GOOD` entries hold a number.
"The sample is usable."
const SAMPLE_GOOD = 0x00
"The row is flagged `Bad`, or has a quality this reader does not know."
const SAMPLE_BAD = 0x01
"The row is flagged `Uncertain` and the policy does not accept that quality."
const SAMPLE_UNCERTAIN = 0x02
"The row is flagged as acceptable but its value is empty or not a finite number."
const SAMPLE_BLANK = 0x03
"The historian has no row for this tag and hour."
const SAMPLE_ABSENT = 0x04

"""
    HistorianTable

Rows of a narrow historian file as written: `time`, `tag`, `value` (`NaN` when the field is empty or
not a number) and `quality`, one entry per row.
"""
struct HistorianTable
    time::Vector{DateTime}
    tag::Vector{String}
    value::Vector{Float64}
    quality::Vector{String}
end

Base.length(table::HistorianTable) = length(table.time)

"""
    HistorianSeries

Hourly samples after the quality policy. `values[h, i]` is the sample of `tags[i]` in hour `h`, where
hour 1 starts at `start`, and is `NaN` unless `status[h, i] == SAMPLE_GOOD`.

`duplicates` counts repeated tag-hour rows, of which the last acceptable row is kept. `off_grid`
counts rows that are not on the hour or fall outside the window, and `unknown_tags` counts rows of
tags that were not requested. None of these rows contribute a sample.
"""
struct HistorianSeries
    tags::Vector{String}
    start::DateTime
    values::Matrix{Float64}
    status::Matrix{UInt8}
    duplicates::Int
    off_grid::Int
    unknown_tags::Int
end

"""
    read_historian(source) -> HistorianTable

Read narrow historian CSV from a path or an `IO`. The header must be exactly
`$HISTORIAN_HEADER`. Timestamps use `yyyy-mm-dd HH:MM:SS`. An empty or non-numeric `Value` is read as
`NaN`, and the row is kept so that `align_historian` can report it. A row with the wrong number of
fields or an unreadable timestamp throws an `ArgumentError` that names the line.
"""
read_historian(path::AbstractString) = open(read_historian, path)

function read_historian(io::IO)
    header = readline(io)
    strip(header, ['﻿', ' ', '\r']) == HISTORIAN_HEADER ||
        throw(ArgumentError("expected the header `$HISTORIAN_HEADER`, found `$header`"))
    time, tag, value, quality = DateTime[], String[], Float64[], String[]
    names = Dict{String, String}()    # one shared String per distinct tag or quality
    line_number = 1
    for line in eachline(io)
        line_number += 1
        isempty(strip(line)) && continue
        fields = split(rstrip(line, '\r'), ',')
        length(fields) == 4 ||
            throw(ArgumentError("line $line_number: expected 4 fields, found $(length(fields))"))
        stamp = tryparse(DateTime, strip(fields[1]), _HISTORIAN_TIME_FORMAT)
        stamp === nothing &&
            throw(ArgumentError("line $line_number: unreadable timestamp `$(fields[1])`"))
        number = tryparse(Float64, strip(fields[3]))
        push!(time, stamp)
        push!(tag, get!(() -> String(strip(fields[2])), names, fields[2]))
        push!(value, number === nothing ? NaN : number)
        push!(quality, get!(() -> String(strip(fields[4])), names, fields[4]))
    end
    return HistorianTable(time, tag, value, quality)
end

# Status of a row under the accepted qualities, before its value is looked at.
function _quality_status(quality::AbstractString, accept)
    any(q -> lowercase(q) == lowercase(quality), accept) && return SAMPLE_GOOD
    return lowercase(quality) == "uncertain" ? SAMPLE_UNCERTAIN : SAMPLE_BAD
end

"""
    align_historian(table; tags, start, hours, accept = ("Good",)) -> HistorianSeries

Place the rows of `table` on an hourly grid of `hours` hours from `start`. Only rows whose quality is
listed in `accept` provide a value. Everything else is `NaN` with a status code:

- `SAMPLE_BAD`: flagged `Bad`, or a quality that is not recognized.
- `SAMPLE_UNCERTAIN`: flagged `Uncertain`, unless `accept` includes it.
- `SAMPLE_BLANK`: acceptable quality, but the value is empty or not finite.
- `SAMPLE_ABSENT`: no row exists for that tag and hour.

Missing samples are never interpolated. When a tag-hour has several rows, the last acceptable row
wins, and an acceptable row always wins over an excluded one.
"""
function align_historian(
        table::HistorianTable; tags, start::DateTime, hours::Integer, accept = ("Good",),
    )
    hours >= 1 || throw(ArgumentError("hours must be positive"))
    names = String.(collect(tags))
    allunique(names) || throw(ArgumentError("tags must be unique"))
    column = Dict(name => i for (i, name) in enumerate(names))
    values = fill(NaN, hours, length(names))
    status = fill(SAMPLE_ABSENT, hours, length(names))
    duplicates, off_grid, unknown = 0, 0, 0
    for row in eachindex(table.time)
        i = get(column, table.tag[row], 0)
        if i == 0
            unknown += 1
            continue
        end
        offset = Dates.value(table.time[row] - start)    # milliseconds
        if offset < 0 || offset % 3_600_000 != 0 || offset ÷ 3_600_000 >= hours
            off_grid += 1
            continue
        end
        h = offset ÷ 3_600_000 + 1
        code = _quality_status(table.quality[row], accept)
        code == SAMPLE_GOOD && !isfinite(table.value[row]) && (code = SAMPLE_BLANK)
        if status[h, i] != SAMPLE_ABSENT
            duplicates += 1
            status[h, i] == SAMPLE_GOOD && code != SAMPLE_GOOD && continue
        end
        status[h, i] = code
        values[h, i] = code == SAMPLE_GOOD ? table.value[row] : NaN
    end
    return HistorianSeries(names, start, values, status, duplicates, off_grid, unknown)
end

"""
    historian_counts(series::HistorianSeries) -> NamedTuple

Number of tag-hours by status: `total`, `good`, `bad`, `uncertain`, `blank` and `absent`.
"""
function historian_counts(series::HistorianSeries)
    count_of(code) = count(==(code), series.status)
    return (
        total = length(series.status),
        good = count_of(SAMPLE_GOOD),
        bad = count_of(SAMPLE_BAD),
        uncertain = count_of(SAMPLE_UNCERTAIN),
        blank = count_of(SAMPLE_BLANK),
        absent = count_of(SAMPLE_ABSENT),
    )
end

"Write the header line of the narrow format."
write_historian_header(io::IO) = println(io, HISTORIAN_HEADER)

"""
    write_historian_row(io, time, tag, value, quality)

Write one narrow-format row. A `NaN` value is written as an empty field.
"""
function write_historian_row(io::IO, time::DateTime, tag::AbstractString, value::Real, quality::AbstractString)
    print(io, Dates.format(time, _HISTORIAN_TIME_FORMAT), ',', tag, ',')
    isnan(value) || print(io, round(value; digits = 4))
    println(io, ',', quality)
    return nothing
end

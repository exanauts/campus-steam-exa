# Network data contract

This is the interface between the synthetic campus generator and the optimization models.
All quantities are SI unless the column name says otherwise. All data is synthetic.

## Topology

The network has two sides, steam supply and condensate/water return. Each load and the plant
connect one steam junction to one water junction. Steam leaves the plant, releases heat at
the loads, and returns to the plant as water.

Each pipe's `from -> to` is its nominal flow direction. Models may assume flow is non-negative
in that direction, which keeps `phi*abs(phi)` smooth. `orient_network` recomputes directions
when a pipe is out of service, so a looped main can reroute without a reversible-flow model.

`orient_network` directs pipes along the flow at the design heat of every load. It removes the
out-of-service pipes and renumbers the remaining pipes contiguously in their original order;
junction and load ids do not change. During an outage, a lightly loaded looped main can carry a
small reverse flow at part load, so outage models must tolerate that on `is_loop` pipes.

## Files (one directory per network)

### `junctions.csv`

| Column | Type | Meaning |
|---|---|---|
| `id` | Int | 1-based, contiguous |
| `side` | String | `steam` or `water` |
| `kind` | String | `plant`, `load`, or `junction` |
| `x_m`, `y_m` | Float64 | Drawing coordinates |

### `pipes.csv`

| Column | Type | Meaning |
|---|---|---|
| `id` | Int | 1-based, contiguous |
| `side` | String | `steam` or `water` |
| `from`, `to` | Int | Junction ids on the same side |
| `length_m`, `diameter_m` | Float64 | Geometry |
| `friction_factor` | Float64 | Darcy-Weisbach factor, dimensionless |
| `heat_loss_W_per_m2K` | Float64 | Overall heat-transfer coefficient to ground |
| `max_pump_boost_Pa` | Float64 | 0 when the pipe has no pump |
| `is_loop` | Bool | True when removing the pipe keeps every load connected |

### `loads.csv`

| Column | Type | Meaning |
|---|---|---|
| `id` | Int | 1-based, contiguous |
| `name` | String | Generic label such as `Lab 07`; never a real building name |
| `type` | String | `lab`, `housing`, `classroom`, or `critical` |
| `steam_junction`, `water_junction` | Int | Connection points |
| `design_heat_W` | Float64 | Heat demand at the design outdoor temperature |
| `priority_weight` | Float64 | Shed penalty weight; highest for `critical` |

### `plant.csv` (one row)

| Column | Type | Meaning |
|---|---|---|
| `steam_junction`, `water_junction` | Int | Connection points |
| `rating_W` | Float64 | Total output rating |
| `n_boilers` | Int | Identical boilers that share the rating |
| `ramp_limit_W_per_h` | Float64 | Maximum hourly output change |
| `supply_temp_K`, `supply_pressure_Pa` | Float64 | Nominal steam supply state |
| `return_pressure_Pa` | Float64 | Nominal water pressure at the plant |

### `weather.csv` and `load_profiles.csv`

- `weather.csv`: `hour` (1-based), `outdoor_temp_C`, `is_cold_snap` (Bool).
- `load_profiles.csv`: `hour`, `load_id`, `heat_W`, in narrow format.

## Julia API (`CampusSteam`)

```julia
demo_campus(; seed = 1)::CampusNetwork          # about 45 loads, 130-140 junctions
scaled_campus(n_junctions; seed = 1)::CampusNetwork
generate_profiles(net; seed = 1, hours = 8760)::LoadProfiles
orient_network(net; out_of_service = Int[])::CampusNetwork
write_network(dir, net)
read_network(dir)::CampusNetwork
```

`CampusNetwork` has the fields `junctions`, `pipes`, `loads`, and `plant`. Each of the first
three is a `Vector` of an immutable struct whose field names match the CSV columns, and `plant`
is one such struct. The structs are `Junction`, `Pipe`, `Load`, and `Plant`. `LoadProfiles` has
the fields `outdoor_temp_C::Vector{Float64}`, `is_cold_snap::Vector{Bool}`, and
`heat_W::Matrix{Float64}`, indexed `(hour, load_id)`.

The types and API live in `src/network.jl`. Generators are deterministic for a given seed.

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

## Layout of the generated campuses

`demo_campus` and `scaled_campus` lay out one plant at campus size by the same rule:

- The plant sits on the south edge. A west and an east trunk main leave it along a header, turn
  north at the corners and pass a series of branch stations. Every main is sized for its own flow,
  so the trunks taper away from the plant.
- Branch mains run east or west from the stations, and each building hangs off a branch by a short
  lateral. Mains run straight with bends at corners and one jog in the west trunk. No pipe crosses
  another pipe or a building footprint (`BUILDING_FOOTPRINT_M`).
- Two cross-ties join the trunks and close two loops around an open quad lined with classrooms.
  The middle of the first tie feeds a short clinic spur toward the plant, so the critical buildings
  receive steam from both trunks; the middle of the second feeds a north spine to an outlying housing
  group. On campuses with three or more stations per trunk, the east trunk detours around the lab
  district as a ring, and the outermost branches start with a long untapped run to outlying
  buildings. The rest of the network is a tree.
- Housing lies to the west, labs to the east, classrooms around the quad and clinics on the spur.
- Building sizes are redrawn, within the same ranges, until no looped main changes flow direction
  over the load mixes of a year, so models can orient every pipe once along the design flow. This
  holds for the demo campus and the 40-junction calibration campus over the generated year; larger
  scaled campuses keep the best draw found and are solved at design heat.
- The water side mirrors the steam side pipe for pipe and is drawn with a small offset.

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
demo_campus(; seed = 1)::CampusNetwork          # 45 loads, 166 junctions, 2 loops
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

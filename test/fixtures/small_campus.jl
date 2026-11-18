# Hand-built synthetic network that follows docs/network-schema.md.
#
# Steam side: plant at 1, feeding 1 -> 2, then 2 -> 3, 2 -> 4, 3 -> 5, and 4 -> 5 closing a loop.
# Water side: junctions 6 to 10 mirror 1 to 5 with every pipe reversed, and a pump on 7 -> 6.

function small_campus(; rating_W = 8.0e6, heat_scale = 1.0)
    junction(id, side, kind) = Junction(id, side, kind, Float64(id), 0.0)
    junctions = [
        junction(1, "steam", "plant"),
        junction(2, "steam", "junction"),
        junction(3, "steam", "load"),
        junction(4, "steam", "load"),
        junction(5, "steam", "load"),
        junction(6, "water", "plant"),
        junction(7, "water", "junction"),
        junction(8, "water", "load"),
        junction(9, "water", "load"),
        junction(10, "water", "load"),
    ]

    function pipe(id, side, from, to, length_m, diameter_m; boost = 0.0, is_loop = true)
        steam = side == "steam"
        return CampusSteam.Pipe(
            id, side, from, to, length_m, diameter_m, steam ? 0.013 : 0.002,
            steam ? 0.5 : 0.25, boost, is_loop,
        )
    end
    pipes = [
        pipe(1, "steam", 1, 2, 300.0, 0.25; is_loop = false),
        pipe(2, "steam", 2, 3, 200.0, 0.2),
        pipe(3, "steam", 2, 4, 250.0, 0.2),
        pipe(4, "steam", 3, 5, 150.0, 0.15),
        pipe(5, "steam", 4, 5, 180.0, 0.15),
        pipe(6, "water", 7, 6, 300.0, 0.15; boost = 34473.8, is_loop = false),
        pipe(7, "water", 8, 7, 200.0, 0.1),
        pipe(8, "water", 9, 7, 250.0, 0.1),
        pipe(9, "water", 10, 8, 150.0, 0.08),
        pipe(10, "water", 10, 9, 180.0, 0.08),
    ]

    loads = [
        Load(1, "Lab 01", "lab", 3, 8, heat_scale * 2.0e6, 2.0),
        Load(2, "Housing 01", "housing", 4, 9, heat_scale * 1.5e6, 1.0),
        Load(3, "Critical 01", "critical", 5, 10, heat_scale * 1.0e6, 10.0),
    ]

    plant = Plant(1, 6, rating_W, 2, 4.0e6, 423.15, 275790.0, 34473.8)

    return validate_network(CampusNetwork(junctions, pipes, loads, plant))
end

using CampusSteam
using Dates: DateTime, Hour
using Test

const _HISTORIAN_SAMPLE = """
DateTime,TagName,Value,Quality
2024-01-01 00:00:00,A.FLOW,10.5,Good
2024-01-01 01:00:00,A.FLOW,99.0,Bad
2024-01-01 02:00:00,A.FLOW,11.5,Uncertain
2024-01-01 03:00:00,A.FLOW,,Good
2024-01-01 00:00:00,B.TEMP,400.25,Good
2024-01-01 01:00:00,B.TEMP,401.25,good
2024-01-01 01:30:00,B.TEMP,500.0,Good
2024-01-01 02:00:00,B.TEMP,1.0,Bad
2024-01-01 02:00:00,B.TEMP,402.25,Good
2024-01-01 03:00:00,B.TEMP,403.25,Good
2024-01-01 03:00:00,B.TEMP,7.0,Bad
2024-01-01 00:00:00,C.OTHER,1.0,Good
2024-01-01 09:00:00,A.FLOW,12.0,Good
"""

@testset "historian ingest" begin
    table = read_historian(IOBuffer(_HISTORIAN_SAMPLE))
    @test length(table) == 13
    @test table.tag[1] == "A.FLOW" && table.value[1] == 10.5 && table.quality[2] == "Bad"
    @test isnan(table.value[4])

    start = DateTime(2024, 1, 1)
    series = align_historian(table; tags = ["A.FLOW", "B.TEMP", "D.NONE"], start, hours = 4)

    @testset "quality policy" begin
        @test series.values[1, 1] == 10.5
        @test isnan(series.values[2, 1]) && series.status[2, 1] == SAMPLE_BAD
        @test isnan(series.values[3, 1]) && series.status[3, 1] == SAMPLE_UNCERTAIN
        @test isnan(series.values[4, 1]) && series.status[4, 1] == SAMPLE_BLANK
        @test series.values[2, 2] == 401.25    # quality names are not case sensitive
    end

    @testset "missing samples stay missing" begin
        @test all(==(SAMPLE_ABSENT), series.status[:, 3])
        @test all(isnan, series.values[:, 3])
    end

    @testset "duplicates, off-grid rows and other tags" begin
        @test series.values[3, 2] == 402.25    # a good row replaces an earlier bad one
        @test series.values[4, 2] == 403.25    # a later bad row does not replace a good one
        @test series.duplicates == 2
        @test series.off_grid == 2             # 01:30 and the hour past the window
        @test series.unknown_tags == 1
    end

    @testset "counts" begin
        c = historian_counts(series)
        @test c.total == 12
        @test c.good == 5 && c.bad == 1 && c.uncertain == 1 && c.blank == 1 && c.absent == 4
        @test c.good + c.bad + c.uncertain + c.blank + c.absent == c.total
    end

    @testset "accepting uncertain samples is an explicit choice" begin
        relaxed = align_historian(table; tags = ["A.FLOW"], start, hours = 4, accept = ("Good", "Uncertain"))
        @test relaxed.values[3, 1] == 11.5
        @test relaxed.status[2, 1] == SAMPLE_BAD
    end

    @testset "malformed input is rejected" begin
        @test_throws ArgumentError read_historian(IOBuffer("Time,Tag,Value,Quality\n"))
        @test_throws ArgumentError read_historian(IOBuffer("$HISTORIAN_HEADER\n2024-01-01 00:00:00,A,1.0\n"))
        @test_throws ArgumentError read_historian(IOBuffer("$HISTORIAN_HEADER\nyesterday,A,1.0,Good\n"))
    end

    @testset "writer and reader agree" begin
        io = IOBuffer()
        write_historian_header(io)
        write_historian_row(io, DateTime(2024, 3, 1, 5), "X", 1.25, "Good")
        write_historian_row(io, DateTime(2024, 3, 1, 6), "X", NaN, "Bad")
        back = read_historian(IOBuffer(String(take!(io))))
        @test back.time == [DateTime(2024, 3, 1, 5), DateTime(2024, 3, 1, 6)]
        @test back.value[1] == 1.25 && isnan(back.value[2])
    end
end

@testset "calibration" begin
    net = CampusSteam.calibration_network()
    hours = 336

    @testset "forward physics agrees with the steam model" begin
        sim = ForwardSimulator(net)
        heat = reshape(Float64[l.design_heat_W for l in net.loads], 1, :)
        x = simulate_hours(sim, heat)[:, 1]
        s = sim.layout
        model = build_steam_model(net)
        full = zeros(model.nlp.meta.nvar)
        n = CampusSteam._iboost(s, s.npump)
        full[1:n] .= x[1:n]
        full[end] = x[end]    # shed and excess stay at zero
        c = zeros(model.nlp.meta.ncon)
        CampusSteam.ExaModels.NLPModels.cons!(model.nlp, full, c)
        d = model.data
        before_load_pressure = d.nmass + d.njunction + d.nedge + 2 * d.npipe + d.nload
        equality = vcat(1:before_load_pressure, model.nlp.meta.ncon)
        @test maximum(abs, c[equality]) < 1.0e-8
    end

    path = joinpath(mktempdir(), "synthetic_historian.csv")
    hist = generate_synthetic_historian(path; net, hours, spread = 0.0)
    names = [t.name for t in hist.tags]

    @testset "synthetic historian file" begin
        table = read_historian(path)
        @test length(table) == hist.rows
        @test filesize(path) == hist.bytes
        @test length(hist.tags) == 25
        @test sort(unique(t.category for t in hist.tags)) == ["flow", "pressure", "run state", "temperature"]
        @test hist.rows < 25 * hours
        series = align_historian(table; tags = names, start = CampusSteam.HISTORIAN_START, hours)
        counts = historian_counts(series)
        @test counts.bad > 0 && counts.absent > 0
        @test 0.90 < counts.good / counts.total < 0.99
        @test all(isnan, series.values[series.status .!= SAMPLE_GOOD])
    end

    @testset "recovers known coefficients on a two-week case" begin
        series = align_historian(read_historian(path); tags = names, start = CampusSteam.HISTORIAN_START, hours)
        nominal = simulate_hours(ForwardSimulator(net), hist.nominal_heat_W)
        problem = CalibrationProblem(net, series, hist.tags, hist.nominal_heat_W, nominal)
        result = solve_calibration(build_calibration_model(problem))
        errors = recovery_errors(result, hist.truth)
        estimated = hist.groups.estimated
        @test result.converged
        @test maximum(errors.loss[estimated]) < 0.05       # within 5% of the true multiplier
        @test maximum(errors.friction[estimated]) < 0.05
        @test all(isapprox.(result.loss[.!estimated], 1.0; atol = 1.0e-6))
        @test all(isapprox.(result.friction[.!estimated], 1.0; atol = 1.0e-6))
    end
end

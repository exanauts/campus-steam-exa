# Ipopt reference runs for the benchmarks. Ipopt stays out of the main package: this script runs
# with the validation environment stacked below the scripts environment.
#
#   JULIA_LOAD_PATH="scripts:validation:@stdlib" julia validation/ipopt_benchmark.jl \
#       OUTDIR REPEATS CASE [CASE...]
#
# Writes OUTDIR/ipopt_records.json and one raw Float64 solution file per case. The model is the
# same ExaModel the MadNLP runs use, passed to Ipopt through its C interface. Data is synthetic.

using Ipopt
using JSON

include(joinpath(@__DIR__, "..", "scripts", "site", "bench_common.jl"))

const IPOPT_STATUS = Dict(
    0 => "Solve_Succeeded", 1 => "Solved_To_Acceptable_Level", 2 => "Infeasible_Problem_Detected",
    3 => "Search_Direction_Becomes_Too_Small", 4 => "Diverging_Iterates",
    5 => "User_Requested_Stop", 6 => "Feasible_Point_Found", -1 => "Maximum_Iterations_Exceeded",
    -2 => "Restoration_Failed", -3 => "Error_In_Step_Computation",
    -4 => "Maximum_CpuTime_Exceeded", -5 => "Maximum_WallTime_Exceeded",
)

function ipopt_problem(nlp, eval_time)
    meta = nlp.meta
    jrows, jcols = BenchNLP.jac_structure(nlp)
    hrows, hcols = BenchNLP.hess_structure(nlp)
    timed(f) = (args...) -> begin
        start = time_ns()
        out = f(args...)
        eval_time[] += (time_ns() - start) / 1.0e9
        return out
    end
    eval_f = timed(x -> BenchNLP.obj(nlp, x))
    eval_g = timed((x, g) -> (BenchNLP.cons!(nlp, x, g); nothing))
    eval_grad = timed((x, g) -> (BenchNLP.grad!(nlp, x, g); nothing))
    eval_jac = timed(
        (x, rows, cols, values) -> begin
            if values === nothing
                rows .= jrows
                cols .= jcols
            else
                BenchNLP.jac_coord!(nlp, x, values)
            end
            return nothing
        end,
    )
    eval_h = timed(
        (x, rows, cols, obj_factor, lambda, values) -> begin
            if values === nothing
                rows .= hrows
                cols .= hcols
            else
                BenchNLP.hess_coord!(nlp, x, lambda, values; obj_weight = obj_factor)
            end
            return nothing
        end,
    )
    prob = Ipopt.CreateIpoptProblem(
        meta.nvar, Vector(meta.lvar), Vector(meta.uvar), meta.ncon, Vector(meta.lcon),
        Vector(meta.ucon), meta.nnzj, meta.nnzh, eval_f, eval_g, eval_grad, eval_jac, eval_h,
    )
    prob.x .= meta.x0
    return prob
end

# Wall-clock seconds of one line of Ipopt's timing statistics.
function timing_wall(log, label)
    m = match(Regex("(?m)^\\s*" * label * "\\.*:.*wall:\\s*([0-9.eE+-]+)\\)"), log)
    return m === nothing ? nothing : parse(Float64, m.captures[1])
end

function run_ipopt(id, nlp, repeat, outdir; tol = 1.0e-8, strict = false)
    eval_time = Ref(0.0)
    prob = ipopt_problem(nlp, eval_time)
    logfile = joinpath(outdir, "ipopt_$(id)_$(repeat).log")
    Ipopt.AddIpoptIntOption(prob, "print_level", 0)
    Ipopt.AddIpoptStrOption(prob, "sb", "yes")
    Ipopt.AddIpoptStrOption(prob, "output_file", logfile)
    Ipopt.AddIpoptIntOption(prob, "file_print_level", 5)
    Ipopt.AddIpoptStrOption(prob, "print_timing_statistics", "yes")
    Ipopt.AddIpoptNumOption(prob, "tol", tol)
    Ipopt.AddIpoptIntOption(prob, "max_iter", 1000)
    strict && Ipopt.AddIpoptIntOption(prob, "acceptable_iter", 0)
    compile_start = Base.cumulative_compile_time_ns()[1]
    start = time_ns()
    status = Ipopt.IpoptSolve(prob)
    total = (time_ns() - start) / 1.0e9
    compile = (Base.cumulative_compile_time_ns()[1] - compile_start) / 1.0e9
    log = read(logfile, String)
    iters = match(r"Number of Iterations\.*:\s*(\d+)", log)
    factor = timing_wall(log, "LinearSystemFactorization")
    backsolve = timing_wall(log, "LinearSystemBackSolve")
    x = copy(prob.x)
    # Ipopt's Lagrangian is f + y'g, the sign convention kkt_residuals expects.
    residuals = kkt_residuals(nlp, x, prob.mult_g, prob.mult_x_L, prob.mult_x_U)
    return (
        record = Dict{String, Any}(
            "case" => id, "solver" => "cpu_ipopt_mumps", "repeat" => repeat,
            "mode" => strict ? "strict" : "default", "tol_requested" => tol,
            "nvar" => nlp.meta.nvar, "ncon" => nlp.meta.ncon, "nnzj" => nlp.meta.nnzj,
            "nnzh" => nlp.meta.nnzh,
            "status" => get(IPOPT_STATUS, Int(status), string(status)),
            "iterations" => iters === nothing ? nothing : parse(Int, iters.captures[1]),
            "total_s" => total, "eval_s" => eval_time[],
            "linear_s" => (factor === nothing || backsolve === nothing) ? nothing : factor + backsolve,
            "compile_s" => compile, "objective" => BenchNLP.obj(nlp, x),
            "primal_residual" => residuals.primal, "dual_residual" => residuals.dual,
            "complementarity_residual" => residuals.complementarity, "kkt_residual" => residuals.kkt,
        ),
        x,
    )
end

function main(args)
    outdir, repeats, cases = args[1], parse(Int, args[2]), args[3:end]
    mkpath(outdir)
    records = Dict{String, Any}[]
    # The first solve compiles the callbacks and is not recorded.
    run_ipopt("warmup", bench_case("demo").nlp, 0, outdir)
    run_ipopt("warmup-mp", bench_case("horizon-2").nlp, 0, outdir)
    for id in cases, strict in (false, true)
        nlp = bench_case(id).nlp
        for repeat in 1:repeats
            result = run_ipopt(id, nlp, repeat, outdir; strict)
            push!(records, result.record)
            strict || write(joinpath(outdir, "ipopt_$(id).x.bin"), result.x)
            println(id, " strict=", strict, " repeat ", repeat, ": ", result.record["status"], " ",
                    round(result.record["total_s"]; sigdigits = 4), " s")
            flush(stdout)
        end
    end
    write(joinpath(outdir, "ipopt_records.json"), JSON.json(records, 2))
    return nothing
end

main(ARGS)

using CampusSteam, CUDA, CUDSS, MadNLP, MadNLPGPU, ExaModels, Printf
net = demo_campus()
prof(T) = generate_profiles(net; hours=T).heat_W
function row(label, r)
    c = r.counters
    @printf("%-30s %-28s it=%4d tot=%8.3f lin=%8.3f eval=%7.3f pr=%.1e du=%.1e obj=%.8e\n", label, string(r.status), r.iter, c.total_time, c.linear_solver_time, c.eval_function_time, r.primal_feas, r.dual_feas, r.objective)
    flush(stdout)
end
gpuopts = (; richardson_max_iter=30, richardson_tol=1e-12, cudss_asynchronous=false)
for T in (24,168,720)
    h = prof(T)
    mc = build_multiperiod_model(net; heat_W=h)
    mg = build_multiperiod_model(net; heat_W=h, backend=CUDABackend())
    if T == 24
        madnlp(mc.nlp; print_level=MadNLP.ERROR)
        madnlp(mg.nlp; print_level=MadNLP.ERROR, gpuopts...)
    end
    row("T=$T cpu default", madnlp(mc.nlp; print_level=MadNLP.ERROR, max_iter=1000))
    row("T=$T gpu default+rich", madnlp(mg.nlp; print_level=MadNLP.ERROR, max_iter=1000, gpuopts...))
    row("T=$T gpu async", madnlp(mg.nlp; print_level=MadNLP.ERROR, max_iter=1000, richardson_max_iter=30, richardson_tol=1e-12))
    for tol in (1e-4,1e-5,1e-6,1e-7,1e-8)
        s = (; tol, acceptable_tol=tol, acceptable_iter=100000, max_iter=1000, print_level=MadNLP.ERROR)
        row("T=$T cpu strict $tol", madnlp(mc.nlp; s...))
        row("T=$T gpu strict $tol", madnlp(mg.nlp; s..., gpuopts...))
    end
end

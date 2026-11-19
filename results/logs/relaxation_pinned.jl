# Does pinning the bound relaxation at 1e-8 on the GPU make strict tolerances comparable with the CPU?
using CampusSteam, CUDA, CUDSS, MadNLP, MadNLPGPU, ExaModels, Printf
net = demo_campus()
function row(label, r, ref)
    c = r.counters
    @printf("%-34s %-28s it=%4d tot=%8.3f lin=%8.3f pr=%.1e du=%.1e obj=%.8e objrel=%.1e\n", label, string(r.status), r.iter, c.total_time, c.linear_solver_time, r.primal_feas, r.dual_feas, r.objective, abs(r.objective - ref) / abs(ref))
    flush(stdout)
end
gpuopts = (; richardson_max_iter=30, richardson_tol=1e-12, cudss_asynchronous=false)
for T in (24, 168, 720)
    h = generate_profiles(net; hours=T).heat_W
    mc = build_multiperiod_model(net; heat_W=h)
    mg = build_multiperiod_model(net; heat_W=h, backend=CUDABackend())
    T == 24 && madnlp(mg.nlp; print_level=MadNLP.ERROR, gpuopts...)
    ref = madnlp(mc.nlp; print_level=MadNLP.ERROR, max_iter=1000).objective
    for tol in (1e-4, 1e-5, 1e-6, 1e-7, 1e-8), rep in 1:3
        s = (; tol, acceptable_tol=tol, acceptable_iter=100000, max_iter=1000, print_level=MadNLP.ERROR)
        row("T=$T gpu pinned tol=$tol rep=$rep", madnlp(mg.nlp; s..., gpuopts..., bound_relax_factor=1e-8), ref)
    end
end

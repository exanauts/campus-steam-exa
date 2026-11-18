// Writes invented site data for local page testing: node generate_mock.mjs <output dir>
// The output is marked "mock_fixture" and must never be copied into site/.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const out = process.argv[2] && resolve(process.argv[2]);
if (!out) throw new Error("usage: generate_mock.mjs <output dir>");
if (out.startsWith(join(root, "site"))) throw new Error("mock data must not be written under site/");
mkdirSync(out, { recursive: true });

const demo = join(root, "data/synthetic/demo");
const csv = (f) => {
  const [head, ...rows] = readFileSync(join(demo, f), "utf8").trim().split("\n").map((l) => l.split(","));
  return rows.map((r) => Object.fromEntries(r.map((v, i) => [head[i], v])));
};
const write = (name, value) => writeFileSync(join(out, name), JSON.stringify({ mock_fixture: true, ...value }));
const round = (v, d = 2) => +v.toFixed(d);

const junctions = csv("junctions.csv").filter((j) => j.side === "steam").map((j) => ({ id: +j.id, kind: j.kind, x: +j.x_m, y: +j.y_m }));
const pipes = csv("pipes.csv").filter((p) => p.side === "steam").map((p) => ({ id: +p.id, from: +p.from, to: +p.to, diameter_m: +p.diameter_m }));
const loads = csv("loads.csv").map((l) => ({ id: +l.id, name: l.name, type: l.type, junction: +l.steam_junction, design_heat_W: +l.design_heat_W }));
const plant = csv("plant.csv")[0];
const rating = +plant.rating_W;
write("campus.json", { junctions, pipes, loads, plant: { junction: +plant.steam_junction, rating_W: rating, n_boilers: +plant.n_boilers, supply_temp_C: +plant.supply_temp_K - 273.15 } });

const HOURS = 168;
const scenarios = [
  { id: "baseline", label: "Baseline", file: "scenario_baseline.json", description: "Mock: an ordinary winter week." },
  { id: "cold_snap", label: "Cold snap", file: "scenario_cold_snap.json", description: "Mock: a three-day cold snap." },
  { id: "plant_derate", label: "Plant derate", file: "scenario_plant_derate.json", description: "Mock: boilers out for two days." },
  { id: "pipe_out", label: "Pipe out", file: "scenario_pipe_out.json", description: "Mock: one main segment out of service." },
];
write("scenarios.json", { scenarios });

const designTotal = loads.reduce((t, l) => t + l.design_heat_W, 0);
for (const { id, label } of scenarios) {
  const outdoor = [], output = [], ratingW = [], temp = [], flow = [], inService = [], demand = [], served = [];
  for (let h = 0; h < HOURS; h++) {
    const snap = id === "cold_snap" && h >= 48 && h < 120 ? 1 : 0;
    const T = -4 + 4 * Math.sin((2 * Math.PI * (h - 8)) / 24) - 22 * snap;
    outdoor.push(round(T));
    const avail = id === "plant_derate" && h >= 60 && h < 108 ? rating * 0.45 : rating;
    ratingW.push(avail);
    const scale = Math.max(0.3, (18 - T) / 24) * 1.02;
    const d = loads.map((l) => l.design_heat_W * scale);
    const total = d.reduce((a, b) => a + b, 0);
    const lossW = 0.4e6;
    const short = Math.max(0, total + lossW - avail);
    const s = d.map((v, j) => Math.max(0, v - (short * v * (loads[j].type === "critical" ? 0 : 1.15)) / total));
    demand.push(d.map((v) => round(v, 0)));
    served.push(s.map((v) => round(v, 0)));
    output.push(round(Math.min(avail, s.reduce((a, b) => a + b, 0) + lossW), 0));
    const share = total / designTotal;
    flow.push(pipes.map((p, i) => round((id === "pipe_out" && i === 3 ? 0 : 1) * p.diameter_m ** 2 * 60 * share * (0.2 + (i % 7) / 7))));
    temp.push(pipes.map((_, i) => round(118 - (i / pipes.length) * 14 + 6 * (1 - share), 1)));
    inService.push(pipes.map((_, i) => (id === "pipe_out" && i === 3 ? 0 : 1)));
  }
  write(`scenario_${id}.json`, {
    id, label, outdoor_temp_C: outdoor,
    plant: { output_W: output, rating_W: ratingW },
    pipes: { ids: pipes.map((p) => p.id), temp_C: temp, flow_kg_s: flow, in_service: inService, heat_loss_W: output.map(() => 0.4e6) },
    loads: { ids: loads.map((l) => l.id), demand_W: demand, served_W: served },
  });
}

write("calibration.json", {
  finding: "Mock finding: fitted heat-loss error falls as more months of history are used.",
  chart: {
    title: "Mock calibration error", x_label: "Months of history", y_label: "Heat-loss error (%)",
    series: [
      { name: "Fitted model", x: [1, 3, 6, 12, 18, 24], y: [22, 12, 8, 5, 4, 3.5] },
      { name: "Uncalibrated", x: [1, 3, 6, 12, 18, 24], y: [30, 30, 30, 30, 30, 30] },
    ],
  },
  ask: { tag_count: 25, years: 2, rows: 438000, size_label: "tens of MB" },
  sample_rows: [
    { DateTime: "2025-01-15 07:00", TagName: "STEAM_HEADER_FLOW", Value: 41.2, Quality: "Good" },
    { DateTime: "2025-01-15 08:00", TagName: "STEAM_HEADER_FLOW", Value: -999, Quality: "Bad" },
    { DateTime: "2025-01-15 09:00", TagName: "STEAM_HEADER_FLOW", Value: 43.8, Quality: "Good" },
  ],
});

const runs = [];
[[24192, 1.5, 3.7, "solved"], [169344, 14, 19, "acceptable"], [725760, 88, 13, "acceptable"]].forEach(([size, c, g, gs], k) => {
  runs.push({ size, device: "cpu", solve_s: c, iterations: 58 + 9 * k, status: "solved" });
  runs.push({ size, device: "gpu", solve_s: g, iterations: 94 + 120 * k, status: gs });
});
write("benchmarks.json", { size_label: "Variables", runs });
write("build_info.json", { commit_sha: "0".repeat(40), run_date: "2026-01-01T00:00:00Z", cpu_model: "Mock CPU", gpu_model: "Mock GPU" });
writeFileSync(join(out, "tag_template.csv"), readFileSync(join(root, "scripts/ci/tag_template.csv")));
writeFileSync(join(out, "files.json"), JSON.stringify({ files: [
  "campus.json", "scenarios.json", ...scenarios.map((s) => s.file), "calibration.json", "benchmarks.json", "build_info.json", "tag_template.csv",
] }));

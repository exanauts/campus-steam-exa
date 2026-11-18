// Writes invented site data for local page testing: node generate_mock.mjs <output dir>
// The scenario files follow docs/site-data.md. The output is marked "mock_fixture" and must
// never be copied into site/.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const out = process.argv[2] && resolve(process.argv[2]);
if (!out) throw new Error("usage: generate_mock.mjs <output dir>");
if (out.startsWith(join(root, "site"))) throw new Error("mock data must not be written under site/");
mkdirSync(join(out, "scenarios"), { recursive: true });

const demo = join(root, "data/synthetic/demo");
const csv = (f) => {
  const [head, ...rows] = readFileSync(join(demo, f), "utf8").trim().split("\n").map((l) => l.split(","));
  return rows.map((r) => Object.fromEntries(r.map((v, i) => [head[i], v])));
};
const write = (name, value) => writeFileSync(join(out, name), JSON.stringify({ mock_fixture: true, ...value }));
const round = (v, d = 3) => +v.toFixed(d);
const column = (rows, key, f = (v) => v) => rows.map((r) => f(r[key]));
const labels = { synthetic: true, data_label: "Mock data for page tests.", model_label: "Mock model label." };

const junctions = csv("junctions.csv"), pipes = csv("pipes.csv"), loads = csv("loads.csv"), plant = csv("plant.csv")[0];
const ratingMW = +plant.rating_W / 1e6, boilers = +plant.n_boilers;
write("scenarios/network.json", {
  schema_version: 1, campus: "Example University (fictional)", ...labels,
  junctions: { id: column(junctions, "id", Number), side: column(junctions, "side"), kind: column(junctions, "kind"), x_m: column(junctions, "x_m", Number), y_m: column(junctions, "y_m", Number) },
  pipes: { id: column(pipes, "id", Number), side: column(pipes, "side"), from: column(pipes, "from", Number), to: column(pipes, "to", Number), length_m: column(pipes, "length_m", Number), diameter_m: column(pipes, "diameter_m", Number), is_loop: column(pipes, "is_loop", (v) => v === "true") },
  loads: { id: column(loads, "id", Number), name: column(loads, "name"), type: column(loads, "type"), steam_junction: column(loads, "steam_junction", Number), design_heat_MW: column(loads, "design_heat_W", (v) => +v / 1e6), priority_weight: column(loads, "priority_weight", Number) },
  plant: { steam_junction: +plant.steam_junction, rating_MW: ratingMW, n_boilers: boilers, one_boiler_out_MW: (ratingMW * (boilers - 1)) / boilers, ramp_limit_MW_per_h: +plant.ramp_limit_W_per_h / 1e6 },
});

const HOURS = 168;
const OUT_PIPE = 20;
const steamPipes = pipes.filter((p) => p.side === "steam");
const steamNodes = junctions.filter((j) => j.side === "steam");
const uniqueness = {
  plant_output: "unique", total_shed: "unique", shed_by_type: "unique", shed_by_building: "not_unique_within_equal_weights",
  total_losses: "indicative", steam_temperature: "unique_except_marked_hours", steam_pressure: "indicative_except_marked_hours",
  steam_pipe_flow: "unique_except_marked_hours", steam_pipe_loss: "unique_except_marked_hours",
  water_pipe_flow: "not_unique", water_pipe_loss: "not_unique", water_pressure: "not_exported", water_temperature: "not_exported",
};
const typeTotals = (byType) => ({ critical: 0, lab: 0, classroom: 0, housing: 0, ...byType });
const compareCase = (label, shed) => ({ label, weights: {}, status: "SOLVE_SUCCEEDED", presented: true, iterations: 50, solve_time_s: 1, summary: {}, shed_by_type_MWh: typeTotals(shed) });

const definitions = {
  baseline: { title: "Mock normal week", description: "Mock: a normal week.", events: [] },
  cold_snap: { title: "Mock cold snap", description: "Mock: loads higher for 48 hours.", events: [{ kind: "load_surge", first_hour: 49, last_hour: 96, factor: 1.5, shoulder_hours: 3 }] },
  plant_derate: { title: "Mock boiler out", description: "Mock: one boiler out for 48 hours.", events: [{ kind: "boiler_out", first_hour: 25, last_hour: 72, rating_MW: (ratingMW * (boilers - 1)) / boilers }] },
  pipe_out: { title: "Mock main out", description: "Mock: one main out for 48 hours.", events: [{ kind: "pipe_out", pipe: OUT_PIPE, first_hour: 49, last_hour: 96 }] },
};

for (const [id, def] of Object.entries(definitions)) {
  const event = def.events[0];
  const inEvent = (h) => event && h + 1 >= event.first_hour && h + 1 <= event.last_hour;
  const plantRows = { output_MW: [], rating_MW: [], demand_MW: [], shed_MW: [], excess_MW: [], losses_MW: [] };
  const flow = [], loss = [], temperature = [], pressure = [], loadShed = [], loadExcess = [];
  for (let h = 0; h < HOURS; h++) {
    const daily = 60 + 8 * Math.sin((2 * Math.PI * (h - 8)) / 24);
    const demand = daily * (id === "cold_snap" && inEvent(h) ? 1.5 : id === "plant_derate" ? 1.45 : 1);
    const rating = id === "plant_derate" && inEvent(h) ? event.rating_MW : ratingMW;
    const shed = Math.max(0, demand + 0.4 - rating);
    plantRows.output_MW.push(round(demand + 0.4 - shed));
    plantRows.rating_MW.push(rating);
    plantRows.demand_MW.push(round(demand));
    plantRows.shed_MW.push(round(shed));
    plantRows.excess_MW.push(0);
    plantRows.losses_MW.push(0.4);
    const out = (p) => id === "pipe_out" && inEvent(h) && +p.id === OUT_PIPE;
    flow.push(pipes.map((p, i) => (out(p) ? null : round((p.side === "steam" ? 1 : 3) * (i % 9 === 0 ? 0.2 : 2 + (i % 7) * 4) * (demand / 60), 2))));
    loss.push(pipes.map((p) => (out(p) ? null : 4)));
    temperature.push(steamNodes.map((_, i) => round(150 - (i / steamNodes.length) * 40, 2)));
    pressure.push(steamNodes.map(() => 900));
    const sheddable = loads.filter((l) => l.type === "lab" || l.type === "classroom");
    loadShed.push(loads.map((l) => (l.type === "lab" || l.type === "classroom" ? round(shed / sheddable.length) : 0)));
    loadExcess.push(loads.map(() => 0));
  }
  const totalShed = round(plantRows.shed_MW.reduce((a, b) => a + b, 0));
  const flowMarks = Object.fromEntries(steamPipes.filter((_, i) => i % 9 === 0).map((p) => [p.id, [[1, HOURS]]]));
  write(`scenarios/${id}.json`, {
    schema_version: 1, scenario: id, title: def.title, description: def.description, ...labels,
    hours: HOURS, first_hour_of_synthetic_year: 1177, events: def.events,
    solver: { status: "SOLVE_SUCCEEDED", converged_at_tolerance: true, tolerance: 1e-8, iterations: 60, solve_time_s: 1, nlp_solves: 1, orientation_method: "mock" },
    presented: true,
    summary: { peak_output_MW: Math.max(...plantRows.output_MW), total_demand_MWh: round(plantRows.demand_MW.reduce((a, b) => a + b, 0), 2), total_shed_MWh: totalShed, critical_shed_MWh: 0, total_losses_MWh: 67.2, total_excess_MWh: 0, buildings_shed: [] },
    uniqueness, flow_not_unique_below_kg_s: 0.5, plant: plantRows,
    nodes: { ids: column(steamNodes, "id", Number), pressure_kPa: pressure, temperature_C: temperature, not_unique_hours: {} },
    pipes: { ids: column(pipes, "id", Number), flow_kg_s: flow, loss_kW: loss, flow_not_unique_hours: flowMarks },
    loads: { ids: column(loads, "id", Number), shed_MW: loadShed, excess_MW: loadExcess },
    ...(id === "plant_derate" ? { priority_comparison: {
      note: "Mock note.",
      cases: [compareCase("Priority weights by building type", { lab: 2, classroom: 8 }), compareCase("Uniform priority weight", { lab: 5, classroom: 5 })],
      deeper_derate: { title: "One boiler running", description: "Mock stress case.", rating_MW: ratingMW / boilers, hours: 9, first_hour_of_synthetic_year: 939,
        cases: [compareCase("Priority weights by building type", { lab: 90, classroom: 120, housing: 60, critical: 1 }), compareCase("Uniform priority weight", { lab: 80, classroom: 90, housing: 70, critical: 31 })] },
    } } : {}),
    ...(id === "pipe_out" ? { reroute: { pipe_out: OUT_PIPE, first_hour: 49, last_hour: 96, reference_scenario: "baseline", reversed_steam_pipes: [{ pipe: 4, hours: 48 }, { pipe: 8, hours: 48 }], largest_flow_changes: [] } } : {}),
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
  "scenarios/network.json", ...Object.keys(definitions).map((id) => `scenarios/${id}.json`),
  "calibration.json", "benchmarks.json", "build_info.json", "tag_template.csv",
] }));

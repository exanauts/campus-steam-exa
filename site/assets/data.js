// Loads generated files from data/ and maps them to the shapes the page draws.
// A missing or malformed file yields null, and the section shows its missing-data state.
const BASE = "data/";
let manifest = null;

export async function loadManifest() {
  try {
    const response = await fetch(BASE + "files.json", { cache: "no-store" });
    if (!response.ok) return;
    const body = await response.json();
    if (Array.isArray(body.files)) manifest = new Set(body.files);
  } catch { /* Without a manifest each file is requested directly. */ }
}

export const listed = (name) => manifest === null || manifest.has(name);
export const dataUrl = (name) => BASE + name;

export async function loadJSON(name) {
  if (!listed(name)) return null;
  try {
    const response = await fetch(BASE + name, { cache: "no-store" });
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
}

const isNumArray = (a) => Array.isArray(a) && a.length > 0 && a.every((v) => v === null || Number.isFinite(v));

export function normalizeCampus(raw) {
  if (!raw || !Array.isArray(raw.junctions) || !Array.isArray(raw.pipes) || !Array.isArray(raw.loads) || !raw.plant) return null;
  const junctions = new Map(raw.junctions.map((j) => [j.id, j]));
  const pipes = raw.pipes.filter((p) => junctions.has(p.from) && junctions.has(p.to));
  const loads = raw.loads.filter((l) => junctions.has(l.junction));
  if (!pipes.length || !loads.length || !junctions.has(raw.plant.junction)) return null;
  return { junctions, pipes, loads, plant: raw.plant };
}

export function normalizeScenario(raw) {
  if (!raw || !isNumArray(raw.plant?.output_W) || !isNumArray(raw.plant?.rating_W)) return null;
  const hours = raw.plant.output_W.length;
  const matrixOk = (m) => Array.isArray(m) && m.length === hours && m.every(Array.isArray);
  if (!raw.pipes || !raw.loads) return null;
  if (!matrixOk(raw.pipes.temp_C) || !matrixOk(raw.pipes.flow_kg_s)) return null;
  if (!matrixOk(raw.loads.demand_W) || !matrixOk(raw.loads.served_W)) return null;
  return {
    id: raw.id, label: raw.label, hours,
    outdoor: isNumArray(raw.outdoor_temp_C) ? raw.outdoor_temp_C : null,
    output: raw.plant.output_W, rating: raw.plant.rating_W,
    pipeIds: raw.pipes.ids, temp: raw.pipes.temp_C, flow: raw.pipes.flow_kg_s,
    inService: matrixOk(raw.pipes.in_service) ? raw.pipes.in_service : null,
    nonUnique: matrixOk(raw.pipes.flow_nonunique) ? raw.pipes.flow_nonunique : null,
    heatLoss: isNumArray(raw.pipes.heat_loss_W) ? raw.pipes.heat_loss_W : null,
    loadIds: raw.loads.ids, demand: raw.loads.demand_W, served: raw.loads.served_W,
  };
}

export function normalizeBenchmarks(raw) {
  if (!raw || !Array.isArray(raw.runs) || !raw.runs.length) return null;
  const runs = raw.runs.filter((r) => Number.isFinite(r.size) && Number.isFinite(r.solve_s) && (r.device === "cpu" || r.device === "gpu"));
  return runs.length ? { runs, sizeLabel: raw.size_label || "Variables", notes: raw.notes || null } : null;
}

export function normalizeCalibration(raw) {
  if (!raw) return null;
  const chart = raw.chart;
  const seriesOk = chart && Array.isArray(chart.series) && chart.series.length > 0
    && chart.series.every((s) => isNumArray(s.x) && isNumArray(s.y) && s.x.length === s.y.length);
  return {
    finding: typeof raw.finding === "string" ? raw.finding : null,
    chart: seriesOk ? chart : null,
    ask: raw.ask || null,
    sample: Array.isArray(raw.sample_rows) ? raw.sample_rows : null,
  };
}

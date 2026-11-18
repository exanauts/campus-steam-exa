// Loads generated files from data/ and maps them to the shapes the page draws.
// A missing or malformed file yields null, and the section shows its missing-data state.
// The scenario format is documented in docs/site-data.md.
const BASE = "data/";
export const SCENARIO_DIR = "scenarios/";
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

// Turns a group of parallel arrays into one object per element.
function rows(group, keys) {
  if (!group || !keys.every((k) => Array.isArray(group[k]))) return null;
  const n = group[keys[0]].length;
  if (!n || !keys.every((k) => group[k].length === n)) return null;
  return Array.from({ length: n }, (_, i) => Object.fromEntries(keys.map((k) => [k, group[k][i]])));
}

// Only the steam side is kept: water-side flows and losses are labeled not_unique.
export function normalizeNetwork(raw) {
  if (!raw) return null;
  const junctions = rows(raw.junctions, ["id", "side", "kind", "x_m", "y_m"]);
  const pipes = rows(raw.pipes, ["id", "side", "from", "to"]);
  const loads = rows(raw.loads, ["id", "name", "type", "steam_junction", "design_heat_MW"]);
  const plant = raw.plant;
  if (!junctions || !pipes || !loads || !plant || !Number.isFinite(plant.rating_MW)) return null;
  const steam = new Map(junctions.filter((j) => j.side === "steam").map((j) => [j.id, { id: j.id, kind: j.kind, x: j.x_m, y: j.y_m }]));
  const steamPipes = pipes.filter((p) => p.side === "steam" && steam.has(p.from) && steam.has(p.to));
  const steamLoads = loads.filter((l) => steam.has(l.steam_junction)).map((l) => ({ ...l, junction: l.steam_junction }));
  if (!steamPipes.length || !steamLoads.length || !steam.has(plant.steam_junction)) return null;
  return {
    junctions: steam, pipes: steamPipes, loads: steamLoads,
    plant: { ...plant, junction: plant.steam_junction },
    dataLabel: raw.data_label || null, modelLabel: raw.model_label || null,
  };
}

// Expands { "id": [[first, last], ...] } with hours counted from 1 into one flag per hour.
function hourMarks(marks, hours) {
  const out = new Map();
  for (const [id, ranges] of Object.entries(marks || {})) {
    const flags = new Uint8Array(hours);
    for (const [first, last] of ranges) flags.fill(1, Math.max(0, first - 1), Math.min(hours, last));
    out.set(Number(id), flags);
  }
  return out;
}

const trusted = (label) => typeof label === "string" && label.startsWith("unique");

export function normalizeScenario(raw, network) {
  if (!raw || !network) return null;
  const base = { id: raw.scenario, title: raw.title, description: raw.description, events: raw.events || [], dataLabel: raw.data_label || null, modelLabel: raw.model_label || null };
  if (raw.presented !== true) return { ...base, presented: false, status: raw.solver?.status || "unknown" };

  const hours = raw.hours;
  const { plant, nodes, pipes, loads, summary } = raw;
  const series = ["output_MW", "rating_MW", "demand_MW", "shed_MW", "losses_MW"];
  if (!Number.isInteger(hours) || !plant || !summary || !series.every((k) => isNumArray(plant[k]) && plant[k].length === hours)) return null;
  const matrixOk = (m) => Array.isArray(m) && m.length === hours && m.every(Array.isArray);
  if (!matrixOk(nodes?.temperature_C) || !matrixOk(pipes?.flow_kg_s) || !matrixOk(loads?.shed_MW)) return null;

  const pipeColumn = new Map(pipes.ids.map((id, i) => [id, i]));
  const steamPipes = network.pipes.filter((p) => pipeColumn.has(p.id));
  const columns = steamPipes.map((p) => pipeColumn.get(p.id));
  const uniqueness = raw.uniqueness || {};
  return {
    ...base, presented: true, hours, summary,
    output: plant.output_MW, rating: plant.rating_MW, demand: plant.demand_MW, shed: plant.shed_MW,
    pipes: steamPipes,
    flow: pipes.flow_kg_s.map((row) => columns.map((c) => row[c])),
    flowMarks: hourMarks(pipes.flow_not_unique_hours, hours),
    nodeColumn: new Map(nodes.ids.map((id, i) => [id, i])),
    temperature: nodes.temperature_C,
    nodeMarks: hourMarks(nodes.not_unique_hours, hours),
    // A quantity without a "unique" label in the file is never drawn as a result.
    flowTrusted: trusted(uniqueness.steam_pipe_flow),
    temperatureTrusted: trusted(uniqueness.steam_temperature),
    loadIds: loads.ids, loadShed: loads.shed_MW,
    comparison: raw.priority_comparison || null,
    reroute: raw.reroute || null,
  };
}

export function normalizeBenchmarks(raw) {
  if (!raw || !Array.isArray(raw.runs) || !raw.runs.length) return null;
  const runs = raw.runs.filter((r) => Number.isFinite(r.size) && Number.isFinite(r.solve_s) && (r.device === "cpu" || r.device === "gpu"));
  return runs.length ? { runs, sizeLabel: raw.size_label || "Variables", notes: raw.notes || null, crossover: raw.crossover || null } : null;
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

import { loadManifest, loadJSON, listed, dataUrl, normalizeCampus, normalizeBenchmarks, normalizeCalibration } from "./data.js";
import { el, missing, compact, num } from "./format.js";
import { lineChart } from "./charts.js";
import { initHero } from "./hero.js";

const $ = (id) => document.getElementById(id);
const REPO = "https://github.com/exanauts/campus-steam-exa";

async function guarded(container, what, fn) {
  try {
    await fn();
  } catch (error) {
    console.warn(`Section failed to render: ${what}`, error);
    if (container) missing(container, ` ${what}`);
  }
}

function renderFooter(info) {
  if (!info) return;
  if (typeof info.commit_sha === "string" && /^[0-9a-f]{40}$/.test(info.commit_sha)) {
    const link = el("a", { href: `${REPO}/commit/${info.commit_sha}` });
    el("code", {}, link, info.commit_sha.slice(0, 12));
    $("commit").replaceChildren(link);
  }
  if (info.run_date) $("run-date").textContent = info.run_date;
  const hardware = [info.cpu_model, info.gpu_model].filter(Boolean).join(" / ");
  if (hardware) $("hardware").textContent = hardware;
}

function renderCalibration(cal) {
  const host = $("calibration");
  if (!cal || !cal.chart) return missing(host, " The calibration study has not been generated yet.");
  host.replaceChildren();
  if (cal.finding) el("p", { class: "lead" }, host, cal.finding);
  const colors = ["var(--s1)", "var(--s2)"];
  const c = cal.chart;
  lineChart(el("div", { class: "charts" }, host), {
    title: c.title || "Calibration result", subtitle: c.subtitle, xLabel: c.x_label, yLabel: c.y_label,
    xScale: c.x_scale, yScale: c.y_scale,
    series: c.series.map((s, i) => ({ name: s.name, color: colors[i % colors.length], points: s.x.map((x, k) => ({ x, y: s.y[k] })) })),
  });
}

function renderAsk(cal) {
  const host = $("ask-figures");
  const ask = cal?.ask;
  const items = ask ? [
    ["Curated tags", ask.tag_count, (v) => `about ${num(v)}`],
    ["History", ask.years, (v) => `about ${num(v)} years`],
    ["Rows", ask.rows, (v) => `about ${num(v)}`],
    ["File size", ask.size_label, (v) => v],
  ].filter(([, v]) => v !== undefined && v !== null) : [];
  host.replaceChildren();
  if (!items.length) {
    el("p", { class: "note" }, host, "Export size figures are not available in this build.");
    return;
  }
  const dl = el("dl", { class: "stats" }, host);
  items.forEach(([k, v, f]) => { const d = el("div", {}, dl); el("dt", {}, d, k); el("dd", {}, d, f(v)); });
}

function renderSample(cal) {
  const body = $("sample-body");
  const rows = cal?.sample?.length ? cal.sample : null;
  const layout = [
    { DateTime: "timestamp", TagName: "STEAM_HEADER_FLOW", Value: "reading", Quality: "Good" },
    { DateTime: "timestamp", TagName: "STEAM_HEADER_FLOW", Value: "reading", Quality: "Bad" },
    { DateTime: "timestamp", TagName: "STEAM_HEADER_TEMP", Value: "reading", Quality: "Good" },
  ];
  body.replaceChildren();
  (rows || layout).forEach((r) => {
    const good = String(r.Quality).toLowerCase() === "good";
    const tr = el("tr", { class: good ? null : "bad" }, body);
    [r.DateTime, r.TagName, r.Value, r.Quality].forEach((v) => el("td", {}, tr, String(v)));
    el("td", {}, tr, good ? "Yes" : "Excluded");
  });
  $("sample-note").textContent = rows ? "Synthetic example rows." : "Layout only. Sample values are not available in this build.";
}

function renderTemplate() {
  const slot = $("template-slot");
  if (listed("tag_template.csv")) {
    el("a", { class: "download", href: dataUrl("tag_template.csv"), download: "tag_template.csv" }, slot, "Download the tag-list template (CSV)");
  } else {
    slot.textContent = "The tag-list template is not available in this build.";
  }
}

// A crossover needs both devices at full tolerance at the same size, with the GPU ahead from there on.
function compareDevices(runs) {
  const solved = (r) => r.status === "solved";
  const sizes = [...new Set(runs.map((r) => r.size))].sort((a, b) => a - b);
  const pairs = sizes
    .map((size) => ({ size, cpu: runs.find((r) => r.size === size && r.device === "cpu"), gpu: runs.find((r) => r.size === size && r.device === "gpu") }))
    .filter((p) => p.cpu && p.gpu);
  const strict = pairs.filter((p) => solved(p.cpu) && solved(p.gpu));
  let crossover = null;
  for (let i = strict.length - 1; i >= 0 && strict[i].gpu.solve_s < strict[i].cpu.solve_s; i--) crossover = strict[i].size;
  const looseWins = pairs.filter((p) => solved(p.cpu) && !solved(p.gpu) && p.gpu.solve_s < p.cpu.solve_s);
  return { strict, crossover, looseWins };
}

function renderBenchmarks(bench) {
  const host = $("benchmarks");
  if (!bench) return missing(host, " The CPU and GPU measurements have not been generated yet.");
  host.replaceChildren();
  const { runs, sizeLabel } = bench;
  const { strict, crossover, looseWins } = compareDevices(runs);
  const lead = el("p", { class: "lead" }, host);
  const cpuWins = strict.filter((p) => p.cpu.solve_s <= p.gpu.solve_s).length;
  if (crossover !== null) lead.textContent = `The GPU was faster from ${compact(crossover)} ${sizeLabel.toLowerCase()} upward in these measurements, with both devices at full tolerance.`;
  else if (strict.length === 1) lead.textContent = `No crossover was measured. Both devices reached full tolerance at only one size, and the ${cpuWins ? "CPU" : "GPU"} was faster there.`;
  else if (strict.length) lead.textContent = `No crossover was measured. The CPU was faster at ${cpuWins} of the ${strict.length} sizes where both devices reached full tolerance.`;
  else lead.textContent = "No crossover can be stated, because the two devices did not both reach full tolerance at any common size.";
  if (looseWins.length) {
    const many = looseWins.length > 1;
    el("p", {}, host, `At ${looseWins.length} further size${many ? "s" : ""} the GPU finished sooner but stopped at a looser tolerance, so ${many ? "those runs are" : "that run is"} not counted as faster.`);
  }
  const device = (d, name, color, value) => ({
    name, color,
    points: runs.filter((r) => r.device === d && Number.isFinite(value(r))).map((r) => ({
      x: r.size, y: value(r), hollow: r.status !== "solved", note: r.status !== "solved" ? "looser tolerance" : null,
    })),
  });
  const grid = el("div", { class: "charts two" }, host);
  const chart = (title, yLabel, value, marker) => lineChart(grid, {
    title, xLabel: sizeLabel, yLabel, xScale: "log", yScale: "log", marker,
    series: [device("cpu", "CPU", "var(--s1)", value), device("gpu", "GPU", "var(--s2)", value)].filter((s) => s.points.length),
  });
  chart("Solve time", "Seconds", (r) => r.solve_s, crossover !== null ? { x: crossover, label: "Measured crossover" } : null);
  if (runs.some((r) => Number.isFinite(r.iterations))) chart("Solver iterations", "Iterations", (r) => r.iterations, null);
  if (bench.notes) el("p", { class: "note" }, host, bench.notes);
}

async function main() {
  await loadManifest();
  renderTemplate();
  const [info, calRaw, benchRaw, campusRaw, index] = await Promise.all([
    loadJSON("build_info.json"), loadJSON("calibration.json"), loadJSON("benchmarks.json"), loadJSON("campus.json"), loadJSON("scenarios.json"),
  ]);
  renderFooter(info);
  const cal = normalizeCalibration(calRaw);
  await guarded($("calibration"), "The calibration result could not be drawn.", () => renderCalibration(cal));
  await guarded($("ask-figures"), "The export figures could not be read.", () => renderAsk(cal));
  await guarded(null, "sample", () => renderSample(cal));
  await guarded($("benchmarks"), "The measurements could not be drawn.", () => renderBenchmarks(normalizeBenchmarks(benchRaw)));
  await guarded($("map"), "The campus playback could not be drawn.", () => initHero(normalizeCampus(campusRaw), index));
}

main();

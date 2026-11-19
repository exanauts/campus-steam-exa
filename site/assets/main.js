import { loadManifest, loadJSON, listed, dataUrl, normalizeNetwork, normalizeBenchmarks, SCENARIO_DIR } from "./data.js";
import { el, missing, compact } from "./format.js";
import { lineChart } from "./charts.js";
import { initHero } from "./hero.js";
import { normalizeCalibration, renderCalibration, renderAsk, renderSample } from "./calibration.js";

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

// The junction count is read from the network file that the map draws.
function renderCampusSize(network) {
  const count = network?.junctions?.id?.length;
  if (Number.isInteger(count)) $("campus-size").textContent = `The map shows the ${count}-junction campus that all four scenarios run on. That count includes the steam and return sides.`;
}

function renderTemplate() {
  const slot = $("template-slot");
  if (listed("tag_template.csv")) {
    el("a", { class: "download", href: dataUrl("tag_template.csv"), download: "tag_template.csv" }, slot, "Download the tag-list template (CSV)");
  } else {
    slot.textContent = "The tag-list template is not available in this build.";
  }
}

// Sizes where both devices have a point, split by whether the two points can be compared fairly.
function compareDevices(runs) {
  const solved = (r) => r.status === "solved";
  const sizes = [...new Set(runs.map((r) => r.size))].sort((a, b) => a - b);
  const pairs = sizes
    .map((size) => ({ size, cpu: runs.find((r) => r.size === size && r.device === "cpu"), gpu: runs.find((r) => r.size === size && r.device === "gpu") }))
    .filter((p) => p.cpu && p.gpu);
  const strict = pairs.filter((p) => solved(p.cpu) && solved(p.gpu));
  const notCounted = pairs.filter((p) => solved(p.cpu) && !solved(p.gpu) && p.gpu.solve_s < p.cpu.solve_s);
  return { strict, notCounted };
}

const times = (limit) => (limit === 2 ? "twice" : `${limit} times`);

// Why a point is hollow, read from that point's own repeats and residuals.
// `labels` are short and shared by the legend. `note` carries the counts of this point.
function pointReason(r) {
  if (r.status === "solved") return { labels: [], note: null };
  const unsolved = r.repeats - r.solved_repeats;
  const over = r.device === "gpu" && Number.isFinite(r.residual_ratio) && r.residual_ratio > r.residual_limit;
  const labels = [], notes = [];
  if (unsolved > 0) {
    labels.push("A repeat did not solve");
    notes.push(`median of the ${r.solved_repeats} solved repeat${r.solved_repeats === 1 ? "" : "s"}, leaving out ${unsolved} of ${r.repeats} that did not solve`);
  }
  if (over) {
    labels.push(`GPU reported success, but its residual was more than ${times(r.residual_limit)} the CPU's`);
    notes.push(unsolved > 0
      ? `the largest GPU residual was also more than ${times(r.residual_limit)} the CPU's`
      : `every repeat reported success, but the largest GPU residual was more than ${times(r.residual_limit)} the CPU's`);
  }
  if (!labels.length) {
    labels.push("Residuals could not be compared with the CPU");
    notes.push("its residual could not be compared with the CPU's");
  }
  return { labels, note: notes.join("; ") };
}

// The verdict comes from the crossover stated in the benchmark file, which is computed from the same runs.
function crossoverFindings(runs, reported) {
  const families = [["network_size", "network sizes"], ["horizon", "time horizons"]];
  return families.flatMap(([key, label]) => {
    const run = reported?.[key] ? runs.find((r) => r.case === reported[key]) : null;
    if (!run) return [];
    const larger = runs.some((r) => r.family === key && r.size > run.size);
    return [{ size: run.size, label, larger }];
  });
}

function renderBenchmarks(bench) {
  const host = $("benchmarks");
  if (!bench) return missing(host, " The CPU and GPU measurements have not been generated yet.");
  host.replaceChildren();
  const { runs, sizeLabel } = bench;
  const { strict, notCounted } = compareDevices(runs);
  const unit = sizeLabel.toLowerCase();
  const found = crossoverFindings(runs, bench.crossover);
  const lead = el("p", { class: "lead" }, host);
  const cpuWins = strict.filter((p) => p.cpu.solve_s <= p.gpu.solve_s).length;
  const fair = "every repeat solved and comparable residuals";
  if (found.length) {
    lead.textContent = found.map((c) => (c.larger
      ? `The GPU was faster from ${compact(c.size)} ${unit} upward among the ${c.label} in this build, with ${fair}.`
      : `The GPU was faster only at the largest of the ${c.label} in this build, ${compact(c.size)} ${unit}, with ${fair}. No larger size was run.`)).join(" ");
  } else if (strict.length === 1) lead.textContent = `No crossover was measured in this build. Only one size had ${fair} on both devices, and the ${cpuWins ? "CPU" : "GPU"} was faster there.`;
  else if (strict.length) lead.textContent = `No crossover was measured in this build. The CPU was faster at ${cpuWins} of the ${strict.length} sizes with ${fair} on both devices.`;
  else lead.textContent = `No crossover can be stated, because no size in this build had ${fair} on both devices.`;
  const repeats = Math.max(...runs.map((r) => r.repeats));
  const sizes = new Set(runs.map((r) => r.size)).size;
  el("p", {}, host, `These results come only from the solves run by this build: ${sizes} problem sizes, with up to ${repeats} repeats on each device.`);
  if (bench.skipped) el("p", {}, host, `${bench.skipped} planned solve${bench.skipped > 1 ? "s were" : " was"} not run, because this build reached its time limit.`);
  notCounted.forEach((p) => el("p", {}, host, `At ${compact(p.size)} ${unit} the GPU's median time was lower, but it is not counted as faster: ${pointReason(p.gpu).note}.`));
  bench.unsolved.forEach((r) => el("p", {}, host, `At ${compact(r.size)} ${unit} the ${r.device.toUpperCase()} solved none of its ${r.repeats} repeats, so no point is drawn for it.`));
  const device = (d, name, color, value) => ({
    name, color,
    points: runs.filter((r) => r.device === d && Number.isFinite(value(r))).map((r) => {
      const reason = pointReason(r);
      return { x: r.size, y: value(r), hollow: r.status !== "solved", hollowLabels: reason.labels, note: reason.note };
    }),
  });
  const missingText = (name, size) => (bench.unsolved.some((r) => r.size === size && r.device === name.toLowerCase()) ? "no repeat solved" : "not run");
  const grid = el("div", { class: "charts two" }, host);
  const chart = (title, yLabel, value, marker) => lineChart(grid, {
    title, xLabel: sizeLabel, yLabel, xScale: "log", yScale: "log", marker, missingText,
    series: [device("cpu", "CPU", "var(--s1)", value), device("gpu", "GPU", "var(--s2)", value)].filter((s) => s.points.length),
  });
  chart("Solve time", "Seconds", (r) => r.solve_s, found.length ? { x: found[0].size, label: "Measured crossover" } : null);
  if (runs.some((r) => Number.isFinite(r.iterations))) chart("Solver iterations", "Iterations", (r) => r.iterations, null);
  if (bench.notes) el("p", { class: "note" }, host, bench.notes);
}

async function main() {
  await loadManifest();
  renderTemplate();
  const [info, calRaw, benchRaw, networkRaw] = await Promise.all([
    loadJSON("build_info.json"), loadJSON("calibration.json"), loadJSON("benchmarks.json"), loadJSON(`${SCENARIO_DIR}network.json`),
  ]);
  renderFooter(info);
  renderCampusSize(networkRaw);
  const cal = normalizeCalibration(calRaw);
  await guarded($("calibration"), "The calibration result could not be drawn.", () => renderCalibration($("calibration"), cal));
  await guarded($("ask-figures"), "The export figures could not be read.", () => renderAsk($("ask-figures"), cal));
  await guarded(null, "sample", () => renderSample($("sample-body"), $("sample-note"), cal));
  await guarded($("benchmarks"), "The measurements could not be drawn.", () => renderBenchmarks(normalizeBenchmarks(benchRaw)));
  await guarded($("map"), "The campus playback could not be drawn.", () => initHero(normalizeNetwork(networkRaw)));
}

main();

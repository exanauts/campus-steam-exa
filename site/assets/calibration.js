// "What the data buys": reads calibration.json (docs/site-data.md, "Calibration").
// Fields the page does not use are ignored, so the file can grow without changing this module.
import { el, missing, num } from "./format.js";
import { lineChart } from "./charts.js";

// The chart holds the length of record fixed. The table shows the largest tag set at each length.
const CHART_MONTHS = 1;
const TABLE_TAGS = 25;

// All wording of the section is here, so it can be revised without touching the drawing code.
const TEXT = {
  intro: "What the data buys is pipe heat-loss and friction values fitted to the plant, so that scenarios reflect that network. The test below shows how closely those values can be estimated from hourly readings. It uses a simulated campus and simulated historian-style CSV readings, not data from a real plant.",
  definition: "Recovery error is how far the estimated pipe heat-loss and friction values are from the known true values in the simulated campus. A smaller number means a closer estimate. This test measures only that accuracy. It does not measure savings or any other benefit.",
  leadFalling: (first, last) => `With one month of data, more tags reduce the recovery error: the largest error falls from ${first.label} with ${first.tags} tags to ${last.label} with ${last.tags} tags.`,
  leadMixed: (first, last) => `With one month of data, the largest recovery error is ${first.label} with ${first.tags} tags and ${last.label} with ${last.tags} tags.`,
  chartTitle: "Largest recovery error against number of tags, with one month of data",
  chartNote: "Every point on this chart uses one month of data. The table below shows longer records with 25 tags.",
  monthsTitle: "Largest recovery error with 25 tags, by months of data",
  monthsCaption: "Largest recovery error with 25 tags for each length of record in this build",
  monthsHead: ["Months of data", "Largest recovery error"],
  notRun: "Not run",
  notConverged: "Did not converge",
  seasonCompared: (s) => `Accuracy depends on which season the data covers. With ${s.tags} tags and one month of data, the largest recovery error was ${s.first.label} for ${s.first.window} (${s.first.where}) and ${s.second.label} for ${s.second.window} (${s.second.where}).`,
  seasonMissing: (s) => `Accuracy can depend on which season the data covers. With ${s.tags} tags, the largest recovery error for ${s.first.window} was ${s.first.label}. The same fit for ${s.second.window} has no result in this build: ${s.second.outcome}.`,
  noChart: " The calibration study has not produced a converged result in this build.",
  noFigures: "Export size figures are not available in this build.",
  figuresNote: "Measured on the synthetic export used in this demonstration.",
  quality: (h) => `In that file ${h.good_percent}% of tag-hours are usable Good readings. ${num(h.excluded_bad)} Bad and ${num(h.excluded_uncertain)} Uncertain readings are excluded, and ${num(h.absent)} tag-hours have no reading. Nothing is filled in.`,
  sampleLayout: "Layout only. Sample values are not available in this build.",
  sampleSynthetic: "Synthetic example rows.",
  sampleExcluded: (e, bad) => `Synthetic readings from ${e.tag}, in ${e.unit}. The Bad reading of ${bad.value.toFixed(1)} ${e.unit} is excluded: the mean of these readings is ${e.mean_after_exclusion.toFixed(1)} ${e.unit} without it and would be ${e.mean_with_bad_sample.toFixed(1)} ${e.unit} with it.`,
};

const percent = (v) => `${v.toFixed(1)}%`;

// The largest recovery error of each seasonal window, as computed by the build.
function seasonalWindows(check) {
  const windows = Array.isArray(check?.windows) ? check.windows : [];
  if (check?.run !== true || windows.length < 2 || !Number.isFinite(windows[0].max_error_percent)) return null;
  const describe = (w) => ({
    window: w.label,
    label: Number.isFinite(w.max_error_percent) ? percent(w.max_error_percent) : null,
    where: `${w.max_error_group}, ${w.max_error_coefficient === "loss" ? "heat loss" : "friction"}`,
    outcome: w.converged === true ? "no error was recorded" : `the solver stopped with status ${w.solver_status}`,
  });
  return { tags: check.tags, first: describe(windows[0]), second: describe(windows[1]) };
}

export function normalizeCalibration(raw) {
  if (!raw) return null;
  const cells = Array.isArray(raw.grid?.cells) ? raw.grid.cells : [];
  const points = cells
    .filter((c) => c.months === CHART_MONTHS && c.converged === true && Number.isFinite(c.tags) && Number.isFinite(c.max_error_percent))
    .map((c) => ({ tags: c.tags, error: c.max_error_percent, label: percent(c.max_error_percent) }))
    .sort((a, b) => a.tags - b.tags);
  const months = cells.filter((c) => c.tags === TABLE_TAGS && Number.isFinite(c.months))
    .sort((a, b) => a.months - b.months)
    .map((c) => ({
      months: c.months,
      result: c.run !== true ? TEXT.notRun
        : c.converged === true && Number.isFinite(c.max_error_percent) ? percent(c.max_error_percent) : TEXT.notConverged,
    }));
  return {
    points, months, seasonal: seasonalWindows(raw.seasonal_check),
    findings: Array.isArray(raw.findings) ? raw.findings.filter((f) => typeof f === "string") : [],
    subtitle: raw.chart?.subtitle || null, xLabel: raw.chart?.x_label || "Tags used", yLabel: raw.chart?.y_label || "Largest recovery error (%)",
    ask: raw.ask || null, historian: raw.historian || null,
    example: raw.bad_quality_example || null,
    sampleRows: Array.isArray(raw.sample_rows) ? raw.sample_rows : null,
  };
}

export function renderCalibration(host, cal) {
  if (!cal || cal.points.length < 2) return missing(host, TEXT.noChart);
  host.replaceChildren();
  const first = cal.points[0], last = cal.points[cal.points.length - 1];
  const falling = cal.points.every((p, i) => i === 0 || p.error < cal.points[i - 1].error);
  el("p", {}, host, TEXT.intro);
  el("p", {}, host, TEXT.definition);
  el("p", { class: "lead" }, host, falling ? TEXT.leadFalling(first, last) : TEXT.leadMixed(first, last));
  if (cal.seasonal) el("p", { class: "lead" }, host, cal.seasonal.second.label ? TEXT.seasonCompared(cal.seasonal) : TEXT.seasonMissing(cal.seasonal));
  lineChart(el("div", { class: "charts" }, host), {
    title: TEXT.chartTitle, subtitle: cal.subtitle, xLabel: cal.xLabel, yLabel: cal.yLabel, yScale: "log",
    labelEnds: (p) => percent(p.y), yFormat: (v) => `${+v.toPrecision(3)}`,
    series: [{ name: "Largest recovery error (%)", color: "var(--s1)", points: cal.points.map((p) => ({ x: p.tags, y: p.error })) }],
  });
  el("p", { class: "note" }, host, TEXT.chartNote);
  if (cal.months.length) {
    el("h3", {}, host, TEXT.monthsTitle);
    const wrap = el("div", { class: "table-scroll months-table", tabindex: "0", role: "region", "aria-label": TEXT.monthsTitle }, host);
    const table = el("table", {}, wrap);
    el("caption", { class: "sr-only" }, table, TEXT.monthsCaption);
    const head = el("tr", {}, el("thead", {}, table));
    TEXT.monthsHead.forEach((h) => el("th", { scope: "col" }, head, h));
    const body = el("tbody", {}, table);
    cal.months.forEach((m) => {
      const tr = el("tr", {}, body);
      el("th", { scope: "row" }, tr, String(m.months));
      el("td", {}, tr, m.result);
    });
  }
  const scope = el("ul", { class: "scope" }, host);
  cal.findings.forEach((f) => el("li", {}, scope, f));
}

export function renderAsk(host, cal) {
  const ask = cal?.ask;
  const items = ask ? [
    ["Curated tags", ask.tag_count, (v) => num(v)],
    ["History", ask.years, (v) => `${num(v)} years`],
    ["Rows", ask.rows, (v) => num(v)],
    ["File size", ask.size_label, (v) => v],
  ].filter(([, v]) => v !== undefined && v !== null) : [];
  host.replaceChildren();
  if (!items.length) {
    el("p", { class: "note" }, host, TEXT.noFigures);
    return;
  }
  const dl = el("dl", { class: "stats" }, host);
  items.forEach(([k, v, f]) => { const d = el("div", {}, dl); el("dt", {}, d, k); el("dd", {}, d, f(v)); });
  el("p", { class: "note" }, host, TEXT.figuresNote);
  const h = cal.historian;
  if (h && [h.good_percent, h.excluded_bad, h.excluded_uncertain, h.absent].every(Number.isFinite)) el("p", { class: "note" }, host, TEXT.quality(h));
}

const LAYOUT_ROWS = [
  { DateTime: "timestamp", TagName: "STEAM_HEADER_FLOW", Value: "reading", Quality: "Good" },
  { DateTime: "timestamp", TagName: "STEAM_HEADER_FLOW", Value: "reading", Quality: "Bad" },
  { DateTime: "timestamp", TagName: "STEAM_HEADER_TEMP", Value: "reading", Quality: "Good" },
];

export function renderSample(body, note, cal) {
  const example = cal?.example;
  const samples = Array.isArray(example?.samples) && example.samples.length ? example.samples : null;
  const rows = samples
    ? samples.map((s) => ({ DateTime: s.time, TagName: example.tag, Value: s.value, Quality: s.quality, used: s.used === true }))
    : (cal?.sampleRows?.length ? cal.sampleRows : LAYOUT_ROWS).map((r) => ({ ...r, used: String(r.Quality).toLowerCase() === "good" }));
  body.replaceChildren();
  rows.forEach((r) => {
    const tr = el("tr", { class: r.used ? null : "bad" }, body);
    [r.DateTime, r.TagName, r.Value, r.Quality].forEach((v) => el("td", {}, tr, String(v)));
    el("td", {}, tr, r.used ? "Yes" : "Excluded");
  });
  const bad = samples?.filter((s) => s.used !== true) ?? [];
  const means = Number.isFinite(example?.mean_after_exclusion) && Number.isFinite(example?.mean_with_bad_sample);
  if (bad.length === 1 && means && Number.isFinite(bad[0].value)) note.textContent = TEXT.sampleExcluded(example, bad[0]);
  else note.textContent = samples || cal?.sampleRows?.length ? TEXT.sampleSynthetic : TEXT.sampleLayout;
}

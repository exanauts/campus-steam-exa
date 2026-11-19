import { el, num, hourLabel, missing, dataTable, showTip, hideTip } from "./format.js";
import { loadJSON, listed, normalizeScenario, SCENARIO_DIR } from "./data.js";

const HOURS_PER_SECOND = 6;
// Shed load below this size, in MW or MWh, is solver residue rather than a result.
const SHED_MIN = 0.01;
const DEFAULT_TITLE = "How a campus steam network carries a hard week";
// The scenario shown first, when it is in the build.
const FIRST_SCENARIO = "cold_snap";
// Fixed temperature color scale, so that colors compare across scenarios. About nine tenths of the
// steam temperatures in the four scenarios fall inside this range. Anything outside is drawn in the
// end color, and the key says so.
const COLOR_SCALE_C = [105, 125];
// Marker outline for each building type, drawn around the origin with half-size r.
const SHAPES = {
  critical: (r) => `M0 ${-1.3 * r}L${1.3 * r} 0L0 ${1.3 * r}L${-1.3 * r} 0Z`,
  lab: (r) => `M${-r} ${-r}H${r}V${r}H${-r}Z`,
  classroom: (r) => `M0 ${-1.2 * r}L${1.2 * r} ${0.95 * r}H${-1.2 * r}Z`,
  housing: (r) => `M${-1.1 * r} 0a${1.1 * r} ${1.1 * r} 0 1 0 ${2.2 * r} 0a${1.1 * r} ${1.1 * r} 0 1 0 ${-2.2 * r} 0Z`,
};
const shapeOf = (type) => SHAPES[type] || SHAPES.lab;
const TYPE_NAMES = { critical: "Critical", lab: "Labs", classroom: "Classrooms", housing: "Housing" };
const TYPE_ORDER = ["critical", "lab", "classroom", "housing"];

const reduceMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (id) => document.getElementById(id);
const sum = (a) => a.reduce((x, y) => x + y, 0);
const fixed = (v, digits = 1) => v.toFixed(digits);
const typeName = (t) => TYPE_NAMES[t] || t;
const fileOf = (id) => `${SCENARIO_DIR}${id}.json`;

// Shed is reported by building type: the split between buildings of one type is not unique.
function scenarioFacts(s, network) {
  const typeOfLoad = new Map(network.loads.map((l) => [l.id, l.type]));
  const types = TYPE_ORDER.filter((t) => network.loads.some((l) => l.type === t));
  const shedByHour = s.loadShed.map((row) => {
    const byType = Object.fromEntries(types.map((t) => [t, 0]));
    row.forEach((v, j) => { const t = typeOfLoad.get(s.loadIds[j]); if (t in byType) byType[t] += v; });
    return byType;
  });
  const weekByType = Object.fromEntries(types.map((t) => [t, sum(shedByHour.map((h) => h[t]))]));
  const designByType = Object.fromEntries(types.map((t) => [t, sum(network.loads.filter((l) => l.type === t).map((l) => l.design_heat_MW))]));
  const shedHours = s.shed.filter((v) => v >= SHED_MIN).length;
  const worstHour = s.shed.indexOf(Math.max(...s.shed));
  const peakHour = s.output.indexOf(Math.max(...s.output));
  return { types, shedByHour, weekByType, designByType, shedHours, worstHour, peakHour };
}

function shedByTypeText(f) {
  const parts = f.types.filter((t) => t !== "critical" && f.weekByType[t] >= SHED_MIN)
    .sort((a, b) => f.weekByType[b] - f.weekByType[a])
    .map((t) => `${typeName(t).toLowerCase()} ${fixed(f.weekByType[t])} MWh`);
  return parts.join(", ");
}

function findingText(s, f, network) {
  const total = s.summary.total_shed_MWh;
  const shed = total >= SHED_MIN;
  const peak = `output peaks at ${fixed(s.output[f.peakHour])} MW of ${fixed(s.rating[f.peakHour])} MW available`;
  const critical = s.summary.critical_shed_MWh >= SHED_MIN ? `${fixed(s.summary.critical_shed_MWh)} MWh of critical load is shed` : "no critical load is shed";
  const weights = s.comparison ? " with the priority weights by building type" : "";
  const outcome = shed
    ? `${fixed(total)} MWh goes unserved (${shedByTypeText(f)})${weights}, and ${critical}.`
    : `The plant carries it: ${peak}, and no load is shed.`;
  const event = s.events[0];
  const span = event ? event.last_hour - event.first_hour + 1 : 0;
  if (s.id === "cold_snap" && event) {
    return `Cold snap: loads run ${Math.round((event.factor - 1) * 100)} percent higher for ${span} hours, with a ${event.shoulder_hours}-hour ramp on each side. ${outcome}`;
  }
  if (s.id === "plant_derate" && event) {
    return `One of ${network.plant.n_boilers} boilers out for ${span} hours leaves ${fixed(event.rating_MW)} MW available. ${outcome}`;
  }
  if (s.id === "pipe_out" && event) {
    const reversed = s.reroute?.reversed_steam_pipes?.length;
    const reroute = reversed ? ` Flow reverses in ${reversed} other steam pipe${reversed > 1 ? "s" : ""} to reroute around it.` : "";
    return `Steam main pipe ${event.pipe} out for ${span} hours. ${outcome}${reroute}`;
  }
  return `${s.title}: ${shed ? outcome : `the plant carries the week, ${peak}, and no load is shed.`}`;
}

function typeTable(host, caption, types, cases) {
  const scroll = el("div", { class: "table-scroll", tabindex: "0", role: "region", "aria-label": caption }, host);
  const table = el("table", {}, scroll);
  el("caption", { class: "sr-only" }, table, caption);
  const head = el("tr", {}, el("thead", {}, table));
  el("th", { scope: "col" }, head, "Shed by building type (MWh)");
  cases.forEach((c) => el("th", { scope: "col" }, head, c.label));
  const body = el("tbody", {}, table);
  types.forEach((t) => {
    const tr = el("tr", {}, body);
    el("th", { scope: "row" }, tr, typeName(t));
    cases.forEach((c) => el("td", {}, tr, fixed(c.shed_by_type_MWh[t] ?? 0, 2)));
  });
}

const usable = (cases) => Array.isArray(cases) && cases.length >= 2 && cases.every((c) => c.presented && c.shed_by_type_MWh);

// The weights change how shed load is shared, so each statement is drawn from the two solves.
function renderComparison(host, s, f) {
  const cmp = s.comparison;
  if (!cmp) return;
  const box = el("div", { class: "evidence" }, host);
  el("h2", { class: "evidence-title" }, box, "What the priority weights change with one boiler out");
  if (usable(cmp.cases)) {
    const [weighted, uniform] = cmp.cases;
    const noCritical = cmp.cases.every((c) => (c.shed_by_type_MWh.critical ?? 0) < SHED_MIN);
    const moved = f.types.filter((t) => Math.abs((weighted.shed_by_type_MWh[t] ?? 0) - (uniform.shed_by_type_MWh[t] ?? 0)) >= SHED_MIN).map((t) => typeName(t).toLowerCase());
    const text = noCritical
      ? `No critical load is shed under either weighting, so this case does not show the weights protecting critical load.${moved.length ? ` The weights only shift shedding between ${moved.join(" and ")}.` : ""}`
      : "Critical load is shed in this case. Compare the two weightings below.";
    el("p", {}, box, text);
    typeTable(box, "Shed by building type with one boiler out, under two weightings", f.types, cmp.cases);
  } else {
    el("p", {}, box, "This comparison did not reach the solver tolerance, so its results are withheld.");
  }
  if (cmp.note) el("p", { class: "note" }, box, cmp.note);

  const stress = cmp.deeper_derate;
  if (!stress) return;
  const card = el("div", { class: "stress" }, box);
  el("span", { class: "tag" }, card, "Stress case");
  el("h3", {}, card, `${stress.title}: ${fixed(stress.rating_MW)} MW for ${stress.hours} peak hours`);
  el("p", {}, card, "This is a separate, harsher case and not one of the four scenarios above.");
  if (usable(stress.cases)) {
    const [weighted, uniform] = stress.cases;
    const a = weighted.shed_by_type_MWh.critical ?? 0, b = uniform.shed_by_type_MWh.critical ?? 0;
    const text = a < b - SHED_MIN
      ? `Here the weights protect critical load: ${fixed(a, 2)} MWh of critical load is shed with weights by building type, against ${fixed(b, 2)} MWh with one uniform weight.`
      : `Critical load shed is ${fixed(a, 2)} MWh with weights by building type and ${fixed(b, 2)} MWh with one uniform weight.`;
    el("p", {}, card, text);
    typeTable(card, "Shed by building type in the stress case, under two weightings", f.types, stress.cases);
  } else {
    el("p", {}, card, "This stress case did not reach the solver tolerance, so its results are withheld.");
  }
}

export async function initHero(network) {
  const map = $("map");
  const radios = [...document.querySelectorAll('input[name="scenario"]')];
  radios.forEach((r) => {
    r.disabled = !network || !listed(fileOf(r.value));
    if (r.disabled) r.closest("label").title = "Not available in this build";
  });
  const enabled = radios.filter((r) => !r.disabled);
  if (!enabled.length) {
    missing(map, " The campus playback has not been generated yet.");
    return;
  }
  const first = enabled.find((r) => r.value === FIRST_SCENARIO) || enabled[0];
  first.checked = true;

  const view = buildMap(map, network);
  const panel = $("panel"), transport = $("transport"), scrubber = $("scrubber"), play = $("play");
  map.closest(".stage").classList.add("has-panel");
  $("map-key").hidden = false;
  // Building types in the order the optimizer protects them: the larger the weight, the later it is shed.
  const weightOf = (t) => network.loads.find((l) => l.type === t && Number.isFinite(l.priority_weight))?.priority_weight;
  const keyTypes = TYPE_ORDER.filter((t) => network.loads.some((l) => l.type === t));
  const ranked = keyTypes.every((t) => weightOf(t) !== undefined);
  if (ranked) keyTypes.sort((a, b) => weightOf(b) - weightOf(a));
  buildKey($("map-key"), keyTypes, ranked ? weightOf : null);
  const ui = buildPanel(panel, network);

  const cache = new Map();
  const state = { s: null, f: null, hour: 0, playing: false, visible: true, token: 0 };
  let cursor = null, cursorX = () => 0;

  const fetchScenario = (id) => {
    if (!cache.has(id)) cache.set(id, loadJSON(fileOf(id)).then((raw) => normalizeScenario(raw, network)));
    return cache.get(id);
  };

  function render(announce) {
    const { s, f, hour } = state;
    view.update(s, f, hour);
    ui.update(s, f, hour);
    scrubber.value = hour;
    const shed = s.shed[hour] >= SHED_MIN ? s.shed[hour] : 0;
    const text = `${hourLabel(hour)}: plant output ${fixed(s.output[hour])} MW, demand ${fixed(s.demand[hour])} MW, shed ${fixed(shed)} MW.`;
    scrubber.setAttribute("aria-valuetext", text);
    if (cursor) { cursor.setAttribute("x1", cursorX(hour)); cursor.setAttribute("x2", cursorX(hour)); }
    if (announce) $("hero-live").textContent = text;
  }

  function drawStrip() {
    const { s } = state;
    const host = $("strip");
    host.replaceChildren();
    const W = Math.max(200, host.clientWidth - 22), H = 42;
    const top = Math.max(network.plant.rating_MW, ...s.rating, ...s.output);
    const sx = (h) => (s.hours > 1 ? (h / (s.hours - 1)) * W : 0);
    const sy = (v) => H - 3 - (v / top) * (H - 6);
    const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" }, host);
    s.events.forEach((e) => el("rect", { x: sx(e.first_hour - 1), y: 0, width: sx(e.last_hour - 1) - sx(e.first_hour - 1), height: H, fill: "var(--ink)", opacity: 0.07 }, svg));
    s.shed.forEach((v, h) => {
      if (v >= SHED_MIN) el("rect", { x: sx(h) - W / s.hours / 2, y: 0, width: Math.max(1.5, W / s.hours), height: H, fill: "var(--shed)", opacity: 0.3 }, svg);
    });
    const path = (a) => a.map((v, h) => `${h ? "L" : "M"}${sx(h).toFixed(1)} ${sy(v).toFixed(1)}`).join("");
    el("path", { d: path(s.rating), fill: "none", stroke: "var(--ink-3)", "stroke-width": 1 }, svg);
    el("path", { d: path(s.output), fill: "none", stroke: "var(--s1)", "stroke-width": 2 }, svg);
    cursor = el("line", { y1: 0, y2: H, stroke: "var(--ink)", "stroke-width": 1 }, svg);
    cursorX = sx;
    const days = $("strip-days");
    days.replaceChildren();
    for (let d = 0; d < Math.ceil(s.hours / 24); d++) {
      const label = el("span", {}, days);
      el("span", { class: "word" }, label, "Day ");
      label.append(String(d + 1));
    }
  }

  function renderTables() {
    const { s, f } = state;
    const host = $("hero-tables");
    host.replaceChildren();
    const rows = [];
    for (let d = 0; d < Math.ceil(s.hours / 24); d++) {
      const range = [...Array(s.hours).keys()].filter((h) => Math.floor(h / 24) === d);
      rows.push([`Day ${d + 1}`, fixed(Math.max(...range.map((h) => s.demand[h]))), fixed(Math.max(...range.map((h) => s.output[h]))),
        fixed(Math.min(...range.map((h) => s.rating[h]))), fixed(sum(range.map((h) => s.shed[h])))]);
    }
    dataTable(host, "Day-by-day values for this scenario", ["Day", "Peak demand (MW)", "Peak output (MW)", "Lowest available (MW)", "Shed (MWh)"], rows);
    dataTable(host, "Week totals for this scenario", ["Quantity", "Value"], [
      ["Demand", `${num(s.summary.total_demand_MWh)} MWh`],
      ["Shed", `${fixed(s.summary.total_shed_MWh)} MWh`],
      ...f.types.map((t) => [`Shed, ${typeName(t).toLowerCase()}`, `${fixed(f.weekByType[t])} MWh`]),
      ["Heat lost in pipes (indicative)", `about ${num(s.summary.total_losses_MWh)} MWh`],
    ]);
    renderComparison(host, s, f);
  }

  function showLabels(s) {
    const labels = [s.dataLabel, s.modelLabel].filter(Boolean).join(" ");
    const node = $("hero-labels");
    node.hidden = !labels;
    node.textContent = labels;
  }

  let timer = null;
  function setPlaying(on) {
    state.playing = on;
    play.textContent = on ? "Pause" : "Play";
    play.setAttribute("aria-pressed", String(on));
    clearInterval(timer);
    timer = null;
    if (on) {
      timer = setInterval(() => {
        if (!state.s || !state.visible || document.hidden) return;
        state.hour = (state.hour + 1) % state.s.hours;
        render(false);
      }, 1000 / HOURS_PER_SECOND);
    } else if (state.s) {
      render(true);
    }
  }

  function withhold(message, s) {
    setPlaying(false);
    state.s = null;
    view.setVisible(false);
    missing(view.notice, message);
    view.notice.hidden = false;
    $("hero-title").textContent = s?.title || DEFAULT_TITLE;
    $("hero-sub").hidden = true;
    panel.hidden = true;
    transport.hidden = true;
    $("map-key").hidden = true;
    $("hero-tables").replaceChildren();
  }

  async function select(id) {
    const token = ++state.token;
    const s = await fetchScenario(id);
    if (token !== state.token) return;
    if (!s) return withhold(" This scenario could not be loaded.");
    showLabels(s);
    if (!s.presented) return withhold(` The solver stopped with status ${s.status}, so the numbers for this scenario are withheld.`, s);
    view.notice.hidden = true;
    view.setVisible(true);
    panel.hidden = false;
    transport.hidden = false;
    $("map-key").hidden = false;
    state.s = s;
    state.f = scenarioFacts(s, network);
    view.prepare(s);
    scrubber.max = s.hours - 1;
    state.hour = Math.min(state.hour, s.hours - 1);
    $("hero-title").textContent = findingText(s, state.f, network);
    const sub = $("hero-sub");
    sub.hidden = !s.description;
    sub.textContent = s.description || "";
    drawStrip();
    renderTables();
    render(true);
  }

  play.addEventListener("click", () => setPlaying(!state.playing));
  scrubber.addEventListener("input", () => {
    state.hour = +scrubber.value;
    setPlaying(false);
  });
  radios.forEach((r) => r.addEventListener("change", () => { if (r.checked) select(r.value); }));
  // Playback pauses only when the whole hero is off screen, so the controls always respond.
  new IntersectionObserver(([e]) => { state.visible = e.isIntersecting; }).observe($("hero"));
  let lastWidth = map.clientWidth;
  new ResizeObserver(() => {
    if (Math.abs(map.clientWidth - lastWidth) < 4) return;
    lastWidth = map.clientWidth;
    view.resize();
    if (state.s) { drawStrip(); render(false); }
  }).observe(map);

  await select(first.value);
  if (state.s && !reduceMotion()) setPlaying(true);
}

function buildMap(host, network) {
  host.replaceChildren();
  const pts = [...network.junctions.values()];
  const xs = pts.map((j) => j.x), ys = pts.map((j) => j.y);
  const pad = 46;
  // The plant label sits under the plant, which is on the south edge, so the bottom margin is wider.
  const bottomPad = pad + 54;
  const x0 = Math.min(...xs) - pad, y1 = Math.max(...ys) + pad;
  const vw = Math.max(...xs) - x0 + pad, vh = y1 - Math.min(...ys) + bottomPad;
  const px = (j) => j.x - x0, py = (j) => y1 - j.y;
  const svg = el("svg", {
    viewBox: `0 0 ${vw} ${vh}`, role: "img",
    "aria-label": "Map of the fictional campus steam network. Pipes are colored by steam temperature, from the hot plant end to the cooler far ends, and drawn wider for larger flows. Lightly loaded pipes are faded. Buildings are marked by type with a shape and a color, sized by design heat, and empty out when their type is short of heat. The status panel and the tables below give the values as text.",
  }, host);
  const notice = el("div", { hidden: "" }, host);
  const defs = el("defs", {}, svg);
  const pipeLayer = el("g", {}, svg), hitLayer = el("g", {}, svg), markLayer = el("g", {}, svg), bldgLayer = el("g", {}, svg);
  // Each pipe has its own gradient, so its color runs from the temperature at one end to the other.
  const pipes = new Map(network.pipes.map((p) => {
    const a = network.junctions.get(p.from), b = network.junctions.get(p.to);
    const ends = { x1: px(a), y1: py(a), x2: px(b), y2: py(b) };
    const gradient = el("linearGradient", { id: `pipe-heat-${p.id}`, gradientUnits: "userSpaceOnUse", ...ends }, defs);
    const stops = [el("stop", { offset: 0 }, gradient), el("stop", { offset: 1 }, gradient)];
    const node = el("line", { class: "pipe", ...ends, "stroke-width": 1.5 }, pipeLayer);
    el("line", { class: "pipe-hit", ...ends, "data-pipe": p.id }, hitLayer);
    return [p.id, { node, stops, from: p.from, to: p.to, mx: (px(a) + px(b)) / 2, my: (py(a) + py(b)) / 2, mark: null, info: null }];
  }));
  // The filled part of a marker is clipped from the top by the share of that type's load not served.
  const clips = new Map(TYPE_ORDER.map((t) => {
    const clip = el("clipPath", { id: `served-${t}`, clipPathUnits: "objectBoundingBox" }, defs);
    return [t, el("rect", { x: 0, y: 0, width: 1, height: 1 }, clip)];
  }));
  const heats = network.loads.map((l) => l.design_heat_MW).filter(Number.isFinite);
  const heatLow = Math.min(...heats), heatSpan = Math.max(1e-9, Math.max(...heats) - heatLow);
  const loads = new Map(network.loads.map((l) => {
    const j = network.junctions.get(l.junction);
    const g = el("g", { "data-load": l.id, transform: `translate(${px(j)} ${py(j)})` }, bldgLayer);
    const type = l.type in SHAPES ? l.type : "lab";
    const fill = el("path", { class: `bldg-fill t-${type}` }, g);
    if (clips.has(l.type)) fill.setAttribute("clip-path", `url(#served-${l.type})`);
    return [l.id, {
      load: l, fill,
      // Marker area grows with design heat.
      scale: 0.75 + 0.75 * Math.sqrt(Number.isFinite(l.design_heat_MW) ? (l.design_heat_MW - heatLow) / heatSpan : 0),
      outline: el("path", { class: `bldg-outline t-${type}` }, g),
    }];
  }));
  const pj = network.junctions.get(network.plant.junction);
  const plantMark = el("rect", { class: "plant" }, svg);
  const plantText = el("text", { "text-anchor": "middle" }, svg, "Plant");

  let unit = 1, size = 10, current = null, facts = null, hourNow = 0, maxFlow = 1;
  const typeInfo = new Map();

  function drawOutMarks() {
    markLayer.replaceChildren();
    pipes.forEach((p) => {
      const d = 7 * unit;
      p.mark = el("path", { class: "out-mark", visibility: "hidden", d: `M${p.mx - d} ${p.my - d}L${p.mx + d} ${p.my + d}M${p.mx - d} ${p.my + d}L${p.mx + d} ${p.my - d}` }, markLayer);
    });
  }

  function resize() {
    const width = host.clientWidth || 600;
    // The drawing is letterboxed when its height is capped, so measure the scale it renders at.
    const box = svg.getBoundingClientRect();
    const scale = Math.min(box.width / vw, box.height / vh);
    unit = scale > 0 ? 1 / scale : vw / Math.max(240, width);
    size = Math.max(9, Math.min(13, width / 55)) * unit;
    loads.forEach((v) => {
      const d = shapeOf(v.load.type)((size / 2) * v.scale);
      v.fill.setAttribute("d", d); v.outline.setAttribute("d", d);
    });
    const s = size * 1.7;
    plantMark.setAttribute("x", px(pj) - s / 2); plantMark.setAttribute("y", py(pj) - s / 2);
    plantMark.setAttribute("width", s); plantMark.setAttribute("height", s);
    plantText.setAttribute("x", px(pj)); plantText.setAttribute("y", py(pj) + s / 2 + 15 * unit);
    plantText.setAttribute("font-size", 13 * unit); plantText.setAttribute("stroke-width", 3 * unit);
    drawOutMarks();
    if (current) update(current, facts, hourNow);
  }

  const readRamp = () => {
    const styles = getComputedStyle(document.documentElement);
    return ["--hot-0", "--hot-1", "--hot-2", "--hot-3"].map((name) => {
      const h = styles.getPropertyValue(name).trim().slice(1);
      return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
    });
  };
  let ramp = readRamp();
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    ramp = readRamp();
    if (current) update(current, facts, hourNow);
  });
  const [tMin, tMax] = COLOR_SCALE_C;
  const color = (t) => {
    const u = Math.max(0, Math.min(1, (t - tMin) / (tMax - tMin))) * (ramp.length - 1);
    const i = Math.min(ramp.length - 2, Math.floor(u)), a = ramp[i], b = ramp[i + 1];
    return `rgb(${a.map((c, k) => Math.round(c + (b[k] - c) * (u - i))).join(" ")})`;
  };

  // Temperature at the pipe's two ends. An end marked as not unique in this hour takes the other end's value.
  function pipeTemperature(s, p, h) {
    const ends = [p.from, p.to].map((id) => {
      const t = s.nodeMarks.get(id)?.[h] ? NaN : s.temperature[h][s.nodeColumn.get(id)];
      return Number.isFinite(t) ? t : null;
    });
    if (ends[0] === null && ends[1] === null) return null;
    return [ends[0] ?? ends[1], ends[1] ?? ends[0]];
  }

  function prepare(s) {
    current = s;
    maxFlow = 1e-9;
    s.flow.forEach((row, h) => row.forEach((v, i) => {
      if (v !== null && !s.flowMarks.get(s.pipes[i].id)?.[h]) maxFlow = Math.max(maxFlow, Math.abs(v));
    }));
  }

  function update(s, f, h) {
    facts = f;
    hourNow = h;
    s.pipes.forEach((pipe, i) => {
      const p = pipes.get(pipe.id);
      if (!p) return;
      const flow = s.flow[h][i];
      const out = flow === null;
      p.mark?.setAttribute("visibility", out ? "visible" : "hidden");
      p.node.classList.toggle("out", out);
      const temperature = out ? null : pipeTemperature(s, p, h);
      const faded = !out && (!s.flowTrusted || !s.temperatureTrusted || s.flowMarks.get(pipe.id)?.[h] || temperature === null);
      p.node.classList.toggle("faded", !!faded);
      p.info = { id: pipe.id, out, faded: !!faded, flow, temperature };
      if (out || faded) {
        p.node.style.stroke = "";
        p.node.setAttribute("stroke-width", out ? 2 : 1.25);
        return;
      }
      p.stops.forEach((stop, k) => stop.setAttribute("stop-color", color(temperature[k])));
      p.node.style.stroke = `url(#pipe-heat-${pipe.id})`;
      p.node.setAttribute("stroke-width", (1.5 + 6 * Math.sqrt(Math.abs(flow) / maxFlow)).toFixed(1));
    });
    f.types.forEach((t) => {
      const mw = f.shedByHour[h][t];
      const info = { mw, frac: Math.min(1, mw / f.designByType[t]) };
      typeInfo.set(t, info);
      // A small shortfall still empties a visible slice of the marker.
      const empty = mw >= SHED_MIN ? Math.max(0.2, info.frac) : 0;
      const rect = clips.get(t);
      if (rect) { rect.setAttribute("y", empty); rect.setAttribute("height", 1 - empty); }
    });
    loads.forEach((v) => v.outline.classList.toggle("short", (typeInfo.get(v.load.type)?.mw ?? 0) >= SHED_MIN));
  }

  svg.addEventListener("pointermove", (e) => {
    const line = e.target.closest?.("[data-pipe]");
    const pipe = line && pipes.get(+line.dataset.pipe)?.info;
    if (pipe) {
      return showTip(e.clientX, e.clientY, (t) => {
        el("b", {}, t, `Steam pipe ${pipe.id}`);
        if (pipe.out) return el("div", {}, t, "Out of service this hour");
        if (pipe.faded) return el("div", {}, t, "Lightly loaded this hour. Its flow and temperature are not unique, so no value is shown.");
        const [hot, cool] = [...pipe.temperature].sort((a, b) => b - a);
        el("div", {}, t, hot - cool >= 0.05 ? `Steam cools from ${fixed(hot)} C to ${fixed(cool)} C along it` : `Steam at ${fixed(hot)} C`);
        el("div", {}, t, `Flow ${fixed(Math.abs(pipe.flow))} kg/s`);
      });
    }
    const g = e.target.closest?.("[data-load]");
    if (!g) return hideTip();
    const v = loads.get(+g.dataset.load), info = v && typeInfo.get(v.load.type);
    if (!v || !info) return;
    showTip(e.clientX, e.clientY, (t) => {
      el("b", {}, t, v.load.name);
      if (Number.isFinite(v.load.design_heat_MW)) el("div", {}, t, `${typeName(v.load.type)}, design heat ${fixed(v.load.design_heat_MW)} MW`);
      el("div", {}, t, info.mw >= SHED_MIN ? `${typeName(v.load.type)} combined: ${fixed(info.mw)} MW shed this hour` : `${typeName(v.load.type)}: no load shed this hour`);
    });
  });
  svg.addEventListener("pointerleave", hideTip);
  resize();
  return { notice, prepare, update, resize, setVisible: (on) => { svg.style.display = on ? "" : "none"; } };
}

function buildKey(host, types, weightOf) {
  host.replaceChildren();
  const marker = (parent, type, short) => {
    const svg = el("svg", { class: "key-mark map", viewBox: "-8 -8 16 16", "aria-hidden": "true" }, parent);
    const d = shapeOf(type)(5);
    if (!short) el("path", { class: `bldg-fill t-${type}`, d }, svg);
    el("path", { class: `bldg-outline t-${type}${short ? " short" : ""}`, d }, svg);
  };
  const pipesRow = el("div", { class: "key-row" }, host);
  const a = el("span", {}, pipesRow);
  a.append(`Steam temperature: ${COLOR_SCALE_C[0]} C or cooler`);
  el("i", { class: "ramp" }, a);
  a.append(`${COLOR_SCALE_C[1]} C or hotter`);
  el("span", {}, pipesRow, "Wider line: more flow");
  const f = el("span", {}, pipesRow); el("i", { class: "line-key faded" }, f); f.append("Faded: lightly loaded this hour, not a prediction");
  const d = el("span", {}, pipesRow); el("i", { class: "line-key" }, d); d.append("Pipe out of service");
  const bldgRow = el("div", { class: "key-row" }, host);
  if (weightOf) el("span", { class: "key-lead" }, bldgRow, "Priority for heat, highest first:");
  types.forEach((t, i) => {
    const item = el("span", {}, bldgRow);
    marker(item, t, false);
    item.append(weightOf ? `${i + 1}. ${typeName(t)} (weight ${num(weightOf(t))})` : typeName(t));
  });
  const noteRow = el("div", { class: "key-row" }, host);
  if (weightOf) el("span", {}, noteRow, "When heat is short, the lowest priority is shed first");
  el("span", {}, noteRow, "Larger marker: larger design heat");
  if (types.length) { const e = el("span", {}, noteRow); marker(e, types[types.length - 1], true); e.append("Emptying marker: that building type is short of heat"); }
}

function buildPanel(host, network) {
  host.replaceChildren();
  const nameplate = network.plant.rating_MW;
  const head = el("div", { class: "gauge-head" }, host);
  el("span", {}, head, "Plant output");
  const pct = el("span", {}, head);
  const value = el("div", { class: "gauge-value" }, host);
  const meter = el("div", { class: "meter" }, host);
  const fill = el("i", { class: "fill" }, meter), off = el("i", { class: "off" }, meter);
  const foot = el("div", { class: "gauge-foot" }, host);
  const dl = el("dl", { class: "readout" }, host);
  const row = (k) => { el("dt", {}, dl, k); return el("dd", {}, dl); };
  const when = row("Time"), demand = row("Demand"), shed = row("Shed"), supply = row("Steam leaving plant"), coolest = row("Coolest steam on network"), losses = row("Pipe loss, week");
  const list = el("p", { class: "shed-now" }, host);
  return {
    update(s, f, hour) {
      const out = s.output[hour], avail = s.rating[hour];
      value.replaceChildren(`${fixed(out)} `);
      el("small", {}, value, "MW");
      pct.textContent = `${Math.round((100 * out) / avail)}% of available`;
      fill.style.width = `${Math.min(100, (100 * out) / nameplate)}%`;
      off.style.width = `${Math.max(0, 100 * (1 - avail / nameplate))}%`;
      foot.textContent = avail < nameplate
        ? `${fixed(avail)} MW available, derated from the ${fixed(nameplate)} MW rating`
        : `${fixed(avail)} MW available, the full rating`;
      when.textContent = hourLabel(hour);
      demand.textContent = `${fixed(s.demand[hour])} MW`;
      shed.textContent = `${fixed(s.shed[hour] >= SHED_MIN ? s.shed[hour] : 0)} MW`;
      // Junctions marked as not unique in this hour are left out.
      const temps = s.temperatureTrusted ? [...s.nodeColumn].filter(([id]) => !s.nodeMarks.get(id)?.[hour]).map(([id, column]) => [id, s.temperature[hour][column]]).filter(([, t]) => Number.isFinite(t)) : [];
      const atPlant = temps.find(([id]) => id === network.plant.junction);
      supply.textContent = atPlant ? `${fixed(atPlant[1])} C` : "Not shown";
      coolest.textContent = temps.length ? `${fixed(Math.min(...temps.map(([, t]) => t)))} C` : "Not shown";
      losses.textContent = `about ${num(s.summary.total_losses_MWh)} MWh`;
      const short = f.types.filter((t) => f.shedByHour[hour][t] >= SHED_MIN).sort((a, b) => f.shedByHour[hour][b] - f.shedByHour[hour][a]);
      list.replaceChildren();
      if (!short.length) { list.append("All load served this hour."); return; }
      el("b", {}, list, "Short this hour: ");
      list.append(short.map((t) => `${typeName(t)} ${fixed(f.shedByHour[hour][t])} MW`).join(", "));
    },
  };
}

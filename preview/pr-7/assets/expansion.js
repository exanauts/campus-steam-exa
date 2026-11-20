// "Adding a building": reads expansion.json (docs/site-data.md, "New building study") and the
// network file of the scenarios. Every number in the section comes from those two files.
import { el, missing, num } from "./format.js";

// Undelivered heat below this size, in MWh, is solver residue rather than a result.
const SHED_MIN = 0.01;
const TYPE_ORDER = ["critical", "lab", "housing", "classroom"];
const TYPE_PLURAL = { critical: "critical buildings", lab: "labs", housing: "housing", classroom: "classrooms" };
const TYPE_SINGULAR = { critical: "critical building", lab: "lab", housing: "housing building", classroom: "classroom" };
// Marker outlines as in the campus map above.
const SHAPES = {
  critical: (r) => `M0 ${-1.3 * r}L${1.3 * r} 0L0 ${1.3 * r}L${-1.3 * r} 0Z`,
  lab: (r) => `M${-r} ${-r}H${r}V${r}H${-r}Z`,
  classroom: (r) => `M0 ${-1.2 * r}L${1.2 * r} ${0.95 * r}H${-1.2 * r}Z`,
  housing: (r) => `M${-1.1 * r} 0a${1.1 * r} ${1.1 * r} 0 1 0 ${2.2 * r} 0a${1.1 * r} ${1.1 * r} 0 1 0 ${-2.2 * r} 0Z`,
};
const shapeOf = (type) => SHAPES[type] || SHAPES.lab;

const fixed = (v, digits = 1) => (Math.abs(v) < 0.05 && digits === 1 ? "0" : v.toFixed(digits));
const mw = (v) => String(+v.toFixed(1));
const joinList = (items) => (items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`);
const isOk = (c) => c && c.converged === true && c.summary && c.shed_by_type_MWh;
const shedOf = (c) => (isOk(c) ? (c.summary.total_shed_MWh >= SHED_MIN ? c.summary.total_shed_MWh : 0) : null);

// "classrooms 5.6 MWh, housing 1.2 MWh", largest first, or null when nothing is undelivered.
function byTypeText(c) {
  const parts = TYPE_ORDER.filter((t) => (c.shed_by_type_MWh[t] ?? 0) >= SHED_MIN)
    .sort((a, b) => c.shed_by_type_MWh[b] - c.shed_by_type_MWh[a])
    .map((t) => `${TYPE_PLURAL[t]} ${fixed(c.shed_by_type_MWh[t])} MWh`);
  return parts.length ? parts.join(", ") : null;
}
const onlyType = (c) => {
  const types = TYPE_ORDER.filter((t) => (c.shed_by_type_MWh[t] ?? 0) >= SHED_MIN);
  return types.length === 1 ? types[0] : null;
};

function leadText(doc, by, building) {
  const today = by.get("today"), tomorrow = by.get("tomorrow");
  if (!isOk(today) || !isOk(tomorrow)) return "The comparison of today and tomorrow is incomplete in this build, because a solve did not converge. The table shows which.";
  const what = building ? `one new ${mw(building.design_heat_MW)} MW ${TYPE_SINGULAR[building.type] || building.type}` : "one new building";
  const todayText = shedOf(today) === 0
    ? `Today's network delivers all ${num(today.summary.total_demand_MWh)} MWh of heat in the coldest week of the synthetic year.`
    : `Today's network leaves ${fixed(shedOf(today))} MWh of heat undelivered in the coldest week of the synthetic year.`;
  if (shedOf(tomorrow) === 0) return `${todayText} With ${what}, it still delivers all of it.`;
  const single = onlyType(tomorrow);
  const where = single ? `, all of it in ${TYPE_PLURAL[single]}` : `: ${byTypeText(tomorrow)}`;
  return `${todayText} With ${what}, ${fixed(shedOf(tomorrow))} MWh goes undelivered over ${tomorrow.summary.hours_with_shed} hours${where}.`;
}

// One sentence on what each option changes, in the order of the file.
function optionsText(options) {
  const done = options.filter(isOk), failed = options.filter((c) => !isOk(c));
  const name = (c) => `the ${c.label.toLowerCase()}`;
  const clears = done.filter((c) => shedOf(c) === 0).map(name);
  const leaves = done.filter((c) => shedOf(c) > 0);
  const parts = [];
  if (clears.length) parts.push(`With ${joinList(clears)}, every building gets its heat.`);
  if (leaves.length) {
    const each = leaves.map((c, i) => `${i === 0 ? "With" : "with"} ${name(c)}, ${fixed(shedOf(c))} MWh`);
    parts.push(`${each.join("; ")} still ${leaves.length === 1 ? "goes" : "go"} undelivered.`);
  }
  if (failed.length) parts.push(`The solve with ${joinList(failed.map(name))} did not converge, so no result is shown for ${failed.length > 1 ? "them" : "it"}.`);
  return parts.join(" ");
}

// What changed in a case, in words, from the file.
function changeText(c, building) {
  const ch = c.changes || {};
  const parts = [];
  if (c.case === "today") return "Today's network. Nothing is added.";
  if (building) parts.push(`${building.name}, a new ${mw(building.design_heat_MW)} MW ${TYPE_SINGULAR[building.type] || building.type}, on a new lateral from junction ${building.tap}.`);
  if (ch.resized_pipes?.length) {
    const before = [...new Set(ch.resized_pipes.map((p) => p.diameter_before_m))].join(" and ");
    const after = [...new Set(ch.resized_pipes.map((p) => p.diameter_after_m))].join(" and ");
    parts.push(`Steam pipe${ch.resized_pipes.length > 1 ? "s" : ""} ${joinList(ch.resized_pipes.map((p) => p.id))}, the branch main toward the new building, enlarged from ${before} m to ${after} m, with the return main beside ${ch.resized_pipes.length > 1 ? "them" : "it"}.`);
  }
  if (ch.added_pipes?.length) ch.added_pipes.forEach((p) => parts.push(`A new ${p.diameter_m} m steam main, ${num(p.length_m)} m long, and its return, from junction ${p.from} to junction ${p.to}.`));
  if (ch.insulated_pipes?.length) parts.push(`Heat-loss coefficient multiplied by ${ch.insulation_factor} on ${ch.insulated_pipes.length} steam trunk pipes.`);
  if (Number.isFinite(ch.plant_rating_MW)) parts.push(`${ch.n_boilers} boilers, rating ${mw(ch.plant_rating_MW)} MW.`);
  return parts.join(" ");
}

const speedOf = (c) => (isOk(c) && Number.isFinite(c.steam_checks?.max_velocity_on_route_m_s) ? c.steam_checks.max_velocity_on_route_m_s : null);

// Steam speed is the one pipe concern the model does not limit, so it is stated separately.
function velocityText(by, options) {
  const tomorrow = by.get("tomorrow");
  const v = speedOf(tomorrow);
  if (v === null) return null;
  const ck = tomorrow.steam_checks;
  const design = ck.design_velocity_m_s;
  let text = `The model has no limit on steam speed, so speed never causes undelivered heat here. Tomorrow, the fastest steam on the route to the new building is about ${mw(v)} m/s, in pipe ${ck.fastest_pipe_on_route}`;
  text += Number.isFinite(design) ? `, against the ${mw(design)} m/s the campus pipes were sized for.` : ".";
  const pipeOptions = options.filter((c) => speedOf(c) !== null && (c.changes?.resized_pipes?.length || c.changes?.added_pipes?.length));
  if (pipeOptions.length) text += ` ${pipeOptions.map((c, i) => `${i === 0 ? "With" : "with"} the ${c.label.toLowerCase()} it is about ${mw(speedOf(c))} m/s`).join(", and ")}. That is what the pipe options change.`;
  return text;
}

function buildMap(host, network, building) {
  host.replaceChildren();
  const pts = [...network.junctions.values()];
  if (building) pts.push({ x: building.steam_junction.x_m, y: building.steam_junction.y_m });
  const xs = pts.map((j) => j.x), ys = pts.map((j) => j.y);
  const pad = 40, bottomPad = 90;
  const x0 = Math.min(...xs) - pad, y1 = Math.max(...ys) + pad;
  const vw = Math.max(...xs) - x0 + pad, vh = y1 - Math.min(...ys) + bottomPad;
  const at = (x, y) => [x - x0, y1 - y];
  const svg = el("svg", { viewBox: `0 0 ${vw} ${vh}`, role: "img", "aria-label": "Map of the steam supply side of the fictional campus. The pipes and buildings changed in the selected case are drawn heavier. The text beside the map lists the changes." }, host);
  const base = el("g", {}, svg), changed = el("g", {}, svg), marks = el("g", {}, svg), labels = el("g", {}, svg);
  const line = (layer, a, b, cls) => {
    const [ax, ay] = at(a.x, a.y), [bx, by] = at(b.x, b.y);
    return el("line", { class: cls, x1: ax, y1: ay, x2: bx, y2: by }, layer);
  };
  network.pipes.forEach((p) => line(base, network.junctions.get(p.from), network.junctions.get(p.to), "xp-pipe"));
  const pj = network.junctions.get(network.plant.junction);
  const state = { unit: 1, c: null };

  function draw() {
    const box = svg.getBoundingClientRect();
    state.unit = box.width > 0 ? vw / box.width : vw / 600;
    const u = state.unit, c = state.c;
    changed.replaceChildren(); marks.replaceChildren(); labels.replaceChildren();
    const r = 5 * u;
    network.loads.forEach((l) => {
      const j = network.junctions.get(l.junction);
      const [x, y] = at(j.x, j.y);
      el("path", { class: `xp-bldg t-${l.type in SHAPES ? l.type : "lab"}`, d: shapeOf(l.type)(r), transform: `translate(${x} ${y})` }, marks);
    });
    const s = 12 * u;
    const [px, py] = at(pj.x, pj.y);
    el("rect", { class: "xp-plant", x: px - s / 2, y: py - s / 2, width: s, height: s }, marks);
    const ch = c?.changes || {};
    const label = (x, y, text, anchor = "middle") => el("text", { x, y, "text-anchor": anchor, "font-size": 12 * u, "stroke-width": 3 * u }, labels, text);
    label(px, py + s / 2 + 15 * u, Number.isFinite(ch.plant_rating_MW) ? `Plant, ${ch.n_boilers} boilers` : "Plant");
    if (!c) return;
    (ch.insulated_pipes || []).forEach((id) => {
      const p = network.pipes.find((q) => q.id === id);
      if (p) line(changed, network.junctions.get(p.from), network.junctions.get(p.to), "xp-insulated");
    });
    (ch.resized_pipes || []).forEach((rp) => {
      const a = network.junctions.get(rp.from), b = network.junctions.get(rp.to);
      if (a && b) line(changed, a, b, "xp-upsized");
    });
    (ch.added_pipes || []).forEach((ap) => {
      const a = network.junctions.get(ap.from), b = network.junctions.get(ap.to);
      if (a && b) line(changed, a, b, "xp-added");
    });
    if (building && c.case !== "today") {
      const tap = network.junctions.get(building.tap);
      const site = { x: building.steam_junction.x_m, y: building.steam_junction.y_m };
      if (tap) line(changed, tap, site, "xp-added");
      const [x, y] = at(site.x, site.y);
      el("path", { class: `xp-new t-${building.type in SHAPES ? building.type : "lab"}`, d: shapeOf(building.type)(2.2 * r), transform: `translate(${x} ${y})` }, marks);
      // The label sits above the building, clear of its lateral, and inside the drawing.
      const half = 40 * u;
      label(Math.min(vw - half, Math.max(half, x)), y - 2.2 * r - 5 * u, `New: ${building.name}`);
    }
  }
  return {
    show(c) { state.c = c; draw(); },
    resize: draw,
  };
}

function barList(host, cases) {
  const values = cases.map(shedOf);
  const top = Math.max(SHED_MIN, ...values.filter((v) => v !== null));
  const list = el("div", { class: "xp-bars", role: "list", "aria-label": "Undelivered heat over the week, by case" }, host);
  cases.forEach((c, i) => {
    const row = el("div", { class: "xp-bar-row", role: "listitem" }, list);
    el("span", { class: "xp-bar-label" }, row, c.label);
    const track = el("span", { class: "xp-bar-track" }, row);
    const v = values[i];
    if (v === null) {
      el("span", { class: "xp-bar-value na-text" }, row, "Did not converge");
      return;
    }
    if (v > 0) el("i", { class: "xp-bar", style: `width:${Math.max(0.5, (100 * v) / top)}%` }, track);
    el("span", { class: "xp-bar-value" }, row, v > 0 ? `${fixed(v)} MWh` : "None");
  });
}

function caseTable(host, cases, onPick) {
  const scroll = el("div", { class: "table-scroll", tabindex: "0", role: "region", "aria-label": "Results by case" }, host);
  const table = el("table", { class: "xp-table" }, scroll);
  el("caption", { class: "sr-only" }, table, "Results of each case over the coldest week of the synthetic year");
  const head = el("tr", {}, el("thead", {}, table));
  ["Case", "Undelivered heat (MWh)", "Undelivered by building type", "Hours with undelivered heat", "Peak output / rating (MW)", "Heat lost in pipes (MWh, indicative)", "Fastest steam to the new building (m/s, indicative)"]
    .forEach((h) => el("th", { scope: "col" }, head, h));
  const body = el("tbody", {}, table);
  const rows = new Map();
  cases.forEach((c) => {
    const tr = el("tr", { "data-case": c.case }, body);
    const th = el("th", { scope: "row" }, tr);
    const pick = el("button", { type: "button", class: "linkish" }, th, c.label);
    pick.addEventListener("click", () => onPick(c.case));
    rows.set(c.case, tr);
    if (!isOk(c)) {
      el("td", { colspan: 6, class: "left" }, tr, `Did not converge (solver status ${c.status}). No result is shown.`);
      return;
    }
    const s = c.summary;
    el("td", {}, tr, shedOf(c) > 0 ? fixed(shedOf(c)) : "0");
    el("td", { class: "left" }, tr, byTypeText(c) || "None");
    el("td", {}, tr, String(s.hours_with_shed));
    el("td", {}, tr, `${mw(s.peak_output_MW)} / ${mw(c.plant_rating_MW)}`);
    el("td", {}, tr, `about ${num(s.total_losses_MWh)}`);
    el("td", {}, tr, speedOf(c) === null ? "" : `about ${Math.round(speedOf(c))}`);
  });
  return (id) => rows.forEach((tr, key) => tr.classList.toggle("picked", key === id));
}

export function renderExpansion(host, doc, network) {
  if (!doc || !Array.isArray(doc.cases) || !doc.cases.length) return missing(host, " The new-building study has not been generated in this build.");
  host.replaceChildren();
  const by = new Map(doc.cases.map((c) => [c.case, c]));
  const building = doc.cases.map((c) => c.changes?.new_building).find(Boolean) || null;
  const options = doc.cases.filter((c) => c.case !== "today" && c.case !== "tomorrow");

  el("p", { class: "lead" }, host, leadText(doc, by, building));
  const optText = optionsText(options);
  if (optText) el("p", { class: "prose" }, host, optText);
  if (doc.limit?.statement) el("p", { class: "prose" }, host, doc.limit.statement);

  const speed = velocityText(by, options);
  if (speed) el("p", { class: "prose" }, host, speed);

  // Case picker and map.
  const picker = el("fieldset", { class: "scenarios xp-picker" }, host);
  el("legend", {}, picker, "Case");
  const figure = el("div", { class: "xp-stage" }, host);
  const card = el("figure", { class: "map-card xp-map-card" }, figure);
  const mapHost = el("div", { class: "map xp-map" }, card);
  const side = el("div", { class: "xp-side" }, figure);
  const title = el("h3", { class: "xp-case-title" }, side);
  const what = el("p", { class: "xp-what" }, side);
  const result = el("p", { class: "xp-result" }, side);
  const key = el("div", { class: "map-key xp-key" }, side);
  const keyLine = (cls, text) => { const span = el("span", {}, key); el("i", { class: `xp-key-line ${cls}` }, span); span.append(text); };
  keyLine("xp-key-added", "New pipe or lateral");
  keyLine("xp-key-upsized", "Enlarged pipe");
  keyLine("xp-key-insulated", "Better insulated");

  let view = null;
  if (network) view = buildMap(mapHost, network, building);
  else missing(mapHost, " The campus network file is missing, so the map is not drawn.");

  const setRow = { fn: () => {} };
  const show = (id) => {
    const c = by.get(id);
    if (!c) return;
    picker.querySelectorAll("input").forEach((i) => { i.checked = i.value === id; });
    title.textContent = c.label;
    what.textContent = changeText(c, building);
    if (!isOk(c)) result.textContent = `This case did not converge (solver status ${c.status}), so no result is shown.`;
    else {
      const s = c.summary;
      const shed = shedOf(c) > 0 ? `${fixed(shedOf(c))} MWh undelivered over ${s.hours_with_shed} hours (${byTypeText(c)})` : "all heat delivered";
      result.textContent = `Result: ${shed}. Plant output peaks at ${mw(s.peak_output_MW)} of ${mw(c.plant_rating_MW)} MW.`;
    }
    if (view) view.show(c);
    setRow.fn(id);
  };
  doc.cases.forEach((c) => {
    const label = el("label", {}, picker);
    const input = el("input", { type: "radio", name: "xp-case", value: c.case }, label);
    el("span", {}, label, c.label);
    input.addEventListener("change", () => show(c.case));
  });

  el("h3", {}, host, "Undelivered heat over the week");
  barList(host, doc.cases);
  setRow.fn = caseTable(host, doc.cases, show);
  el("p", { class: "note" }, host, "Undelivered heat is heat a building asked for and did not get. It is reported by building type, because the split between buildings of one type is not unique. Heat lost in pipes is indicative and rounded to whole MWh. Steam speed is worked out from the steam flow, pressure and temperature in each pipe on the route; it is indicative because steam pressures are.");

  show(by.has("tomorrow") ? "tomorrow" : doc.cases[0].case);
  if (view) {
    let frame = 0;
    window.addEventListener("resize", () => { cancelAnimationFrame(frame); frame = requestAnimationFrame(view.resize); });
  }
}

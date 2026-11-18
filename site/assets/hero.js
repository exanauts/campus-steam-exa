import { el, MW, num, hourLabel, missing, dataTable, showTip, hideTip } from "./format.js";
import { loadJSON, listed, normalizeScenario } from "./data.js";

const HOURS_PER_SECOND = 6;
// Share of demand below which shed load is treated as solver noise.
const SHED_EPS = 1e-4;
// Pipes under this share of the week's largest flow are drawn at the minimum width,
// because flows in lightly loaded pipes are not unique at the optimum.
const LIGHT_FLOW_SHARE = 0.05;
const DEFAULT_TITLE = "How a campus steam network carries a hard week";

const reduceMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (id) => document.getElementById(id);
const sum = (a) => a.reduce((x, y) => x + y, 0);

function scenarioFacts(s) {
  const demandBy = s.demand.map(sum), servedBy = s.served.map(sum);
  const shedBy = demandBy.map((d, i) => Math.max(0, d - servedBy[i]));
  const significant = shedBy.map((v, i) => v > SHED_EPS * demandBy[i]);
  const worstHour = shedBy.indexOf(Math.max(...shedBy));
  const peakHour = s.output.indexOf(Math.max(...s.output));
  return {
    demandBy, shedBy, significant, worstHour,
    demandMWh: sum(demandBy) / 1e6,
    shedMWh: sum(shedBy.filter((_, i) => significant[i])) / 1e6,
    shedHours: significant.filter(Boolean).length,
    worstShed: shedBy[worstHour],
    peakOutput: s.output[peakHour], ratingAtPeak: s.rating[peakHour],
  };
}

function findingText(s, f, label) {
  if (f.shedHours === 0) {
    return `${label}: the plant carries the week. Output peaks at ${MW(f.peakOutput)} MW against ${MW(f.ratingAtPeak)} MW available, and no load is shed.`;
  }
  const pct = ((100 * f.shedMWh) / f.demandMWh).toFixed(1);
  return `${label}: the plant falls short for ${f.shedHours} of ${s.hours} hours. ${num(f.shedMWh)} MWh of demand goes unserved (${pct}%), and the deepest shortfall is ${MW(f.worstShed)} MW on ${hourLabel(f.worstHour)}.`;
}

export async function initHero(campus, index) {
  const map = $("map");
  const radios = [...document.querySelectorAll('input[name="scenario"]')];
  const labels = Object.fromEntries(radios.map((r) => [r.value, r.nextElementSibling.textContent]));
  const entry = (id) => index?.scenarios?.find((s) => s.id === id);
  const fileOf = (id) => entry(id)?.file || `scenario_${id}.json`;
  const available = (id) => !!campus && !!entry(id) && listed(fileOf(id));
  radios.forEach((r) => {
    r.disabled = !available(r.value);
    if (r.disabled) r.closest("label").title = "Not available in this build";
  });
  const first = radios.find((r) => !r.disabled);
  if (!first) {
    missing(map, " The campus playback has not been generated yet.");
    return;
  }
  first.checked = true;

  const view = buildMap(map, campus);
  const panel = $("panel"), transport = $("transport"), scrubber = $("scrubber"), play = $("play");
  map.closest(".stage").classList.add("has-panel");
  panel.hidden = false;
  transport.hidden = false;
  $("map-key").hidden = false;
  buildKey($("map-key"), campus);
  const ui = buildPanel(panel, campus);

  const cache = new Map();
  const state = { s: null, f: null, hour: 0, playing: false, visible: true, token: 0 };
  let cursor = null, cursorX = () => 0;

  const fetchScenario = (id) => {
    if (!cache.has(id)) cache.set(id, loadJSON(fileOf(id)).then(normalizeScenario));
    return cache.get(id);
  };

  function render(announce) {
    const { s, f, hour } = state;
    view.update(s, hour);
    const demand = f.demandBy[hour], shed = f.significant[hour] ? f.shedBy[hour] : 0;
    ui.update(s, hour, demand, shed);
    scrubber.value = hour;
    const text = `${hourLabel(hour)}: plant output ${MW(s.output[hour])} MW, demand ${MW(demand)} MW, shed ${MW(shed)} MW.`;
    scrubber.setAttribute("aria-valuetext", text);
    if (cursor) { cursor.setAttribute("x1", cursorX(hour)); cursor.setAttribute("x2", cursorX(hour)); }
    if (announce) $("hero-live").textContent = text;
  }

  function drawStrip() {
    const { s, f } = state;
    const host = $("strip");
    host.replaceChildren();
    const W = Math.max(200, host.clientWidth - 22), H = 42;
    const top = Math.max(campus.plant.rating_W, ...s.rating);
    const sx = (h) => (s.hours > 1 ? (h / (s.hours - 1)) * W : 0);
    const sy = (v) => H - 3 - (v / top) * (H - 6);
    const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" }, host);
    f.significant.forEach((on, h) => {
      if (on) el("rect", { x: sx(h) - W / s.hours / 2, y: 0, width: Math.max(1.5, W / s.hours), height: H, fill: "var(--shed)", opacity: 0.28 }, svg);
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
      const shed = sum(range.map((h) => (f.significant[h] ? f.shedBy[h] : 0))) / 1e6;
      rows.push([`Day ${d + 1}`, s.outdoor ? num(Math.min(...range.map((h) => s.outdoor[h])), 1) : "n/a",
        MW(Math.max(...range.map((h) => f.demandBy[h]))), MW(Math.max(...range.map((h) => s.output[h]))), num(shed, 1)]);
    }
    dataTable(host, "Day-by-day values for this scenario", ["Day", "Lowest outdoor (C)", "Peak demand (MW)", "Peak output (MW)", "Shed (MWh)"], rows);
    const byLoad = s.loadIds.map((id, j) => {
      let shed = 0, total = 0;
      for (let h = 0; h < s.hours; h++) {
        total += s.demand[h][j];
        if (f.significant[h]) shed += Math.max(0, s.demand[h][j] - s.served[h][j]);
      }
      return { load: campus.loads.find((l) => l.id === id), shed: shed / 1e6, total: total / 1e6 };
    }).filter((r) => r.shed > 0 && r.load).sort((a, b) => b.shed - a.shed);
    if (byLoad.length) {
      dataTable(host, "Buildings with shed load in this scenario", ["Building", "Type", "Shed (MWh)", "Share of its demand (%)"],
        byLoad.map((r) => [r.load.name, r.load.type, num(r.shed, 1), num((100 * r.shed) / r.total, 1)]));
    } else {
      el("p", { class: "note" }, host, "No building has shed load in this scenario.");
    }
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

  async function select(id) {
    const token = ++state.token;
    const s = await fetchScenario(id);
    if (token !== state.token) return;
    if (!s) {
      setPlaying(false);
      state.s = null;
      view.setVisible(false);
      missing(view.notice, " This scenario could not be loaded.");
      view.notice.hidden = false;
      $("hero-title").textContent = DEFAULT_TITLE;
      $("hero-sub").hidden = true;
      panel.hidden = true;
      transport.hidden = true;
      $("hero-tables").replaceChildren();
      return;
    }
    view.notice.hidden = true;
    view.setVisible(true);
    panel.hidden = false;
    transport.hidden = false;
    state.s = s;
    state.f = scenarioFacts(s);
    view.prepare(s);
    scrubber.max = s.hours - 1;
    state.hour = Math.min(state.hour, s.hours - 1);
    $("hero-title").textContent = findingText(s, state.f, entry(id)?.label || labels[id]);
    const sub = $("hero-sub"), description = entry(id)?.description;
    sub.hidden = !description;
    sub.textContent = description || "";
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
  new IntersectionObserver(([e]) => { state.visible = e.isIntersecting; }).observe(map);
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

function buildMap(host, campus) {
  host.replaceChildren();
  const pts = [...campus.junctions.values()];
  const xs = pts.map((j) => j.x), ys = pts.map((j) => j.y);
  const pad = 46;
  const x0 = Math.min(...xs) - pad, y1 = Math.max(...ys) + pad;
  const vw = Math.max(...xs) - x0 + pad, vh = y1 - Math.min(...ys) + pad;
  const px = (j) => j.x - x0, py = (j) => y1 - j.y;
  const svg = el("svg", {
    viewBox: `0 0 ${vw} ${vh}`, role: "img",
    "aria-label": "Map of the fictional campus steam network. Pipes are colored by steam temperature and drawn wider for larger flows. Buildings show served and shed load. The status panel and the tables below give the same values as text.",
  }, host);
  const notice = el("div", { hidden: "" }, host);
  const pipeLayer = el("g", {}, svg), markLayer = el("g", {}, svg), bldgLayer = el("g", {}, svg);
  const pipes = new Map(campus.pipes.map((p) => {
    const a = campus.junctions.get(p.from), b = campus.junctions.get(p.to);
    const node = el("line", { class: "pipe", x1: px(a), y1: py(a), x2: px(b), y2: py(b), "stroke-width": 1.5 }, pipeLayer);
    return [p.id, { node, mx: (px(a) + px(b)) / 2, my: (py(a) + py(b)) / 2 }];
  }));
  const loads = new Map(campus.loads.map((l) => {
    const j = campus.junctions.get(l.junction);
    const g = el("g", { "data-load": l.id }, bldgLayer);
    return [l.id, {
      load: l, cx: px(j), cy: py(j),
      base: el("rect", { class: "bldg" }, g),
      shed: el("rect", { class: "bldg-shed", height: 0 }, g),
      ring: el("rect", { class: "bldg-ring", visibility: "hidden" }, g),
    }];
  }));
  const pj = campus.junctions.get(campus.plant.junction);
  const plantMark = el("rect", { class: "plant" }, svg);
  const plantText = el("text", { "text-anchor": "start" }, svg, "Plant");

  let unit = 1, size = 10, current = null, hourNow = 0, maxFlow = 1, outPipes = [];
  const loadInfo = new Map();

  function drawOutMarks() {
    markLayer.replaceChildren();
    outPipes.forEach((id) => {
      const p = pipes.get(id);
      if (!p) return;
      const d = 7 * unit;
      el("path", { class: "out-mark", d: `M${p.mx - d} ${p.my - d}L${p.mx + d} ${p.my + d}M${p.mx - d} ${p.my + d}L${p.mx + d} ${p.my - d}` }, markLayer);
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
      for (const r of [v.base, v.ring]) {
        r.setAttribute("x", v.cx - size / 2); r.setAttribute("y", v.cy - size / 2);
        r.setAttribute("width", size); r.setAttribute("height", size);
      }
      v.shed.setAttribute("x", v.cx - size / 2); v.shed.setAttribute("y", v.cy - size / 2); v.shed.setAttribute("width", size);
    });
    const s = size * 1.7;
    plantMark.setAttribute("x", px(pj) - s / 2); plantMark.setAttribute("y", py(pj) - s / 2);
    plantMark.setAttribute("width", s); plantMark.setAttribute("height", s);
    plantText.setAttribute("x", px(pj) + s / 2 + 6 * unit); plantText.setAttribute("y", py(pj) + 5 * unit);
    plantText.setAttribute("font-size", 13 * unit); plantText.setAttribute("stroke-width", 3 * unit);
    drawOutMarks();
    if (current) update(current, hourNow);
  }

  const readRamp = () => {
    const styles = getComputedStyle(document.documentElement);
    return ["--hot-0", "--hot-1"].map((name) => {
      const h = styles.getPropertyValue(name).trim().slice(1);
      return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
    });
  };
  let [c0, c1] = readRamp();
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    [c0, c1] = readRamp();
    if (current) update(current, hourNow);
  });
  const tMin = 100, tMax = campus.plant.supply_temp_C;
  const color = (t) => {
    const u = Math.max(0, Math.min(1, (t - tMin) / (tMax - tMin)));
    return `rgb(${c0.map((c, i) => Math.round(c + (c1[i] - c) * u)).join(" ")})`;
  };

  function prepare(s) {
    current = s;
    maxFlow = Math.max(1e-9, ...s.flow.map((row) => Math.max(...row.map(Math.abs))));
    const out = new Set();
    if (s.inService) s.inService.forEach((row) => row.forEach((on, i) => { if (!on) out.add(s.pipeIds[i]); }));
    outPipes = [...out];
    drawOutMarks();
  }

  function update(s, h) {
    hourNow = h;
    s.pipeIds.forEach((id, i) => {
      const p = pipes.get(id);
      if (!p) return;
      const on = !s.inService || s.inService[h][i];
      p.node.classList.toggle("out", !on);
      if (!on) { p.node.style.stroke = ""; p.node.setAttribute("stroke-width", 2); return; }
      const share = Math.abs(s.flow[h][i]) / maxFlow;
      const light = share < LIGHT_FLOW_SHARE || (s.nonUnique && s.nonUnique[h][i]);
      p.node.style.stroke = color(s.temp[h][i]);
      p.node.setAttribute("stroke-width", light ? 1.5 : (1.5 + 6 * Math.sqrt(share)).toFixed(1));
    });
    s.loadIds.forEach((id, j) => {
      const v = loads.get(id);
      if (!v) return;
      const d = s.demand[h][j], frac = d > 0 ? Math.max(0, d - s.served[h][j]) / d : 0;
      const shed = frac > SHED_EPS;
      loadInfo.set(id, { d, served: s.served[h][j], frac });
      v.shed.setAttribute("height", shed ? Math.max(size * 0.18, size * frac) : 0);
      v.ring.setAttribute("visibility", shed ? "visible" : "hidden");
    });
  }

  svg.addEventListener("pointermove", (e) => {
    const g = e.target.closest?.("[data-load]");
    if (!g) return hideTip();
    const v = loads.get(+g.dataset.load), info = loadInfo.get(+g.dataset.load);
    if (!v || !info) return;
    showTip(e.clientX, e.clientY, (t) => {
      el("b", {}, t, v.load.name);
      el("div", {}, t, `Demand ${MW(info.d)} MW`);
      el("div", {}, t, `Served ${MW(info.served)} MW${info.frac > SHED_EPS ? `, ${((100 * info.frac)).toFixed(0)}% shed` : ""}`);
    });
  });
  svg.addEventListener("pointerleave", hideTip);
  resize();
  return { notice, prepare, update, resize, setVisible: (on) => { svg.style.display = on ? "" : "none"; } };
}

function buildKey(host, campus) {
  host.replaceChildren();
  const a = el("span", {}, host);
  a.append("100 C");
  el("i", { class: "ramp" }, a);
  a.append(`${num(campus.plant.supply_temp_C)} C steam`);
  el("span", {}, host, "Wider line: more flow");
  const b = el("span", {}, host); el("i", { class: "swatch" }, b); b.append("Building served");
  const c = el("span", {}, host); el("i", { class: "swatch shed" }, c); c.append("Part of load shed");
  const d = el("span", {}, host); el("i", { class: "line-key" }, d); d.append("Pipe out of service");
}

function buildPanel(host, campus) {
  host.replaceChildren();
  const nameplate = campus.plant.rating_W;
  const head = el("div", { class: "gauge-head" }, host);
  el("span", {}, head, "Plant output");
  const pct = el("span", {}, head);
  const value = el("div", { class: "gauge-value" }, host);
  const meter = el("div", { class: "meter" }, host);
  const fill = el("i", { class: "fill" }, meter), off = el("i", { class: "off" }, meter);
  const foot = el("div", { class: "gauge-foot" }, host);
  const dl = el("dl", { class: "readout" }, host);
  const row = (k) => { el("dt", {}, dl, k); return el("dd", {}, dl); };
  const when = row("Time"), outdoor = row("Outdoors"), demand = row("Demand"), shed = row("Shed");
  const lossLabel = el("dt", { hidden: "" }, dl, "Lost in pipes"), loss = el("dd", { hidden: "" }, dl);
  const list = el("p", { class: "shed-now" }, host);
  return {
    update(s, hour, d, sh) {
      const out = s.output[hour], avail = s.rating[hour];
      value.replaceChildren(`${MW(out)} `);
      el("small", {}, value, "MW");
      pct.textContent = `${Math.round((100 * out) / avail)}% of available`;
      fill.style.width = `${Math.min(100, (100 * out) / nameplate)}%`;
      off.style.width = `${Math.max(0, 100 * (1 - avail / nameplate))}%`;
      foot.textContent = avail < nameplate
        ? `${MW(avail, 0)} MW available, derated from the ${MW(nameplate, 0)} MW rating`
        : `${MW(avail, 0)} MW available, the full rating`;
      lossLabel.hidden = loss.hidden = !s.heatLoss;
      if (s.heatLoss) loss.textContent = `${MW(s.heatLoss[hour], 2)} MW`;
      when.textContent = hourLabel(hour);
      outdoor.textContent = s.outdoor ? `${s.outdoor[hour].toFixed(1)} C` : "n/a";
      demand.textContent = `${MW(d)} MW`;
      shed.textContent = `${MW(sh)} MW`;
      const short = s.loadIds.map((id, j) => ({ id, v: s.demand[hour][j] - s.served[hour][j], d: s.demand[hour][j] }))
        .filter((r) => r.d > 0 && r.v / r.d > SHED_EPS).sort((a, b) => b.v - a.v);
      list.replaceChildren();
      if (!short.length) { list.append("All buildings fully served this hour."); return; }
      el("b", {}, list, `${short.length} building${short.length > 1 ? "s" : ""} short: `);
      list.append(short.slice(0, 3).map((r) => `${campus.loads.find((l) => l.id === r.id)?.name ?? r.id} ${MW(r.v)} MW`).join(", ") + (short.length > 3 ? ", and others" : ""));
    },
  };
}

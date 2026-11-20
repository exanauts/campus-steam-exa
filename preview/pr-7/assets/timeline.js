// The week timeline under the map: heat demand, plant output and available capacity in MW, with shed
// hours shaded and the scenario event marked. It doubles as the scrubber: clicking or dragging on it
// picks the hour. The range input next to it stays for keyboard users.
import { el, hourLabel, showTip, hideTip } from "./format.js";
import { linTicks } from "./charts.js";

const fixed = (v, digits = 1) => v.toFixed(digits);

// Short text for the event band, built from the event fields in the scenario file.
export function eventLabel(e) {
  if (e.kind === "boiler_out") return "Boiler out";
  if (e.kind === "pipe_out") return Number.isFinite(e.pipe) ? `Pipe ${e.pipe} out` : "Pipe out";
  if (e.kind === "load_surge" && Number.isFinite(e.factor)) return `Loads +${Math.round((e.factor - 1) * 100)}%`;
  return "Event";
}

// Runs of consecutive hours where test(h) holds, as [first, last] indexes counted from 0.
function runs(n, test) {
  const out = [];
  let start = -1;
  for (let h = 0; h <= n; h++) {
    const on = h < n && test(h);
    if (on && start < 0) start = h;
    if (!on && start >= 0) { out.push([start, h - 1]); start = -1; }
  }
  return out;
}

export function createTimeline(host, legendHost, range, { onSeek, shedMin }) {
  let s = null, hour = 0, dragging = false;
  let geom = null, cursor = null, cursorDot = null, hover = null;

  function legend() {
    legendHost.replaceChildren();
    const item = (cls, text) => { const li = el("li", {}, legendHost); el("i", { class: cls }, li); li.append(text); };
    item("ln-demand", "Heat demand");
    item("ln-output", "Plant output");
    item("ln-capacity", "Available capacity");
    if (s.shed.some((v) => v >= shedMin)) item("sw-shed", "Hours with load shed");
    if (s.events.length) item("sw-event", "Event window");
  }

  function draw() {
    if (!s) return;
    host.replaceChildren();
    const W = Math.max(260, host.clientWidth || 600);
    const H = W < 520 ? 180 : 200;
    const m = { l: 38, r: 10, t: 24, b: 24 };
    const iw = W - m.l - m.r, ih = H - m.t - m.b;
    const n = s.hours;
    const top = Math.max(...s.rating, ...s.demand, ...s.output) * 1.12;
    // Hour h spans [h, h + 1] on the x axis, and its values sit at the middle of that span.
    const x = (h) => m.l + (iw * h) / n;
    const xc = (h) => x(h + 0.5);
    const y = (v) => m.t + ih * (1 - v / top);
    geom = { W, m, iw, n, x, xc, y };
    const svg = el("svg", {
      viewBox: `0 0 ${W} ${H}`, role: "img",
      "aria-label": "Heat demand, plant output and available plant capacity in MW for each hour of the week, with hours of shed load shaded and the event window marked. The hour slider below reads the same values, and the day-by-day table below the map lists them.",
    }, host);
    range.style.marginLeft = `${m.l - 8}px`;
    range.style.width = `calc(100% - ${m.l - 8 + m.r - 8}px)`;

    s.events.forEach((e) => {
      const a = x(e.first_hour - 1), b = x(e.last_hour);
      el("rect", { class: "tl-event", x: a, y: m.t, width: b - a, height: ih }, svg);
      el("line", { class: "tl-event-edge", x1: a, x2: a, y1: m.t - 4, y2: m.t + ih }, svg);
      el("line", { class: "tl-event-edge", x1: b, x2: b, y1: m.t - 4, y2: m.t + ih }, svg);
      el("text", { class: "tl-event-label", x: a + 4, y: m.t - 8 }, svg, eventLabel(e));
    });
    runs(n, (h) => s.shed[h] >= shedMin).forEach(([a, b]) => {
      el("rect", { class: "tl-shed", x: x(a), y: m.t, width: Math.max(1.5, x(b + 1) - x(a)), height: ih }, svg);
    });
    linTicks(0, top, H < 190 ? 3 : 4).filter((t) => t <= top).forEach((t) => {
      el("line", { class: "grid", x1: m.l, x2: W - m.r, y1: y(t), y2: y(t) }, svg);
      el("text", { class: "tl-tick", x: m.l - 6, y: y(t) + 4, "text-anchor": "end" }, svg, String(t));
    });
    el("text", { class: "tl-tick", x: m.l - 6, y: m.t - 8, "text-anchor": "end" }, svg, "MW");
    el("line", { class: "base", x1: m.l, x2: W - m.r, y1: m.t + ih, y2: m.t + ih }, svg);
    const days = Math.ceil(n / 24), perDay = iw / days;
    for (let d = 0; d <= days; d++) {
      const dx = x(Math.min(n, d * 24));
      el("line", { class: "base", x1: dx, x2: dx, y1: m.t + ih, y2: m.t + ih + 5 }, svg);
      if (d < days) el("text", { class: "tl-tick", x: dx + perDay / 2, y: m.t + ih + 17, "text-anchor": "middle" }, svg, perDay >= 44 || d === 0 ? `Day ${d + 1}` : String(d + 1));
    }

    const line = (a) => a.map((v, h) => `${h ? "L" : "M"}${xc(h).toFixed(1)} ${y(v).toFixed(1)}`).join("");
    const step = s.rating.map((v, h) => `${h ? "H" + x(h).toFixed(1) + "V" : "M" + x(0).toFixed(1) + " "}${y(v).toFixed(1)}`).join("") + `H${x(n).toFixed(1)}`;
    el("path", { class: "tl-capacity", d: step }, svg);
    // Demand is drawn last and thinner, so the output line shows where the two coincide.
    el("path", { class: "tl-output", d: line(s.output) }, svg);
    el("path", { class: "tl-demand", d: line(s.demand) }, svg);

    hover = el("line", { class: "tl-hover", y1: m.t, y2: m.t + ih, visibility: "hidden" }, svg);
    cursor = el("line", { class: "tl-cursor", y1: m.t - 2, y2: m.t + ih }, svg);
    cursorDot = el("circle", { class: "tl-dot", r: 4 }, svg);
    // A transparent layer over the plot is the hit target, so the pointer never has to land on a line.
    const hit = el("rect", { class: "tl-hit", x: m.l, y: 0, width: iw, height: H }, svg);
    hit.addEventListener("pointerdown", (e) => {
      dragging = true;
      hit.setPointerCapture(e.pointerId);
      onSeek(hourAt(e, svg), false);
    });
    hit.addEventListener("pointermove", (e) => {
      const h = hourAt(e, svg);
      if (dragging) onSeek(h, false);
      if (e.pointerType !== "touch") readout(h, e.clientX, e.clientY);
    });
    const stop = (e) => {
      if (dragging) { dragging = false; onSeek(hourAt(e, svg), true); }
    };
    hit.addEventListener("pointerup", stop);
    hit.addEventListener("pointercancel", () => { dragging = false; });
    hit.addEventListener("pointerleave", () => { if (!dragging) { hover.setAttribute("visibility", "hidden"); hideTip(); } });
    place();
  }

  function hourAt(e, svg) {
    const r = svg.getBoundingClientRect();
    const px = (e.clientX - r.left) * (geom.W / r.width);
    return Math.max(0, Math.min(geom.n - 1, Math.floor(((px - geom.m.l) / geom.iw) * geom.n)));
  }

  function readout(h, cx, cy) {
    hover.setAttribute("x1", geom.xc(h)); hover.setAttribute("x2", geom.xc(h));
    hover.setAttribute("visibility", "visible");
    showTip(cx, cy, (t) => {
      el("b", {}, t, hourLabel(h));
      const row = (cls, v, k) => { const d = el("div", {}, t); el("i", { class: `tip-key ${cls}` }, d); el("strong", {}, d, `${fixed(v)} MW `); el("span", { class: "k" }, d, k); };
      row("ln-demand", s.demand[h], "heat demand");
      row("ln-output", s.output[h], "plant output");
      row("ln-capacity", s.rating[h], "available");
      if (s.shed[h] >= shedMin) row("sw-shed", s.shed[h], "shed");
      const e = s.events.find((ev) => h + 1 >= ev.first_hour && h + 1 <= ev.last_hour);
      if (e) el("div", { class: "k" }, t, eventLabel(e));
    });
  }

  function place() {
    if (!geom || !cursor) return;
    const cx = geom.xc(hour);
    cursor.setAttribute("x1", cx); cursor.setAttribute("x2", cx);
    cursorDot.setAttribute("cx", cx); cursorDot.setAttribute("cy", geom.y(s.output[hour]));
  }

  return {
    show(scenario) { s = scenario; legend(); draw(); },
    setHour(h) { hour = h; place(); },
    redraw: draw,
  };
}

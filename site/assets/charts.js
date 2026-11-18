import { el, compact, dataTable, showTip, hideTip } from "./format.js";

const logTicks = (lo, hi) => {
  const out = [];
  const a = Math.floor(Math.log10(lo)), b = Math.ceil(Math.log10(hi));
  const steps = b - a <= 2 ? [1, 2, 5] : [1];
  for (let e = a; e <= b; e++) for (const s of steps) { const v = s * 10 ** e; if (v >= lo * 0.999 && v <= hi * 1.001) out.push(v); }
  return out.length >= 2 ? out : [lo, hi];
};
const linTicks = (lo, hi, n = 5) => {
  const raw = (hi - lo) / n, mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw);
  const out = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + step * 1e-6; v += step) out.push(+v.toPrecision(10));
  return out;
};

// series: [{ name, color, points: [{ x, y, hollow, note }] }]. marker: { x, label }, passed only when measured.
export function lineChart(container, spec) {
  const { title, subtitle, xLabel, yLabel, series, xScale = "linear", yScale = "linear", marker = null, yFormat = compact } = spec;
  const box = el("div", { class: "chart" }, container);
  el("h4", {}, box, title);
  if (subtitle) el("p", { class: "sub" }, box, subtitle);
  const anyHollow = series.some((s) => s.points.some((p) => p.hollow));
  if (series.length > 1 || anyHollow) {
    const legend = el("ul", { class: "legend" }, box);
    series.forEach((s) => { const li = el("li", {}, legend); el("i", { style: `border-color:${s.color}` }, li); li.append(s.name); });
    if (anyHollow) { const li = el("li", {}, legend); el("i", { class: "hollow" }, li); li.append("Stopped at a looser tolerance"); }
  }
  const holder = el("div", {}, box);
  const xs = [...new Set(series.flatMap((s) => s.points.map((p) => p.x)))].sort((a, b) => a - b);
  const ys = series.flatMap((s) => s.points.map((p) => p.y));

  function draw() {
    holder.replaceChildren();
    const W = Math.max(280, holder.clientWidth || 600), H = Math.round(Math.min(340, Math.max(230, W * 0.56)));
    const m = { l: 52, r: 18, t: 12, b: 46 };
    const iw = W - m.l - m.r, ih = H - m.t - m.b;
    const xLog = xScale === "log", yLog = yScale === "log";
    const pad = (lo, hi, log) => (log ? [lo / 1.25, hi * 1.25] : [Math.min(0, lo), hi * 1.08 || 1]);
    const [x0, x1] = xs.length > 1 ? pad(xs[0], xs[xs.length - 1], xLog) : [xs[0] * 0.5, xs[0] * 1.5];
    const [y0, y1] = pad(Math.min(...ys), Math.max(...ys), yLog);
    const sx = (v) => m.l + iw * (xLog ? Math.log(v / x0) / Math.log(x1 / x0) : (v - x0) / (x1 - x0));
    const sy = (v) => m.t + ih * (1 - (yLog ? Math.log(v / y0) / Math.log(y1 / y0) : (v - y0) / (y1 - y0)));
    const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", tabindex: "0", "aria-label": `${title}. Use the left and right arrow keys to read values. The same values are in the table below.` }, holder);
    (yLog ? logTicks(y0, y1) : linTicks(y0, y1)).forEach((t) => {
      el("line", { class: "grid", x1: m.l, x2: W - m.r, y1: sy(t), y2: sy(t) }, svg);
      el("text", { x: m.l - 6, y: sy(t) + 4, "text-anchor": "end" }, svg, yFormat(t));
    });
    let xt = xLog ? logTicks(x0, x1) : linTicks(x0, x1, W < 420 ? 4 : 6);
    if (xLog && W < 420 && xt.length > 5) xt = xt.filter((_, i) => i % 2 === 0);
    el("line", { class: "base", x1: m.l, x2: W - m.r, y1: m.t + ih, y2: m.t + ih }, svg);
    xt.forEach((t) => el("text", { x: sx(t), y: m.t + ih + 16, "text-anchor": "middle" }, svg, compact(t)));
    el("text", { x: m.l + iw / 2, y: H - 8, "text-anchor": "middle" }, svg, xLabel);
    el("text", { transform: `translate(12 ${m.t + ih / 2}) rotate(-90)`, "text-anchor": "middle" }, svg, yLabel);
    if (marker) {
      el("line", { class: "mark-line", x1: sx(marker.x), x2: sx(marker.x), y1: m.t, y2: m.t + ih }, svg);
      const right = sx(marker.x) > W * 0.6;
      el("text", { class: "dlabel", x: sx(marker.x) + (right ? -6 : 6), y: m.t + 12, "text-anchor": right ? "end" : "start" }, svg, marker.label);
    }
    series.forEach((s) => {
      const pts = [...s.points].sort((a, b) => a.x - b.x);
      el("path", { class: "ln", stroke: s.color, d: pts.map((p, i) => `${i ? "L" : "M"}${sx(p.x).toFixed(1)} ${sy(p.y).toFixed(1)}`).join("") }, svg);
      pts.forEach((p) => el("circle", { cx: sx(p.x), cy: sy(p.y), r: 4.5, fill: p.hollow ? "var(--surface)" : s.color, stroke: p.hollow ? s.color : "var(--surface)", "stroke-width": 2 }, svg));
    });
    const cross = el("line", { class: "cross", y1: m.t, y2: m.t + ih, visibility: "hidden" }, svg);
    let idx = -1;
    const show = (i, cx, cy) => {
      idx = i;
      const v = xs[i];
      cross.setAttribute("x1", sx(v)); cross.setAttribute("x2", sx(v)); cross.setAttribute("visibility", "visible");
      showTip(cx, cy, (t) => {
        el("b", {}, t, `${xLabel}: ${compact(v)}`);
        series.forEach((s) => {
          const p = s.points.find((q) => q.x === v);
          if (!p) return;
          const row = el("div", {}, t);
          row.append(`${yFormat(p.y)} `);
          el("span", { class: "k" }, row, s.name + (p.note ? ` (${p.note})` : ""));
        });
      });
    };
    const hide = () => { cross.setAttribute("visibility", "hidden"); hideTip(); idx = -1; };
    svg.addEventListener("pointermove", (e) => {
      const r = svg.getBoundingClientRect(), px = (e.clientX - r.left) * (W / r.width);
      let best = 0;
      xs.forEach((v, i) => { if (Math.abs(sx(v) - px) < Math.abs(sx(xs[best]) - px)) best = i; });
      show(best, e.clientX, e.clientY);
    });
    svg.addEventListener("pointerleave", hide);
    svg.addEventListener("blur", hide);
    svg.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      e.preventDefault();
      const next = idx < 0 ? 0 : Math.max(0, Math.min(xs.length - 1, idx + (e.key === "ArrowRight" ? 1 : -1)));
      const r = svg.getBoundingClientRect();
      show(next, r.left + sx(xs[next]) * (r.width / W), r.top + r.height * 0.3);
    });
  }
  draw();
  let last = holder.clientWidth;
  new ResizeObserver(() => {
    if (Math.abs(holder.clientWidth - last) > 8) { last = holder.clientWidth; draw(); }
  }).observe(holder);
  dataTable(box, `Table of values: ${title}`, [xLabel, ...series.map((s) => s.name)],
    xs.map((v) => [compact(v), ...series.map((s) => {
      const p = s.points.find((q) => q.x === v);
      return p ? yFormat(p.y) + (p.note ? ` (${p.note})` : "") : "not measured";
    })]));
  return box;
}

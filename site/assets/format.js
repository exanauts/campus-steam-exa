export const MW = (w, digits = 1) => (w / 1e6).toFixed(digits);
export const num = (v, digits = 0) => v.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits });
export const compact = (v) => {
  const a = Math.abs(v);
  if (a >= 1e6) return `${+(v / 1e6).toPrecision(3)}M`;
  if (a >= 1e4) return `${+(v / 1e3).toPrecision(3)}K`;
  if (a >= 1000) return num(v);
  return `${+v.toPrecision(3)}`;
};
export const hourLabel = (h) => `Day ${Math.floor(h / 24) + 1}, ${String(h % 24).padStart(2, "0")}:00`;

const SVG_TAGS = new Set(["svg", "g", "path", "line", "rect", "circle", "text"]);
export function el(tag, attrs = {}, parent = null, text = null) {
  const node = SVG_TAGS.has(tag) ? document.createElementNS("http://www.w3.org/2000/svg", tag) : document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) if (v !== null && v !== undefined) node.setAttribute(k, v);
  if (text !== null) node.textContent = text;
  if (parent) parent.appendChild(node);
  return node;
}

export function missing(container, what) {
  container.replaceChildren();
  const box = el("p", { class: "na", role: "status" }, container);
  el("strong", {}, box, "Results not available in this build");
  box.append(what);
}

export function dataTable(parent, summaryText, headers, rows) {
  const details = el("details", {}, parent);
  el("summary", {}, details, summaryText);
  const scroll = el("div", { class: "table-scroll", tabindex: "0", role: "region", "aria-label": summaryText }, details);
  const table = el("table", {}, scroll);
  const headRow = el("tr", {}, el("thead", {}, table));
  headers.forEach((h) => el("th", { scope: "col" }, headRow, h));
  const body = el("tbody", {}, table);
  rows.forEach((r) => { const tr = el("tr", {}, body); r.forEach((c) => el("td", {}, tr, String(c))); });
  return details;
}

const tip = () => document.getElementById("tip");
export function showTip(x, y, build) {
  const t = tip();
  t.replaceChildren();
  build(t);
  t.hidden = false;
  const r = t.getBoundingClientRect();
  const left = Math.max(8, Math.min(window.innerWidth - r.width - 8, x + 14));
  const top = y - r.height - 12 < 8 ? y + 16 : y - r.height - 12;
  t.style.left = `${left}px`;
  t.style.top = `${top}px`;
}
export const hideTip = () => { tip().hidden = true; };

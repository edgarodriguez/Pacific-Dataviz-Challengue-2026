/* ===================================================================================
   Field Notes on a Moving Coast - local build.
   Charts read app/data/stats.json (12 KB). Coastlines, population and sea borders all
   stream from local tile archives, so nothing geographic is bundled into this file.
   Generated with the assistance of Claude Code (claude-opus-5)
   =================================================================================== */
"use strict";

const SVG = "http://www.w3.org/2000/svg";
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const SAT_URL = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";
maplibregl.addProtocol("pmtiles", new pmtiles.Protocol().tile);
let D, TILES, POP, MOTIFS, BGLINES;
let COUNTRY_HOT = {};   // per-territory named hotspots, from 13_/15_

/* ---------- deterministic wobble: a 40-line rough.js ---------- */
const rng = s => { let a = s >>> 0; return () => {
  a = (a + 0x6D2B79F5) | 0;
  let t = Math.imul(a ^ (a >>> 15), 1 | a);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
};
const jit = (r, a) => (r() - .5) * 2 * a;

function roughLine(x1, y1, x2, y2, r, bow = 1.5) {
  const dx = x2 - x1, dy = y2 - y1, L = Math.hypot(dx, dy) || 1;
  const b = jit(r, bow), mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
  return `M${x1 + jit(r,.6)} ${y1 + jit(r,.6)}Q${mx - dy/L*b} ${my + dx/L*b} ${x2 + jit(r,.6)} ${y2 + jit(r,.6)}`;
}
function roughRect(x, y, w, h, r, bow = 1.3) {
  const p = [[x,y],[x+w,y],[x+w,y+h],[x,y+h]].map(([a,b]) => [a + jit(r,.7), b + jit(r,.7)]);
  let d = `M${p[0][0]} ${p[0][1]}`;
  for (let i = 0; i < 4; i++) {
    const a = p[i], b = p[(i+1) % 4], dx = b[0]-a[0], dy = b[1]-a[1], L = Math.hypot(dx,dy) || 1;
    const o = jit(r, bow);
    d += `Q${(a[0]+b[0])/2 - dy/L*o} ${(a[1]+b[1])/2 + dx/L*o} ${b[0]} ${b[1]}`;
  }
  return d + "Z";
}

/* ---------- tiny SVG helpers ---------- */
const el = (n, at = {}, parent) => {
  const e = document.createElementNS(SVG, n);
  for (const k in at) if (at[k] !== null && at[k] !== undefined) e.setAttribute(k, at[k]);
  if (parent) parent.appendChild(e);
  return e;
};
const txt = (parent, x, y, s, at = {}) => {
  const e = el("text", Object.assign({ x, y, "font-size": 11 }, at), parent);
  e.textContent = s;
  return e;
};
function frame(svg, w, h) {
  svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
  while (svg.firstChild) svg.removeChild(svg.firstChild);
}
const fmt = (n, d = 0) => Number(n).toLocaleString("en-GB",
  { minimumFractionDigits: d, maximumFractionDigits: d });
const sign = (n, d = 1) => (n >= 0 ? "+" : "−") + fmt(Math.abs(n), d);

function ticks(lo, hi, want = 5) {
  const raw = (hi - lo) / want, mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(v => v >= raw) || 10 * mag;
  const out = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + 1e-9; v += step) out.push(+v.toFixed(6));
  if (lo <= 0 && hi >= 0 && !out.some(v => Math.abs(v) < 1e-9)) out.push(0);
  return out.sort((a, b) => a - b);
}

/* Every chart used to name its patterns the same thing, so `url(#hatch-loss)` resolved to
   whichever SVG happened to come first in the document - and if that one was hidden, every
   other chart lost its fill. Patterns are namespaced by the SVG that owns them. */
const pid = (svg, name) => `${svg.id || "svg"}-${name}`;
const purl = (svg, name) => `url(#${pid(svg, name)})`;

function defsFor(svg, ids) {
  const defs = el("defs", {}, svg);
  ids.forEach(id => {
    const tone = id.replace(/^hatch-/, "");
    const p = el("pattern", { id: pid(svg, id), width: 7, height: 7,
                              patternTransform: "rotate(-52)",
                              patternUnits: "userSpaceOnUse" }, defs);
    el("rect", { width: 7, height: 7, fill: `var(--${tone}-soft)` }, p);
    el("line", { x1: 0, y1: 0, x2: 0, y2: 7, stroke: `var(--${tone})`,
                 "stroke-width": 1.7, opacity: .5 }, p);
  });
}

/* ================================================================
   01  the two big flows
   ================================================================ */
function flowChart() {
  const P = D.pacific, svg = document.getElementById("flowChart");
  const W = 760, HT = 330, m = { t: 34, r: 18, b: 46, l: 62 };
  frame(svg, W, HT);
  defsFor(svg, ["hatch-gain", "hatch-loss"]);
  const r = rng(21);

  const steps = [
    { k: "taken by retreat", v: -P.area_lost_km2, tone: "loss" },
    { k: "added by growth", v: P.area_gained_km2, tone: "gain" },
    { k: "net change",       v: P.area_net_km2,   tone: "ink", total: true }
  ];
  let run = 0;
  const seq = steps.map(s => {
    const a = s.total ? 0 : run, b = s.total ? s.v : run + s.v;
    if (!s.total) run += s.v;
    return { ...s, a, b };
  });
  const vals = seq.flatMap(s => [s.a, s.b]).concat(0);
  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo) * .14;
  const y = v => m.t + (hi + pad - v) / (hi - lo + 2 * pad) * (HT - m.t - m.b);
  const bw = (W - m.l - m.r) / seq.length * .56;
  const cx = i => m.l + (W - m.l - m.r) * (i + .5) / seq.length;

  const gAx = el("g", {}, svg);
  ticks(lo, hi, 4).forEach(v => {
    el("path", { d: roughLine(m.l - 8, y(v), W - m.r, y(v), r, v === 0 ? .8 : .5),
      stroke: v === 0 ? "var(--ink-2)" : "var(--grid-strong)", "stroke-width": v === 0 ? 1.5 : 1,
      fill: "none", "stroke-linecap": "round" }, gAx);
    txt(gAx, m.l - 13, y(v) + 3.5, fmt(v), { "text-anchor": "end", "font-size": 10.5, fill: "var(--ink-3)" });
  });
  txt(gAx, m.l - 13, m.t - 15, "km²", { "text-anchor": "end", "font-size": 10, fill: "var(--ink-3)" });

  seq.forEach((s, i) => {
    const g = el("g", {}, svg);
    const top = Math.min(y(s.a), y(s.b)), h = Math.max(4, Math.abs(y(s.a) - y(s.b)));
    const x = cx(i) - bw / 2;
    const grow = el("g", { class: "grow", style: `--d:${180 + i * 190}ms; transform-origin:${cx(i)}px ${y(s.a)}px` }, g);
    el("path", { d: roughRect(x, top, bw, h, r), fill: s.total ? "none" : purl(svg, `hatch-${s.tone}`),
      stroke: `var(--${s.tone})`, "stroke-width": 2, "stroke-linejoin": "round" }, grow);
    if (s.total) el("path", { d: roughRect(x + 3, top + 3, bw - 6, h - 6, r), fill: "none",
      stroke: "var(--loss)", "stroke-width": 1.4, opacity: .6 }, grow);

    txt(g, cx(i), s.v >= 0 ? top - 11 : top + h + 19, sign(s.v, 1),
      { "text-anchor": "middle", "font-size": 14, "font-weight": 600,
        fill: `var(--${s.tone})`, class: "fadein", style: `--d:${520 + i * 190}ms` });
    txt(g, cx(i), HT - 20, s.k, { "text-anchor": "middle", "font-size": 11, fill: "var(--ink-2)",
      class: "fadein", style: `--d:${560 + i * 190}ms` });

    if (i < seq.length - 1 && !seq[i + 1].total) {
      el("path", { d: roughLine(x + bw, y(s.b), cx(i + 1) - bw / 2, y(s.b), r, .5),
        stroke: "var(--ink-3)", "stroke-width": 1, "stroke-dasharray": "3 4", fill: "none",
        class: "fadein", style: `--d:${640 + i * 190}ms` }, g);
    }
  });

  txt(svg, cx(2) - bw / 2 - 12, y(0) - 16, "what is left",
    { "text-anchor": "end", "font-size": 16, class: "lbl-hand fadein",
      style: "--d:900ms", fill: "var(--ink-2)" });
}

/* ================================================================
   01  what the trends themselves look like
   Equal-count bins, so the height cannot be the count - every bar would be
   the same. Height is density, points per metre-per-year, which makes the
   bin widths the story: nearly all of the moving coast moves less than half
   a metre a year. The two extremes sit off the scale on purpose.
   ================================================================ */
const HIST_PALETTES = {
  petal: { label: "Petal deep",
           retreat: ["#7E3F2D", "#C4936A", "#D4C8B5"],
           advance: ["#547A6E", "#2D4F56", "#0F2C3D"] },
  tapa:  { label: "Tapa grid",
           retreat: ["#86432F", "#A7724A", "#CFCEAE"],
           advance: ["#77725D", "#59574E", "#3C4142"] },
};
/* one palette across every chart: Petal deep. The pickers are gone - the page
   already carries a palette switch of its own, and two competing ones read as noise. */
const histPalette = "petal";

/* n colours spread along the stops, so a three-colour palette can dress six bars */
function ramp(stops, n) {
  const rgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const cols = stops.map(rgb);
  return Array.from({ length: n }, (_, i) => {
    const t = n === 1 ? 0 : (i / (n - 1)) * (cols.length - 1);
    const a = cols[Math.floor(t)], b = cols[Math.min(Math.ceil(t), cols.length - 1)];
    const f = t - Math.floor(t);
    return `rgb(${a.map((v, k) => Math.round(v + (b[k] - v) * f)).join(",")})`;
  });
}

let histKind = "count";

const HIST_CAP = {
  count: `Every bar holds the same number of points, then a <em>wider bar</em> spreads that group thinly across a big range ` + `of rates of change, a narrow one packs the same number of points into a similar range of rates. `
       + `Negative values mean retreat, land being taken; positive is `
       + `growth. The hatched band at the centre is not a zero reading: it is every `
       + `point with no significant rate, and every point with low certainty, filed there instead. `
       + `The dashed line marks the median and the dotted line the mean of the points.`,
  even:  `The same points in bins of equal width, half a metre a year each, which is what `
       + `the distribution actually looks like: a single narrow spike around zero with two `
       + `long thin tails. Negative is retreat, land being taken; positive is growth. Bar `
       + `height is simply how many points fall in the bin. The two blocks at the edges hold `
       + `everything moving more than five metres a year in either direction, drawn off `
       + `the scale because on it they would be invisible. The dashed line marks the median `
       + `and the dotted line the mean.`
};

function drawHistograms() {
  const even = histKind === "even";
  const a = document.getElementById("rateHist");
  const b = document.getElementById("rateHistEven");
  if (a) a.parentElement.hidden = even;
  if (b) b.parentElement.hidden = !even;
  if (even) rateHistogramEven(); else rateHistogram();
  const cap = document.getElementById("histCap");
  if (cap) cap.innerHTML = HIST_CAP[histKind];
  document.querySelectorAll("[data-hist]").forEach(x =>
    x.setAttribute("aria-pressed", String(x.dataset.hist === histKind)));
}

function rateHistogram() {
  const svg = document.getElementById("rateHist");
  if (!svg || !D.rate_hist) return;
  const bins = D.rate_hist, pal = HIST_PALETTES[histPalette];
  const W = 760, HT = 364, m = { t: 58, r: 22, b: 78, l: 60 };
  const plotW = W - m.l - m.r, plotH = HT - m.t - m.b;
  frame(svg, W, HT);
  defsFor(svg, ["hatch-ink-3"]);
  const r = rng(11);

  const cap = D.meta.hist_cap_m_yr || 5;
  const tailW = 34, gapW = 9, midW = 62;
  const coreW = (plotW - 2 * tailW - 2 * gapW - midW) / 2;

  /* lay the bars out left to right: worst retreat, through the unresolved
     middle, out to the fastest new land */
  let x = m.l;
  const slots = bins.map(b => {
    const w = b.tail ? tailW : b.side === "unclear" ? midW : (b.hi - b.lo) / cap * coreW;
    const s = { ...b, x, w, density: b.side === "unclear" || b.tail ? null : b.n / (b.hi - b.lo) };
    x += w + (b.tail ? gapW : 0);
    return s;
  });
  const maxD = Math.max(...slots.map(s => s.density || 0)) * 1.08;   // headroom, so the tallest bar is not clipped
  const yh = d => Math.max(1.5, plotH * d / maxD);
  const base = m.t + plotH;

  const retreatCols = ramp(pal.retreat, 6);
  const advanceCols = ramp(pal.advance, 6);
  let ri = 0, ai = 0;

  /* ---- the unresolved middle, drawn as a band rather than a bar: it has no
          width in metres a year, so it has no density to compare ---- */
  const mid = slots.find(s => s.side === "unclear");
  el("rect", { x: mid.x, y: m.t - 8, width: mid.w, height: plotH + 8,
    fill: purl(svg, "hatch-grey") }, svg);
  el("rect", { x: mid.x, y: m.t - 8, width: mid.w, height: plotH + 8, fill: "none",
    stroke: "var(--ink-3)", "stroke-width": 1, "stroke-dasharray": "3 3" }, svg);

  /* ---- the bars ---- */
  slots.forEach(s => {
    if (s.side === "unclear") return;
    if (s.tail) {
      const top = m.t + 62, c = s.side === "retreat" ? retreatCols[0] : advanceCols[5];
      el("path", { d: roughRect(s.x, top, s.w, base - top, r, .8), fill: c, opacity: .16 }, svg);
      el("path", { d: roughRect(s.x, top, s.w, base - top, r, .8), fill: "none",
        stroke: c, "stroke-width": 1.2, "stroke-dasharray": "4 3" }, svg);
      return;
    }
    const h = yh(s.density);
    const fill = s.side === "retreat" ? retreatCols[++ri] : advanceCols[ai++];
    el("path", { d: roughRect(s.x, base - h, s.w, h, r, .7), fill,
      stroke: "var(--paper)", "stroke-width": .8 }, svg);
  });

  /* ---- axis ---- */
  el("path", { d: roughLine(m.l, base, m.l + plotW, base, r, .8), fill: "none",
    stroke: "var(--ink-2)", "stroke-width": 1.3 }, svg);

  const core = slots.filter(s => !s.tail && s.side !== "unclear");
  const xAt = v => {
    const side = v < 0 ? "retreat" : "advance";
    const b = core.find(s => s.side === side && v >= s.lo && v <= s.hi) ||
              core[v < 0 ? 0 : core.length - 1];
    return b.x + (v - b.lo) / (b.hi - b.lo) * b.w;
  };
  [-5, -4, -3, -2, -1, 1, 2, 3, 4, 5].forEach(v => {
    el("path", { d: `M${xAt(v)} ${base}v6`, stroke: "var(--ink-3)", "stroke-width": 1 }, svg);
    txt(svg, xAt(v), base + 19, (v > 0 ? "+" : "−") + Math.abs(v),
      { "text-anchor": "middle", "font-size": 10.5, fill: "var(--ink-3)" });
  });

  txt(svg, m.l + coreW / 2 + tailW, base + 40, "retreat · land lost",
    { "text-anchor": "middle", "font-size": 11.5, fill: "var(--loss)" });
  txt(svg, m.l + plotW - coreW / 2 - tailW, base + 40, "growth · land gained",
    { "text-anchor": "middle", "font-size": 11.5, fill: "var(--gain)" });

  /* ---- median and mean of the points that could be called. The grey band has no
          position on this axis, so neither statistic includes it. The two land within
          three pixels of each other, so they share one callout. ---- */
  const C = D.rate_centre;
  if (C) {
    const top = m.t - 6;
    const marks = [
      { k: "median", v: C.median, dash: "7 4",   w: 1.5, dy: 0 },
      { k: "mean",   v: C.mean,   dash: "1.5 3", w: 1.5, dy: 15 }
    ];
    marks.forEach(mk => {
      mk.x = xAt(mk.v);
      el("path", { d: `M${mk.x} ${top}V${base}`, stroke: "var(--ink)", "stroke-width": mk.w,
        "stroke-dasharray": mk.dash, opacity: .9 }, svg);
    });
    // the two land within three pixels of each other, so each label is lifted to its own
    // line and led back to its line rather than sitting on top of the other
    const lx = Math.max(...marks.map(mk => mk.x)) + 14;
    marks.forEach(mk => {
      const ly = top - 30 + mk.dy;
      el("path", { d: `M${mk.x} ${top}V${ly - 3}H${lx - 4}`, fill: "none",
        stroke: "var(--ink-3)", "stroke-width": .9 }, svg);
      el("path", { d: `M${lx} ${ly - 3.4}h16`, stroke: "var(--ink)", "stroke-width": mk.w,
        "stroke-dasharray": mk.dash, opacity: .9 }, svg);
      txt(svg, lx + 22, ly, `${mk.k}  ${fmt(mk.v, 2)} m/yr`,
        { "font-size": 10, fill: "var(--ink-2)" });
    });
  }

  txt(svg, m.l - 8, m.t - 40, "how tightly the points pile up",
    { "font-size": 10, fill: "var(--ink-3)" });

  /* ---- what the three special blocks are ---- */
  const midN = fmt(mid.n);
  const midLbl = el("text", { x: mid.x + mid.w / 2, y: m.t + 26, "text-anchor": "middle",
    "font-size": 10, fill: "var(--ink-2)", class: "lbl-hand" }, svg);
  ["no change or", "low certainty"].forEach((t, i) => {
    const ts = el("tspan", { x: mid.x + mid.w / 2, dy: i ? 13 : 0 }, midLbl);
    ts.textContent = t;
  });
  txt(svg, mid.x + mid.w / 2, m.t + 58, midN,
    { "text-anchor": "middle", "font-size": 11.5, fill: "var(--ink-2)", class: "num" });
  txt(svg, mid.x + mid.w / 2, m.t + 72, "points",
    { "text-anchor": "middle", "font-size": 9, fill: "var(--ink-3)" });

  slots.filter(s => s.tail).forEach(s => {
    const left = s.side === "retreat";
    const tx = s.x + s.w / 2;
    const lab = el("text", { x: tx, y: m.t + 14, "text-anchor": "middle",
      "font-size": 11, fill: "var(--ink-3)" }, svg);
    [fmt(s.n), "more than", `${left ? "-" : ""}${cap} m / yr`].forEach((t, i) => {
      const ts = el("tspan", { x: tx, dy: i ? 12 : 0 }, lab);
      ts.textContent = t;
      if (i === 0) ts.setAttribute("fill", left ? "var(--loss)" : "var(--gain)");
    });
  });

  svg.setAttribute("aria-label",
    `Histogram of coastal trends. Every bar holds about the same number of measurement `
    + `points, so bar width shows how spread out that group is and bar height how tightly `
    + `packed. ${midN} points, four in five, show no clear trend and sit in the band at the `
    + `centre. ${fmt(slots[0].n)} points retreat more than ${cap} metres a year and `
    + `${fmt(slots[slots.length - 1].n)} build seaward more than that; both sit off the scale.`
    + (D.rate_centre ? ` Among the points that could be called, the median trend is `
        + `${fmt(D.rate_centre.median, 2)} and the mean ${fmt(D.rate_centre.mean, 2)} metres a `
        + `year, both on the retreating side of zero.` : ""));
}

/* The equal-count chart above answers "where do the points sit". It cannot answer
   "what shape is this", because it has flattened the shape by construction. Fixed-width
   bins over the same points can, and the two together are the honest pair. */
function rateHistogramEven() {
  const svg = document.getElementById("rateHistEven");
  if (!svg || !D.rate_hist_even) return;
  const E = D.rate_hist_even, pal = HIST_PALETTES[histPalette];
  const W = 760, HT = 268, m = { t: 34, r: 22, b: 92, l: 60 };
  const plotW = W - m.l - m.r, plotH = HT - m.t - m.b;
  frame(svg, W, HT);
  const r = rng(29);

  const tailW = 62, gapW = 10;
  const coreW = plotW - 2 * (tailW + gapW);
  const x0 = m.l + tailW + gapW;
  const px = v => x0 + (v + E.cap) / (2 * E.cap) * coreW;
  const bw = coreW / (2 * E.cap / E.step);
  const base = m.t + plotH;
  const maxN = Math.max(...E.bins.map(b => b.n));
  const h = n => Math.max(1, n / maxN * plotH);

  /* The same two ramps the equal-count chart above uses, so a bar of a given colour means
     the same speed in both: darkest at the outside of each side, palest at zero. */
  const nBins = E.bins.length, half = nBins / 2;
  const retreatCols = ramp(pal.retreat, half);
  const advanceCols = ramp(pal.advance, half);
  const cols = retreatCols.concat(advanceCols);

  E.bins.forEach((b, i) => {
    el("rect", { x: px(b.lo), y: base - h(b.n), width: Math.max(1, bw - .5),
      height: h(b.n), fill: cols[i] }, svg);
  });

  /* the two tails, off the scale on purpose, each taking the end of the same ramp */
  [{ x: m.l, n: E.lo_n, c: retreatCols[0], side: "retreating" },
   { x: m.l + plotW - tailW, n: E.hi_n, c: advanceCols[half - 1], side: "growing" }
  ].forEach(t => {
    const top = m.t + 8, cx = t.x + tailW / 2;
    el("path", { d: roughRect(t.x, top, tailW, base - top, r, .8), fill: t.c, opacity: .18 }, svg);
    el("path", { d: roughRect(t.x, top, tailW, base - top, r, .8), fill: "none",
      stroke: t.c, "stroke-width": 1.2, "stroke-dasharray": "4 3" }, svg);
    const lab = el("text", { x: cx, y: top + 16, "text-anchor": "middle",
      "font-size": 8, fill: "var(--ink-2)" }, svg);
    [fmt(t.n), t.side, `over ${E.cap} m/yr`].forEach((line, i) => {
      const ts = el("tspan", { x: cx, dy: i ? 11 : 0 }, lab);
      ts.textContent = line;
      if (i === 0) { ts.setAttribute("fill", t.c); ts.setAttribute("font-weight", 600); }
    });
  });

  el("path", { d: roughLine(m.l, base, m.l + plotW, base, r, .8), fill: "none",
    stroke: "var(--ink-2)", "stroke-width": 1.3 }, svg);

  /* every whole metre labelled, not just a few */
  for (let v = -5; v <= 5; v++) {
    el("path", { d: `M${px(v)} ${base}v${v === 0 ? 8 : 5}`, stroke: "var(--ink-3)",
      "stroke-width": v === 0 ? 1.3 : 1 }, svg);
    txt(svg, px(v), base + 19, v > 0 ? "+" + v : String(v),
      { "text-anchor": "middle", "font-size": 10, "font-weight": v === 0 ? 600 : 400,
        fill: v === 0 ? "var(--ink-2)" : "var(--ink-3)" });
  }

  /* the count axis, so the height means something */
  const yTicks = ticks(0, maxN, 4).filter(v => v > 0);
  yTicks.forEach(v => {
    const y = base - v / maxN * plotH;
    el("path", { d: `M${m.l - 5} ${y}H${m.l + plotW}`, stroke: "var(--grid-strong)",
      "stroke-width": 1, opacity: .5 }, svg);
    txt(svg, m.l - 9, y + 3.5, fmt(v),
      { "text-anchor": "end", "font-size": 11, fill: "var(--ink-3)" });
  });

  if (D.rate_centre) [
    { k: "median", v: D.rate_centre.median, dash: "7 4", dy: 0 },
    { k: "mean",   v: D.rate_centre.mean,   dash: "1.5 3", dy: 13 }
  ].forEach(mk => {
    el("path", { d: `M${px(mk.v)} ${m.t - 4}V${base}`, stroke: "var(--ink)",
      "stroke-width": 1.5, "stroke-dasharray": mk.dash, opacity: .9 }, svg);
    const lx = px(mk.v) + 8;
    el("path", { d: `M${lx} ${m.t - 12 + mk.dy - 3.4}h14`, stroke: "var(--ink)",
      "stroke-width": 1.5, "stroke-dasharray": mk.dash, opacity: .9 }, svg);
    txt(svg, lx + 20, m.t - 12 + mk.dy, `${mk.k} ${fmt(mk.v, 2)}`,
      { "font-size": 11, fill: "var(--ink-2)" });
  });

  txt(svg, m.l - 9, m.t - 10, "points per bin",
    { "text-anchor": "start", "font-size": 11, fill: "var(--ink-3)" });
  txt(svg, px(-E.cap / 2), base + 38, "retreat", { "text-anchor": "middle",
    "font-size": 10.5, fill: "var(--loss)" });
  txt(svg, px(E.cap / 2), base + 38, "growth", { "text-anchor": "middle",
    "font-size": 10.5, fill: "var(--gain)" });
  txt(svg, m.l + plotW / 2, base + 58, "trend, metres a year",
    { "text-anchor": "middle", "font-size": 10, "letter-spacing": ".1em",
      fill: "var(--ink-3)" });
  txt(svg, m.l + plotW / 2, base + 74,
    `equal bins of ${E.step} m a year · ${fmt(D.rate_centre ? D.rate_centre.n : 0)} points with a callable trend`,
    { "text-anchor": "middle", "font-size": 9, fill: "var(--ink-3)" });

  svg.setAttribute("aria-label",
    `The same points in bins of equal width, ${E.step} metres a year each. Nearly all of them `
    + `fall within half a metre a year of zero; the distribution is one narrow spike with two `
    + `long thin tails, ${fmt(E.lo_n)} points retreating and ${fmt(E.hi_n)} growing more `
    + `than ${E.cap} metres a year.`);
}

/* ================================================================
   02  by country, and by share
   ================================================================ */
let wfMode = "gross", wfUnit = "area";

/* Everything the page says about this chart moves with the toggle, not just the caption:
   the eyebrow, the headline and the standfirst are all claims about one measure. */
const WF_COPY = {
  gross: {
    eyebrow: "Where the retreat comes from",
    title: "Where the retreat comes from",
    lede: `Between 1999 and 2023 about <b>373 km&sup2;</b> of Pacific land was taken by `
        + `coastal retreat. Retreat concentrates on long, low, sediment-fed shores; deltas, spits and river mouths that rearrange themselves.`,
    note: `Quantifying gross shoreline retreat is relevant for identifying the magnitude of the hazard and gaining an initial idea of ​​potential exposure, as sand accumulation on one province's coast does not restore the assets lost by another.`,
     
    caption: `Land taken by retreat per territory, km&sup2;, 1999 to 2023, with nothing netted `
        + `off against it. Every bar points the same way and the running total only falls.`
  },
  net: {
    eyebrow: "What is left after the growth",
    title: "What the ledger closes at.",
    lede: `Set the growth against the retreat and the region's books very nearly balance. `
        + `Most territories ended the period with more land than they started with, and the `
        + `Pacific as a whole is down only about <b>51 km&sup2;</b>; roughly a seventh `
        + `of what retreat alone took. The two sides are far larger than the gap between them.`,
    note: `Net shoreline change is the way to answer how much territory a region "loses" or "gains." However, a territory can have a positive net value in terms of area because a short stretch that expands rapidly offsets a long stretch that retreats slowly.`,
    caption: `Net change per territory, km&sup2;, 1999 to 2023 &mdash; land taken by retreat `
        + `set against land added by growth. Each bar picks up where the last one stopped, so `
        + `the running total walks down and then back up. The bar marked `
        + `<span class="num">off-EEZ</span> is coast the source data could not assign to anyone.`
  }
};

function countryWaterfall() {
  const P = D.pacific, T = D.territories;
  const svg = document.getElementById("ctryWaterfall");
  const gross = wfMode === "gross", byLen = wfUnit === "length";
  const val = byLen
    ? t => gross ? -t.coast_km_retreat : t.coast_km_advance - t.coast_km_retreat
    : t => gross ? -t.area_lost_km2 : t.area_net_km2;
  const grand = byLen
    ? (gross ? -P.coast_km_retreat : P.coast_km_advance - P.coast_km_retreat)
    : (gross ? -P.area_lost_km2 : P.area_net_km2);
  const unit = byLen ? "km" : "km²";
  const residual = grand - T.reduce((s, t) => s + val(t), 0);
  const rows = T.map(t => ({ code: t.territory, name: t.name, v: val(t) }))
    .concat([{ code: "off-EEZ", name: "Off-EEZ", v: residual }])
    .sort((a, b) => a.v - b.v);

  // the labels are full names slanted under the axis, so the foot of the chart is deep
  const W = 1000, HT = 438, m = { t: 30, r: 20, b: 122, l: 58 };
  frame(svg, W, HT);
  defsFor(svg, ["hatch-gain", "hatch-loss"]);
  const r = rng(7);

  let run = 0;
  const seq = rows.map(s => { const a = run; run += s.v; return { ...s, a, b: run }; });
  seq.push({ code: "TOTAL", name: "Pacific overall", v: run, a: 0, b: run, total: true });

  const vals = seq.flatMap(s => [s.a, s.b]).concat(0);
  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo) * .12;
  const y = v => m.t + (hi + pad - v) / (hi - lo + 2 * pad) * (HT - m.t - m.b);
  const slot = (W - m.l - m.r) / seq.length, bw = slot * .62;
  const cx = i => m.l + slot * (i + .5);

  const gAx = el("g", {}, svg);
  ticks(lo - pad, hi + pad, 5).forEach(v => {
    el("path", { d: roughLine(m.l - 8, y(v), W - m.r, y(v), r, v === 0 ? .8 : .4),
      stroke: v === 0 ? "var(--ink-2)" : "var(--grid-strong)", "stroke-width": v === 0 ? 1.5 : 1,
      fill: "none", "stroke-linecap": "round" }, gAx);
    txt(gAx, m.l - 12, y(v) + 3.5, fmt(v), { "text-anchor": "end", "font-size": 10, fill: "var(--ink-3)" });
  });
  txt(gAx, m.l - 12, m.t - 13, unit, { "text-anchor": "end", "font-size": 10, fill: "var(--ink-3)" });

  const tickTop = HT - m.b + 4;

  seq.forEach((s, i) => {
    const tone = s.total ? "ink" : (s.v < 0 ? "loss" : "gain");
    const top = Math.min(y(s.a), y(s.b)), h = Math.max(2.5, Math.abs(y(s.a) - y(s.b)));
    const g = el("g", {}, svg);
    const grow = el("g", { class: "grow", style: `--d:${90 + i * 42}ms; transform-origin:${cx(i)}px ${y(s.a)}px` }, g);
    el("path", { d: roughRect(cx(i) - bw / 2, top, bw, h, r, 1),
      fill: s.total ? "none" : purl(svg, `hatch-${tone}`), stroke: `var(--${tone})`,
      "stroke-width": s.total ? 2.2 : 1.5, "stroke-linejoin": "round" }, grow);

    // horizontal labels on two staggered rows, name over code, each tied to its bar by a
    // leader. Rotated text is harder to read than a shorter line on a second row.
    const row = i % 2;
    const ly = tickTop + (row ? 40 : 8);
    const lg = el("g", { class: "fadein", style: `--d:${360 + i * 42}ms` }, svg);
    el("path", { d: `M${cx(i)} ${tickTop}V${ly - 2}`,
      stroke: s.total ? "var(--ink)" : "var(--grid-strong)",
      "stroke-width": s.total ? 1.4 : 1 }, lg);
    const lab = el("text", { x: cx(i), y: ly + 9, "text-anchor": "middle",
      "font-family": "var(--f-body)", "font-size": 8,
      fill: s.total ? "var(--ink)" : "var(--ink-2)" }, lg);
    lab.textContent = s.total ? "Pacific overall" : s.name;
    lab.setAttribute("font-weight", s.total ? 600 : 400);
    if (!s.total && s.code !== "off-EEZ")
      txt(lg, cx(i), ly + 20, s.code,
        { "text-anchor": "middle", "font-size": 8.4, fill: "var(--ink-3)" });
    el("title", {}, lg).textContent = `${s.name}: ${sign(s.v, 2)} ${unit}`;
  });

  seq.slice(0, 2).forEach((st, k) => {
    txt(svg, cx(k) + bw + 14, y((st.a + st.b) / 2) + 5, (k ? "then " : "") + st.name,
      { "font-size": 15, class: "lbl-hand fadein", style: `--d:${900 + k * 160}ms`,
        fill: "var(--loss)" });
  });
  txt(svg, cx(seq.length - 1), y(0) - 12, `${sign(run, 1)} ${unit}`,
    { "text-anchor": "middle", "font-size": 13, "font-weight": 600, fill: "var(--loss)",
      class: "fadein", style: "--d:1500ms" });

  svg.setAttribute("aria-label", gross
    ? `Chart of land taken by coastal retreat in each territory, km². Nothing is set against `
      + `it, so the running total falls all the way to ${fmt(Math.abs(run), 0)} square kilometres.`
    : `Chart of net land change per territory, km², running from zero down through `
      + `${seq[0].name} and ${seq[1].name} and back up through the territories that grew, `
      + `ending at ${sign(run, 0)} square kilometres for the region.`);

  const C = WF_COPY[wfMode];
  document.querySelectorAll("[data-wfunit]").forEach(b =>
    b.setAttribute("aria-pressed", String(b.dataset.wfunit === wfUnit)));
  const put = (id, html) => { const n = document.getElementById(id); if (n) n.innerHTML = html; };
  put("wfCap", byLen
    ? (gross
        ? `Kilometres of coast clearly moving inland per territory, 1999 to 2023. The same `
          + `question as the area chart, asked of length instead: not how much ground went, `
          + `but how much shoreline is on the move.`
        : `Kilometres of coast building out set against kilometres moving inland, per `
          + `territory. A positive bar means more of that country's shoreline is growing `
          + `than retreating &mdash; which is not the same as it gaining ground.`)
    : C.caption);
  put("wfEyebrow", C.eyebrow);
  put("wfTitle", C.title);
  put("wfLede", C.lede);
  put("wfNote", C.note);
  document.querySelectorAll("[data-wf]").forEach(b =>
    b.setAttribute("aria-pressed", String(b.dataset.wf === wfMode)));
}

/* Two denominators for the same retreating kilometres: the coast that passed the quality
   check, and every point the record holds. The true share is somewhere between. */
const pctOfAll = t => t.coast_km_total ? t.coast_km_retreat / t.coast_km_total * 100 : null;
const pctPalette = "petal";

function pctChart() {
  const svg = document.getElementById("pctChart");
  const rows = [...D.territories].sort((a, b) => pctOfAll(b) - pctOfAll(a));
  const W = 560, rowH = 17, m = { t: 26, r: 54, b: 26, l: 46 };
  const HT = m.t + rows.length * rowH + m.b;
  frame(svg, W, HT);
  defsFor(svg, ["hatch-loss"]);
  const r = rng(33);
  const top = Math.ceil(Math.max(...rows.map(pctOfAll)) / 5) * 5;
  const x = v => m.l + v / top * (W - m.l - m.r);

  ticks(0, top, 4).forEach(v => {
    el("path", { d: roughLine(x(v), m.t - 9, x(v), HT - m.b + 4, r, .4),
      stroke: "var(--grid-strong)", "stroke-width": 1, fill: "none" }, svg);
    txt(svg, x(v), m.t - 14, v + "%", { "text-anchor": "middle", "font-size": 11, fill: "var(--ink-3)" });
  });

  /* graded by value out of the chosen palette's retreat ramp, so the ranking reads as a
     ramp rather than three arbitrary buckets */
  const cols = ramp([...HIST_PALETTES[pctPalette].retreat].reverse(), 5);
  const band = v => Math.min(4, Math.floor(v / (top / 5)));

  rows.forEach((t, i) => {
    const yy = m.t + i * rowH, h = rowH - 6, share = pctOfAll(t);
    const g = el("g", {}, svg);
    txt(g, m.l - 8, yy + h - 1, t.territory, { "text-anchor": "end", "font-size": 9.8, fill: "var(--ink-2)" });
    const grow = el("g", { class: "fadein", style: `--d:${i * 34}ms` }, g);
    el("path", { d: roughRect(m.l, yy, Math.max(1.6, x(share) - m.l), h, r, .9),
      fill: cols[band(share)],
      stroke: "var(--ink-3)", "stroke-width": .8, "stroke-linejoin": "round" }, grow);
    txt(grow, x(share) + 7, yy + h - 1, fmt(share, 1) + "%",
      { "font-size": 9.4, fill: "var(--ink-2)" });
    el("title", {}, g).textContent =
      `${t.name}: ${fmt(t.coast_km_retreat)} km retreating of the ${fmt(t.coast_km_total)} km `
      + `the record holds`;
  });

  const leg = document.getElementById("pctLegend");
  if (leg) leg.innerHTML = cols.map((c, i) => {
    const lo = (top / 5 * i).toFixed(0), hi = (top / 5 * (i + 1)).toFixed(0);
    return `<li><span class="swatch" style="color:var(--ink-3);background:${c}"></span>`
      + `${i === 4 ? `${lo}%+` : `${lo}–${hi}%`}</li>`;
  }).join("");
}

/* Kiribati, described on its own terms. The card exists to show that length and area
   answer different questions, which needs one country, not a league table. */
function kiribatiCards() {
  const K = D.territories.find(t => t.territory === "KIR");
  if (!K) return;
  const set = (id, v) => { const n = document.getElementById(id); if (n) n.innerHTML = v; };
  set("shKirGood", fmt(K.n_transects));
  set("shKirGoodKm", fmt(K.coast_km_assessed));
  set("shKirRetKm", fmt(K.coast_km_retreat, 1));
  set("shKirPctGood", fmt(K.pct_coast_retreat, 1) + "%");
  set("shKirAll", fmt(K.n_points_all));
  set("shKirAllKm", fmt(K.coast_km_total));
  set("shKirPctAll", fmt(pctOfAll(K), 1) + "%");
}

/* ---- the register: how the cloth in app/img is actually painted. A broad band of the
   dye carrying a repeated cream wave, ruled off top and bottom. One per tone, so a bar
   is a length of cloth rather than a rectangle with hatching in it. ---- */
function registersFor(svg, tones, { plain = [], h = 15 } = {}) {
  const defs = el("defs", {}, svg);
  const w = h * 1.75;                       // one full wave per tile, whatever the height
  const k = h / 15;                         // every weight scales with the tile
  // a plain register: the dye and its two rules, no wave. The cloth alternates plain
  // bands with waved ones, and nesting two waved bands makes both unreadable.
  plain.forEach(t => {
    const p = el("pattern", { id: pid(svg, `reg-plain-${t}`), width: w, height: h,
                              patternUnits: "userSpaceOnUse" }, defs);
    el("rect", { width: w, height: h, fill: `var(--${t})`, opacity: .42 }, p);
    el("path", { d: `M0 ${1.4 * k}H${w}`, stroke: "var(--paper)",
                 "stroke-width": Math.max(.6, 1.1 * k), opacity: .7 }, p);
    el("path", { d: `M0 ${h - 1.1 * k}H${w}`, stroke: "var(--paper)",
                 "stroke-width": Math.max(.5, .9 * k), opacity: .5 }, p);
  });
  tones.forEach(t => {
    const p = el("pattern", { id: pid(svg, `reg-${t}`), width: w, height: h,
                              patternUnits: "userSpaceOnUse" }, defs);
    el("rect", { width: w, height: h, fill: `var(--${t})` }, p);
    const wave = `M0 ${h * .66}Q${w * .125} ${h * .3} ${w * .25} ${h * .66}`
               + `T${w * .5} ${h * .66}T${w * .75} ${h * .66}T${w} ${h * .66}`;
    el("path", { d: wave, fill: "none", stroke: "var(--paper)",
                 "stroke-width": Math.max(1, 2.4 * k), "stroke-linecap": "round" }, p);
    el("path", { d: `M0 ${1.4 * k}H${w}`, stroke: "var(--paper)",
                 "stroke-width": Math.max(.6, 1.1 * k), opacity: .55 }, p);
    el("path", { d: `M0 ${h - 1.1 * k}H${w}`, stroke: "var(--paper)",
                 "stroke-width": Math.max(.5, .9 * k), opacity: .38 }, p);
  });
}

/* ================================================================
   03  one register of cloth, cut into three
   Everyone in the region is the whole band. The coastal kilometre is a piece of
   it, and the retreating coast a piece of that - so the three figures are drawn
   as they actually sit: nested, not stacked side by side.
   ================================================================ */
function peopleBar() {
  const svg = document.getElementById("peopleBar");
  if (!svg) return;
  const W = 760, HT = 262, m = { t: 58, r: 22, b: 112, l: 22 };
  frame(svg, W, HT);
  // one compact register, the same tile the per-country rows use: at 96 px the bar
  // stacks six of them, at 16 px a row carries one, and the motif is the same either way
  registersFor(svg, ["ink-3", "people", "loss"], { h: 8 });
  const r = rng(5);

  const full = W - m.l - m.r, bandH = HT - m.t - m.b, base = m.t + bandH;
  const x = v => m.l + v / POP.total * full;

  /* The fastest band is two tenths of a per cent - a hairline at this width. It is drawn
     with a floor of four pixels so it can be seen at all; the figure beside it is exact. */
  const parts = [
    { a: 0, b: POP.total - POP.coastal, tone: "ink-3" },
    { a: POP.total - POP.coastal, b: POP.total - POP.retreat, tone: "people" },
    { a: POP.total - POP.retreat, b: POP.total - POP.fast, tone: "loss" },
    { a: POP.total - POP.fast, b: POP.total, tone: "loss-deep", flat: true }
  ];
  parts.forEach((p, i) => {
    const x0 = x(p.a), w = Math.max(4, x(p.b) - x(p.a));
    const g = el("g", { class: "fadein", style: `--d:${140 + i * 180}ms` }, svg);
    el("rect", { x: x0, y: m.t, width: w, height: bandH,
      fill: p.flat ? `var(--${p.tone})` : purl(svg, `reg-${p.tone}`),
      "fill-opacity": p.flat ? .95 : 1 }, g);
    el("path", { d: roughRect(x0, m.t, w, bandH, r, .9), fill: "none",
      stroke: "var(--ink-2)", "stroke-width": 1.2, "stroke-linejoin": "round",
      opacity: .55 }, g);
    // a cut in the cloth between registers, so neighbouring dyes cannot bleed together
    if (i) el("rect", { x: x0 - 1.5, y: m.t - 1, width: 3, height: bandH + 2,
      fill: "var(--paper)" }, g);
  });

  /* the two subsets are narrow and sit at the same end of the band, so they are
     called out on separate rows underneath, each label running back into open paper */
  [
    { k: "lives on the coast", v: POP.coastal, at: POP.total - POP.coastal,
      tone: "people", row: 0 },
    { k: "lives where it is retreating", v: POP.retreat, at: POP.total - POP.retreat,
      tone: "loss", row: 1 },
    { k: "lives where it is retreating more than 5 m a year", v: POP.fast,
      at: POP.total - POP.fast, tone: "loss-deep", row: 2 }
  ].forEach((b, i) => {
    const x0 = x(b.at), ly = base + 44 + b.row * 20;
    const g = el("g", { class: "fadein", style: `--d:${520 + i * 200}ms` }, svg);
    el("path", { d: `M${x0} ${base + 2}V${ly - 5}`, stroke: `var(--${b.tone})`,
      "stroke-width": 1.2 }, g);
    // value first and large, then what it counts: the number is the point of the line
    const t = el("text", { x: x0 - 8, y: ly, "text-anchor": "end" }, g);
    const big = el("tspan", { "font-size": 13, "font-weight": 600,
      fill: `var(--${b.tone})` }, t);
    big.textContent = fmt(b.v);
    const pct = el("tspan", { "font-size": 10.5, fill: `var(--${b.tone})` }, t);
    pct.textContent = `  ${fmt(b.v / POP.total * 100, 1)}%`;
    const lab = el("tspan", { "font-size": 10.5, fill: "var(--ink-2)" }, t);
    lab.textContent = `   ${b.k}`;
  });

  const tot = el("text", { x: m.l, y: m.t - 16 }, svg);
  const totBig = el("tspan", { "font-size": 16, "font-weight": 700, fill: "var(--ink)" }, tot);
  totBig.textContent = fmt(POP.total);
  const totLab = el("tspan", { "font-size": 12, fill: "var(--ink-2)" }, tot);
  totLab.textContent = "   everyone in the region";
  txt(svg, m.l, base + 24, `${fmt(POP.total - POP.coastal)} live away from the coast`,
    { "font-size": 12, fill: "var(--ink-3)" });

  txt(svg, m.l, HT - 8, "1 km squares · WorldPop 2020 over the 2021 shoreline",
    { "font-size": 11, fill: "var(--ink-3)" });

  svg.setAttribute("aria-label",
    `One band standing for all ${fmt(POP.total)} people mapped across the twenty-two `
    + `territories. ${fmt(POP.coastal)} of them, ${fmt(POP.coastal / POP.total * 100, 1)} `
    + `per cent, live in a grid square the coast runs through, ${fmt(POP.retreat)}, `
    + `${fmt(POP.retreat / POP.total * 100, 1)} per cent, in one where that coast is `
    + `retreating, and ${fmt(POP.fast)} where it is retreating faster than five metres a year.`);

  document.getElementById("peopleCap").innerHTML =
    `Of the <span class="num">${fmt(POP.total)}</span> people mapped across the 22 territories, `
    + `<span class="num">${fmt(POP.retreat)}</span> live in a square kilometre the retreating `
    + `coast runs through. Roughly one person in fourteen.`;

  const setStat = (id, v, pct, dec) => {
    const n = document.getElementById(id);
    if (n) n.textContent = `${fmt(v)} (${fmt(pct, dec)}%)`;
  };
  setStat("peopleRetreatBig", POP.retreat, POP.retreat / POP.total * 100, 1);
  setStat("peopleFastBig", POP.fast, POP.fast / POP.total * 100, 1);
}

/* ---- which territories need reading differently, and why. Derived from the data
   rather than listed by hand, so a rebuild cannot leave a caveat pointing at the
   wrong country. ---- */
function caveatsFor(t) {
  const out = [];
  if (t.pct_coastal >= 90) out.push({
    h: "No inland to speak of",
    p: `A grid square is a kilometre across and ${t.name} is narrower than that almost `
     + `everywhere, so ${fmt(t.pct_coastal, 1)}% of its people fall inside a coastal square `
     + `by geometry, not by choice. The first bar is close to a definition here. The number `
     + `that carries information is the second one: `
     + `<b>${fmt(t.pct_retreat, 1)}%</b> live where that coast is retreating.`
  });
  const kept = t.n_points_all ? t.n_transects / t.n_points_all : 1;
  if (kept < .35) out.push({
    h: "A thin record",
    p: `Only ${fmt(kept * 100, 0)}% of ${t.name}'s measurement points passed the quality `
     + `check &mdash; ${fmt(t.n_transects)} of ${fmt(t.n_points_all)}. The retreat shown here `
     + `is measured across ${fmt(t.coast_km_assessed)} km of a ${fmt(t.coast_km_total)} km `
     + `coast. A low share may mean the coast is holding, or may mean the record could not `
     + `look at it. Read it as a floor, not an estimate.`
  });
  if (t.pop_total < 1500) out.push({
    h: "Too few people for a share",
    p: `${t.name} has ${fmt(t.pop_total)} people in the 2020 grid. A percentage of a `
     + `population that small moves several points if one household is counted differently, `
     + `so the bar is drawn but should not be ranked against the others.`
  });
  return out;
}

function showCaveat(t) {
  const pop = document.getElementById("pop-caveat");
  if (!pop) return;
  const list = caveatsFor(t);
  document.getElementById("caveatTitle").textContent = t.name;
  document.getElementById("caveatBody").innerHTML =
    list.map(c => `<p><strong>${c.h}.</strong> ${c.p}</p>`).join("");
  pop.showPopover();
}

/* Each row is the country's whole population laid out end to end, cut where the coast
   starts and again where that coast is retreating. Flat colour, not cloth: twenty-two
   rows of woven registers at this height turned the shares into texture, and the shares
   are the point. The cloth stays on the one region bar above, where it has room. */
function popChart() {
  const svg = document.getElementById("popChart");
  const rows = [...D.territories].sort((a, b) => b.pct_retreat - a.pct_retreat);
  const W = 830, rowH = 26, m = { t: 62, r: 172, b: 30, l: 152 };
  const HT = m.t + rows.length * rowH + m.b;
  frame(svg, W, HT);
  const r = rng(12);
  const full = W - m.l - m.r;
  const x = v => m.l + v / 100 * full;

  [0, 25, 50, 75, 100].forEach(v => {
    el("path", { d: roughLine(x(v), m.t - 10, x(v), HT - m.b + 2, r, .4),
      stroke: "var(--grid-strong)", "stroke-width": 1, fill: "none" }, svg);
    txt(svg, x(v), m.t - 15, v + "%", { "text-anchor": "middle", "font-size": 11, fill: "var(--ink-3)" });
  });
  txt(svg, m.l, m.t - 30, "every person in the country, left to right",
    { "font-size": 11, fill: "var(--ink-3)" });
  txt(svg, W - m.r + 10, m.t - 41, "people where", { "font-size": 11, fill: "var(--ink-3)" });
  txt(svg, W - m.r + 10, m.t - 30, "it is retreating", { "font-size": 11, fill: "var(--ink-3)" });

  rows.forEach((t, i) => {
    const yy = m.t + i * rowH, h = rowH - 8;
    const caveats = caveatsFor(t);
    const g = el("g", { class: "fadein", style: `--d:${i * 30}ms` }, svg);
    txt(g, m.l - (caveats.length ? 28 : 9), yy + h - 3, t.name,
      { "text-anchor": "end", "font-size": 11.5, fill: "var(--ink-2)" });
    if (caveats.length) {
      const bx = m.l - 17, by = yy + h / 2 - 1;
      const mark = el("g", { class: "cav", tabindex: 0, role: "button",
        style: "cursor:pointer" }, g);
      mark.setAttribute("aria-label", `${t.name}: read this one with a caveat`);
      el("circle", { cx: bx, cy: by, r: 5.6, fill: "var(--paper-2)",
        stroke: "var(--ink-3)", "stroke-width": 1.1 }, mark);
      txt(mark, bx, by + 3.4, "i", { "text-anchor": "middle", "font-size": 9,
        "font-weight": 600, fill: "var(--ink-2)" });
      el("title", {}, mark).textContent = caveats.map(c => c.h).join(" · ");
      const open = e => { e.stopPropagation(); showCaveat(t); };
      mark.addEventListener("click", open);
      mark.addEventListener("keydown", e => {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(e); }
      });
    }

    /* four bands end to end: inland, coastal but holding, retreating, retreating fast */
    const inland = Math.max(0, 100 - t.pct_coastal);
    const fast = t.pct_fast || 0;
    const parts = [
      { a: 0, b: inland, fill: "var(--ink-3)", op: .2 },
      { a: inland, b: 100 - t.pct_retreat, fill: "var(--people)", op: .55 },
      { a: 100 - t.pct_retreat, b: 100 - fast, fill: "var(--loss)", op: .95 },
      { a: 100 - fast, b: 100, fill: "var(--loss-deep)", op: 1 }
    ];
    parts.forEach(p => {
      const w = x(p.b) - x(p.a);
      if (w < .4) return;
      el("rect", { x: x(p.a), y: yy, width: w, height: h,
        fill: p.fill, "fill-opacity": p.op }, g);
    });
    el("rect", { x: m.l, y: yy, width: full, height: h, fill: "none",
      stroke: "var(--grid-strong)", "stroke-width": 1 }, g);

    // value then share, so a large country and a wholly exposed one can be told apart
    const val = el("text", { x: W - m.r + 10, y: yy + h - 3 }, g);
    el("tspan", { "font-size": 11.5, "font-weight": 600, fill: "var(--loss)" }, val)
      .textContent = fmt(t.pop_retreat_1km);
    el("tspan", { "font-size": 11, fill: "var(--ink-3)" }, val)
      .textContent = `  ${fmt(t.pct_retreat, 1)}%`;
    el("title", {}, g).textContent = `${t.name}: ${fmt(t.pop_retreat_1km)} of `
      + `${fmt(t.pop_total)} people (${fmt(t.pct_retreat, 1)}%) live where the coast is `
      + `retreating, ${fmt(t.pop_fast_1km)} of them where it retreats faster than 5 m a `
      + `year; ${fmt(t.pct_coastal, 1)}% live in a coastal square at all`;
  });
}

/* ================================================================
   MAPS
   ================================================================ */
/* Every colour handed to MapLibre has to be something its parser understands, and that
   is hex / rgb / hsl / named only. The cloth skin's tokens are oklch(), which the parser
   rejects outright - addLayer then throws and the map ends up with no layers at all.
   Resolve through a canvas so any CSS colour comes back as rgb() or rgba(). */
function cssColour(v) {
  if (!v) return "rgba(0,0,0,0)";
  const cv = cssColour._c || (cssColour._c = document.createElement("canvas"));
  cv.width = cv.height = 1;
  const g = cv.getContext("2d", { willReadFrequently: true });
  g.clearRect(0, 0, 1, 1);
  g.fillStyle = "rgba(0,0,0,0)";
  g.fillStyle = v;                       // invalid values leave the previous value in place
  g.fillRect(0, 0, 1, 1);
  const d = g.getImageData(0, 0, 1, 1).data;
  return d[3] === 255
    ? `rgb(${d[0]},${d[1]},${d[2]})`
    : `rgba(${d[0]},${d[1]},${d[2]},${(d[3] / 255).toFixed(3)})`;
}

const rawToken = n =>
  getComputedStyle(document.documentElement).getPropertyValue("--" + n).trim();
const ink = n => cssColour(rawToken(n));


const MAPS = {};

/* The slim archive bakes the quality filters in and drops those columns, so these
   predicates are only added when the full DEP archive is being served. */
const goodOnly = () => TILES.prefiltered ? [] : [["==", ["get", "certainty"], "good"]];
const sigOnly  = () => TILES.prefiltered ? []
  : [["==", ["get", "certainty"], "good"], ["<", ["get", "sig_time"], 0.01]];
const yearFilter = y => ["all", ["==", ["get", "year"], y], ...goodOnly()];

/* A .pmtiles URL is read straight out of a static file via the pmtiles:// protocol
   (browser-side range requests, no server); an XYZ {z}/{x}/{y} template still goes
   through the local `pmtiles serve` CLI as before - so local dev and the production
   deploy both work off the same TILES.* values without touching serve.R. */
function tileSource(url) {
  return /\.pmtiles(\?.*)?$/i.test(url) ? { url: `pmtiles://${url}` } : { tiles: [url] };
}

function baseStyle(withSatellite) {
  const sources = {
    dep: { type: "vector", ...tileSource(TILES.tiles), minzoom: 0, maxzoom: TILES.maxzoom,
           attribution: "Digital Earth Pacific Coastlines v0.7.0-55" },
    bnd: { type: "geojson", data: "data/boundaries.geojson" }
  };
  const layers = [{ id: "paper", type: "background",
                    paint: { "background-color": ink("paper-3") } }];

  if (withSatellite) {
    sources.sat = { type: "raster", tiles: [SAT_URL], tileSize: 256, maxzoom: 18,
                    attribution: "Imagery &copy; Esri" };
    layers.push({ id: "satellite", type: "raster", source: "sat",
                  paint: { "raster-opacity": 1 } });
  }
  if (TILES.populationRaster) {
    sources.popr = { type: "raster", ...tileSource(TILES.populationRaster), tileSize: 256,
                     minzoom: 0, maxzoom: TILES.populationRasterMaxzoom || 7,
                     attribution: "WorldPop R2024B 2020" };
  }
  return { version: 8, sources, layers };
}

/* shorelines for one year, plus an optional ghost of an earlier one */
function shoreLayers(year, ghost) {
  const L = [];
  if (ghost !== null && ghost !== undefined) L.push({
    id: "shore-ghost", type: "line", source: "dep", "source-layer": "shorelines_annual",
    filter: yearFilter(ghost),
    paint: { "line-color": ink("ink-3"),
             "line-width": ["interpolate", ["linear"], ["zoom"], 2, 1.2, 8, 1.2, 13, 2],
             "line-opacity": .6, "line-dasharray": [3, 3] }
  });
  L.push({
    id: "shore-year", type: "line", source: "dep", "source-layer": "shorelines_annual",
    filter: yearFilter(year),
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": ink("ink"),
      // sub-pixel strokes antialias away at region scale, so keep real weight zoomed out
      "line-width": ["interpolate", ["linear"], ["zoom"], 2, 1.6, 5, 1.4, 8, 1.6, 11, 2.4, 13, 3.2]
    }
  });
  return L;
}

const dirColour = () => ["case", ["<", ["get", "rate_time"], 0], ink("loss"), ink("gain")];

/* the pale trail of every annual shoreline, oldest palest, newest in the retreat ink */
const trailRamp = (a = 1999, b = 2023) => ["interpolate", ["linear"], ["get", "year"],
  a, ink("ink-3"), b, ink("loss")];

/* one trail layer, two maps: the drawer close-up and the glyph card. Each keeps its own
   year range on the map object so a theme flip repaints it correctly. */
function addTrail(map, from, to) {
  map.__trail = [from, to];
  map.addLayer({
    id: "shore-trail", type: "line", source: "dep", "source-layer": "shorelines_annual",
    filter: ["all", [">=", ["get", "year"], from], ["<=", ["get", "year"], to], ...goodOnly()],
    layout: { "line-cap": "round" },
    paint: { "line-color": trailRamp(from, to), "line-width": 1.3, "line-opacity": .6 }
  });
}

/* Population as a raster grid, not a scatter. The archive is a real 1 km grid at its
   native resolution (z0-7); nearest-neighbour overzoom keeps the cells square instead of
   smearing them, so what you see on screen is the grid the data actually has. */
const popRasterLayer = () => ({
  id: "people", type: "raster", source: "popr",
  paint: {
    "raster-opacity": ["interpolate", ["linear"], ["zoom"], 3, .78, 9, .82, 13, .72],
    "raster-resampling": "nearest",
    "raster-fade-duration": 120
  }
});

const bndLayer = () => ({
  id: "bnd-line", type: "line", source: "bnd",
  paint: { "line-color": ink("ink-3"), "line-width": 1, "line-opacity": .5,
           "line-dasharray": [4, 3] }
});

/* A layer toggle can be clicked before its layer exists: the maps are built lazily as
   you scroll and their styles settle asynchronously after that, so an early click used to
   flip the button and nothing else, leaving the two out of step for good. The wanted state
   lives on the button, and is applied both on click and once the layers land. */
function bindLayerToggle(map, btnId, layerIds, after) {
  const b = document.getElementById(btnId);
  if (!b) return;
  const apply = () => {
    const on = b.getAttribute("aria-pressed") === "true";
    [].concat(layerIds).forEach(l => {
      if (map.getLayer(l)) map.setLayoutProperty(l, "visibility", on ? "visible" : "none");
    });
    if (after) after(on);
  };
  b.onclick = () => {
    b.setAttribute("aria-pressed", String(b.getAttribute("aria-pressed") !== "true"));
    apply();
  };
  (map.__syncLayers || (map.__syncLayers = [])).push(apply);
}
const syncLayerToggles = map => (map.__syncLayers || []).forEach(f => f());

/* a reset-view button, which MapLibre does not ship */
class HomeControl {
  constructor(view) { this.view = view; }
  onAdd(map) {
    const d = document.createElement("div");
    d.className = "maplibregl-ctrl maplibregl-ctrl-group";
    const b = document.createElement("button");
    b.type = "button";
    b.title = "Reset the view";
    b.setAttribute("aria-label", "Reset the view");
    b.className = "reset-ctrl";
    b.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" width="15" height="15">'
      + '<path d="M3 12a9 9 0 1 0 3-6.7" fill="none" stroke="currentColor" stroke-width="2.2"'
      + ' stroke-linecap="round"/><path d="M3 4v5h5" fill="none" stroke="currentColor"'
      + ' stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
      + '<span class="reset-label">Reset</span>';
    b.onclick = () => map.easeTo({ center: this.view.center, zoom: this.view.zoom,
                                   duration: reduce ? 0 : 900 });
    d.appendChild(b);
    this.el = d;
    return d;
  }
  onRemove() { this.el.remove(); }
}

/* `load` waits for every source in the style, including the remote satellite raster.
   If Esri is slow or unreachable that event never fires and no layer ever gets added,
   so hang layer creation off the style being parsed instead. */
function onStyle(map, fn) {
  // Getting this right matters more than it looks. `load` waits on every source in the
  // style, so a slow remote raster stalls it forever. `styledata` fires once, early,
  // before isStyleLoaded() is true - and for a fully inline style it never fires again,
  // so guarding on it alone means the callback never runs. Listen to both and poll.
  let done = false, timer = null;
  const run = () => {
    if (done) return;
    done = true;
    map.off("styledata", attempt);
    map.off("load", attempt);
    if (timer) clearInterval(timer);
    try { fn(); } catch (e) { mapFail(map, e); }
  };
  const attempt = () => { if (map.isStyleLoaded()) run(); };

  if (map.isStyleLoaded()) { run(); return; }
  map.on("styledata", attempt);
  map.on("load", attempt);
  timer = setInterval(attempt, 60);
  setTimeout(() => { if (!done) run(); }, 8000);   // last resort, never leave it blank
}


/* a failure should say so in the map box, not vanish into the console */
function mapFail(map, e) {
  console.error("map layer setup failed", e);
  const box = map.getContainer();
  const load = box && document.getElementById(box.id + "Load");
  if (load) {
    load.hidden = false;
    load.textContent = "map couldn't load — try refreshing the page";
    load.style.color = "var(--loss)";
  }
}

function makeMap(id, opts = {}) {
  const map = new maplibregl.Map(Object.assign({
    container: id,
    style: baseStyle(opts.satellite),
    attributionControl: { compact: true },
    dragRotate: false,
    maxZoom: 15.5,
    // only for offline capture: lets a tool read the rendered map off the canvas
    preserveDrawingBuffer: window.__CAPTURE__ === true
  }, opts));
  map.touchZoomRotate.disableRotation();

  // Containers are sized by aspect-ratio, so the box can still be resolving when the map
  // is built. A zero-size viewport asks for no tiles, and MapLibre only tracks *window*
  // resizes, so watch the element itself.
  const box = document.getElementById(id);
  // Only resize when the box genuinely changed size. Calling resize() unconditionally
  // resizes the canvas, which retriggers the observer, which resizes again - a loop that
  // keeps invalidating the transform so the source never settles on tiles to request.
  if (window.ResizeObserver) {
    let lastW = 0, lastH = 0;
    new ResizeObserver(entries => {
      const r = entries[0].contentRect;
      const w = Math.round(r.width), h = Math.round(r.height);
      if (!w || !h || (w === lastW && h === lastH)) return;
      lastW = w; lastH = h;
      map.resize();
    }).observe(box);
  }

  map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");
  map.addControl(new maplibregl.FullscreenControl({ container: box.parentElement }), "top-right");
  if (opts.home) map.addControl(new HomeControl(opts.home), "top-right");
  map.addControl(new maplibregl.ScaleControl({ maxWidth: 110, unit: "metric" }), "bottom-right");

  // never gate the overlay on `idle`; with a heavy source it may be a long time coming
  const load = document.getElementById(id + "Load");
  const done = () => { if (load) load.hidden = true; };
  map.on("load", done);
  map.on("sourcedata", e => { if (e.isSourceLoaded) done(); });
  map.on("error", e => {
    console.error("map", id, "- tile server unreachable, is `Rscript app/serve.R` running?", e.error || e);
    if (load) load.textContent = "map couldn't load — try refreshing the page";
  });
  setTimeout(done, 4000);

  MAPS[id] = map;
  return map;
}

/* MapLibre needs literal colours, so every themed paint property is reset on a flip */
function repaintMaps() {
  const set = (m, id, prop, val) => { if (m.getLayer(id)) m.setPaintProperty(id, prop, val); };
  Object.values(MAPS).forEach(m => {
    if (!m.isStyleLoaded || !m.isStyleLoaded()) return;
    set(m, "paper", "background-color", ink("paper-3"));
    set(m, "shore-year", "line-color", ink("ink"));
    set(m, "shore-ghost", "line-color", ink("ink-3"));
    set(m, "shore-focus", "line-color", ink("loss"));
    set(m, "bnd-line", "line-color", ink("ink-3"));
    set(m, "choro-line", "line-color", ink("ink-3"));
    set(m, "choro-sel", "line-color", ink("ink"));

    set(m, "trend", "circle-color", dirColour());
    set(m, "dir", "circle-color", dirColour());
    set(m, "shore-trail", "line-color", trailRamp(...(m.__trail || [1999, 2023])));
    set(m, "choro", "fill-color", choroExpr(metric));
  });
  if (document.getElementById("choroScale")) drawChoroScale();
}

/* The region map's furniture: dashed sea borders plus one clickable ISO label per
   territory. The drawer map takes the same pair, so moving between the two reads as
   one map rather than two unrelated ones - it just dims the labels it is not on. */
function addRegionFurniture(map, { track = false, borders = true } = {}) {
  if (borders && !map.getLayer("bnd-line")) map.addLayer(bndLayer());
  const marks = {};
  D.territories.forEach(t => {
    const d = document.createElement("div");
    d.className = "tlabel";
    d.textContent = t.territory;
    d.title = `${t.name} — ${fmt(t.pct_coast_retreat, 1)}% of coast retreating`;
    if (t.pct_coast_retreat >= 20) d.dataset.on = "1";
    d.onclick = () => selectTerritory(t.territory, true);
    new maplibregl.Marker({ element: d })
      .setLngLat([(t.w + t.e) / 2, (t.s + t.n) / 2]).addTo(map);
    marks[t.territory] = d;
  });
  if (track) {
    map.markSelected = code => Object.entries(marks).forEach(([k, d]) => {
      if (k === code) d.dataset.sel = "1"; else delete d.dataset.sel;
    });
    map.markSelected(selected);
  }
}

/* ================================================================
   04  patterns of movement
   Two hundred stretches of coast, each drawn straight out of shorelines_annual by
   R/17_shoreline_glyphs.R. The SVGs are pulled in as a CSS mask rather than an <img>
   so they take the page's ink and follow the skin; they are cached like any image.
   ================================================================ */
let GLYPHS = [], glyphSort = "rate", glyphDir = "all", glyphOpen = null;
const TILE_CAP = 12;    // tiles per territory band; the note reports the real total
const GLYPH_CUT = 5;    // m/yr, the bar a stretch has to clear to get a glyph at all

/* The glyphs are drawn with hairline, part-transparent strokes so the older years fade
   out. A CSS mask flattens that to alpha and the whole tile disappears, so the SVG is
   inlined instead and the stroke weight lifted in CSS - the year fade survives, and the
   marks take the tile's ink. Fetched only as a tile comes into view, and cached, because
   the same site appears in both sort orders. */
const glyphCache = new Map();
const glyphWatcher = new IntersectionObserver(es => es.forEach(e => {
  if (!e.isIntersecting) return;
  glyphWatcher.unobserve(e.target);
  paintGlyph(e.target.querySelector(".gt-art"), e.target.dataset.src);
}), { rootMargin: "300px" });

function paintGlyph(host, url) {
  if (!host || !url || host.dataset.done) return;
  const put = svg => { host.innerHTML = svg; host.dataset.done = "1"; };
  if (glyphCache.has(url)) return put(glyphCache.get(url));
  fetch(url).then(r => r.ok ? r.text() : Promise.reject(r.status)).then(t => {
    const svg = t.slice(t.indexOf("<svg"));
    glyphCache.set(url, svg);
    put(svg);
  }).catch(e => console.warn("glyph", url, e));
}

const GLYPH_KIND = {
  retreat: { tone: "loss", word: "retreating", verb: "moving inland" },
  gain:    { tone: "gain", word: "growing",    verb: "building out" }
};

// two hundred of these stretches have nobody near them at all, and "about 0 people" is
// a clumsy way to say so
const peopleNear = n => n > 0 ? `about ${fmt(n)} people within about 2 km`
                              : `nobody living within about 2 km`;

const GLYPH_SORT = {
  rate: { key: g => Math.abs(g.rate_m_yr), unit: g => `${fmt(Math.abs(g.rate_m_yr), 0)} m/yr` },
  pop:  { key: g => g.pop_near || 0,       unit: g => fmt(g.pop_near || 0) }
};

/* One grid, both directions. Every stretch moving at least GLYPH_CUT m a year earns a
   glyph; the grid shows the fastest hundred of them under whichever order is chosen, and
   the caption carries the full count so the hundred is never read as the whole set.
   The mix itself carries information: order by speed and it is nearly all river mouths,
   order by people and it is nearly all towns. */
function buildGlyphGrid() {
  const box = document.getElementById("glyphGrid");
  if (!box || !GLYPHS.length) return;
  const S = GLYPH_SORT[glyphSort];
  const pool = glyphDir === "all" ? GLYPHS : GLYPHS.filter(g => g.kind === glyphDir);
  const rows = [...pool].sort((a, b) => S.key(b) - S.key(a)).slice(0, 100);
  box.innerHTML = "";

  rows.forEach(g => {
    const K = GLYPH_KIND[g.kind];
    // not every site has a named place within reach - fall back to the territory
    // itself rather than showing a blank or a bare internal code
    const place = g.place || g.admin || g.country;
    const b = document.createElement("button");
    b.type = "button";
    b.className = "gtile";
    b.dataset.kind = g.kind;
    b.dataset.src = g.glyph;
    b.dataset.id = g.id;
    b.title = `${place} — ${g.country} · ${fmt(Math.abs(g.rate_m_yr), 1)} m a year`
      + `, ${peopleNear(g.pop_near || 0)}`;
    b.setAttribute("aria-label",
      `${place}, ${g.country}: coast ${K.verb} ${fmt(Math.abs(g.rate_m_yr), 1)} metres a `
      + `year, ${peopleNear(g.pop_near || 0)}`);
    b.innerHTML = `<span class="gt-art" aria-hidden="true"></span>`
      + `<span class="gt-lab"><b>${g.place || g.territory}</b> ${S.unit(g)}</span>`;
    b.onclick = () => openGlyph(g, b);
    box.appendChild(b);
    // observed only once it is in the document - an IntersectionObserver given a detached
    // element never reports it, which is what left every tile in the grid blank
    glyphWatcher.observe(b);
  });

  document.querySelectorAll("[data-gsort]").forEach(x =>
    x.setAttribute("aria-pressed", String(x.dataset.gsort === glyphSort)));
  document.querySelectorAll("[data-gdir]").forEach(x =>
    x.setAttribute("aria-pressed", String(x.dataset.gdir === glyphDir)));

  const nRet = rows.filter(g => g.kind === "retreat").length;
  const withPeople = rows.filter(g => g.pop_near > 0).length;
  const totRet = GLYPHS.filter(g => g.kind === "retreat").length;
  const totGain = GLYPHS.length - totRet;
  const shown = rows.length;
  const cap = document.getElementById("glyphCap");
  const order = glyphSort === "rate"
    ? "rate" : "how many people live within about two kilometres";

  if (cap && glyphDir !== "all") {
    const K = GLYPH_KIND[glyphDir];
    const tot = glyphDir === "retreat" ? totRet : totGain;
    cap.innerHTML = `<span class="num">${fmt(tot)}</span> stretches of Pacific coast are `
      + `${K.word} at ${GLYPH_CUT} metres a year or more. The fastest `
      + `<span class="num">${shown}</span> are here, ordered by ${order}. The strongest moves `
      + `<span class="num">${fmt(Math.abs(rows[0].rate_m_yr), 0)} m</span> a year; `
      + `<span class="num">${withPeople}</span> of those shown have anyone living within `
      + `about two kilometres.`;
    return;
  }
  if (cap) cap.innerHTML =
    `<span class="num">${fmt(GLYPHS.length)}</span> stretches of Pacific coast move at least `
    + `<span class="num">${GLYPH_CUT} m</span> a year &mdash; `
    + `<span class="num">${fmt(totRet)}</span> retreating, `
    + `<span class="num">${fmt(totGain)}</span> growing. The `
    + `<span class="num">${shown}</span> shown here are the fastest by ${order}: the quickest `
    + `moves <span class="num">${fmt(Math.abs(rows[0].rate_m_yr), 0)} m</span> a year, the `
    + `last <span class="num">${fmt(Math.abs(rows[shown - 1].rate_m_yr), 1)} m</span>. Only `
    + `<span class="num">${withPeople}</span> have anyone living within about two kilometres `
    + `&mdash; fast coast and populated coast are rarely the same coast.`;
}

function glyphKv(g) {
  const K = GLYPH_KIND[g.kind];
  const ns = g.lat < 0 ? "S" : "N", ew = g.lon < 0 ? "W" : "E";
  return `
    <dt>country</dt><dd>${g.country}</dd>
    <dt>division</dt><dd>${g.admin || "&mdash;"}</dd>
    <dt>nearest ${g.place_type || "place"}</dt><dd>${g.place || "&mdash;"}</dd>
    <dt>distance to it</dt><dd>${g.place_km == null ? "&mdash;" : fmt(g.place_km, 1) + " km"}</dd>
    <dt>people within about 2 km</dt><dd class="ppl">${fmt(g.pop_near || 0)}</dd>
    <div class="sep"></div>
    <dt>coast ${K.verb}</dt>
      <dd class="${K.tone}">${fmt(Math.abs(g.rate_m_yr), 2)} m a year</dd>
    <dt>median of its points</dt>
      <dd class="${g.rate_robust ? K.tone : "warnval"}">${fmt(Math.abs(g.rate_median_m_yr), 2)} m a year</dd>
    <dt>${D.meta.year_min} to ${D.meta.year_max}</dt>
      <dd class="${K.tone}">${fmt(Math.abs(g.shift_m))} m</dd>
    <div class="sep"></div>
    <dt>points behind it</dt><dd>${fmt(g.n_points)}</dd>
    <dt>coast measured here</dt><dd>${fmt(g.coast_m)} m</dd>
    <dt>where</dt>
      <dd>${fmt(Math.abs(g.lat), 3)}°${ns} ${fmt(Math.abs(g.lon), 3)}°${ew}</dd>`;
}

function fillGlyphSheet(g) {
  const K = GLYPH_KIND[g.kind];
  const set = (id, v) => { const n = document.getElementById(id); if (n) n.innerHTML = v; };
  set("gsKind", K.word);
  set("gsTitle", g.place || g.admin || g.country);
  set("gsSub", `${g.country} · ${g.admin || "unassigned"}`);
  set("gsPlace", `${g.place || g.country}`);
  set("gsKv", glyphKv(g));
  const art = document.getElementById("gsGlyph");
  if (art) {
    art.dataset.kind = g.kind;
    delete art.dataset.done;
    art.innerHTML = "";
    paintGlyph(art, g.glyph);
  }
  set("gsWiki", g.wiki_extract
    ? `<h4>${g.wiki_title}</h4><p>${g.wiki_extract}</p>`
      + `<a class="srclink" href="${g.wiki_url}" target="_blank" rel="noreferrer noopener">`
      + `<span class="srclink-t">Read the article</span>`
      + `<span class="srclink-d">wikipedia.org</span>`
      + `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7"/><path d="M8 7h9v9"/></svg></a>`
    : `<p class="small">No Wikipedia article sits within reach of this stretch. The place name `
      + `comes from OpenStreetMap.</p>`);
  set("gsCap",
    `Every annual shoreline the record holds here, ${D.meta.year_min} to ${D.meta.year_max}, `
    + `palest first. The bold line is the year on the slider. `
    + `${g.pop_near ? fmt(g.pop_near) + " people live" : "nobody lives"} within two kilometres.`
    // the headline rate is the mean of this stretch's points; when the median is far below
    // it, a minority of them are carrying it and the reader should know
    + (g.rate_robust ? ``
       : ` <strong>Most of this stretch moves more slowly than the headline figure:</strong> `
         + `half its points are under ${fmt(Math.abs(g.rate_median_m_yr), 1)} m a year. A few `
         + `fast-moving points carry the average.`));
}

/* the map inside the card: built on first open, then moved */
const GLYPH_MAP_ZOOM = 13;   // reads as roughly 1 km on the built-in scale control
let glyphPlayTimer = null;
const PLAY_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l9 6-9 6z"/></svg>`;
const PAUSE_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><line x1="8" y1="5" x2="8" y2="19"/><line x1="16" y1="5" x2="16" y2="19"/></svg>`;

function stopGlyphPlay() {
  if (!glyphPlayTimer) return;
  clearInterval(glyphPlayTimer);
  glyphPlayTimer = null;
  const btn = document.getElementById("gsPlayBtn");
  if (btn) { btn.setAttribute("aria-pressed", "false"); btn.innerHTML = PLAY_ICON; }
}

function glyphMap(g) {
  const yearIn = document.getElementById("gsYearIn");
  const draw = () => {
    const map = MAPS.mapGlyph, y = +yearIn.value;
    document.getElementById("gsYearOut").textContent = y;
    document.getElementById("gsYear").textContent = y;
    if (map && map.getLayer("shore-focus")) map.setFilter("shore-focus", yearFilter(y));
  };
  stopGlyphPlay();

  if (!MAPS.mapGlyph) {
    const map = makeMap("mapGlyph", {
      center: [g.lon, g.lat], zoom: GLYPH_MAP_ZOOM, maxZoom: 17,
      home: { center: [g.lon, g.lat], zoom: GLYPH_MAP_ZOOM }
    });
    onStyle(map, () => {
      if (TILES.populationRaster) {
        map.addLayer(popRasterLayer());
        map.setLayoutProperty("people", "visibility", "none");
      }
      addTrail(map, D.meta.year_min, D.meta.year_max);
      map.addLayer({
        id: "shore-focus", type: "line", source: "dep", "source-layer": "shorelines_annual",
        filter: yearFilter(+yearIn.value),
        layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": ink("loss"), "line-width": 3.2 }
      });
      addSatellite(map, document.getElementById("gsSatBtn").getAttribute("aria-pressed") === "true");
      draw();
      syncLayerToggles(map);
    });
    yearIn.addEventListener("input", () => { stopGlyphPlay(); draw(); });
    bindLayerToggle(map, "gsTrailBtn", "shore-trail");
    const gsKey = document.getElementById("gsPopKey");
    bindLayerToggle(map, "gsPopBtn", "people", on => { if (gsKey) gsKey.hidden = !on; });
    const gsSat = document.getElementById("gsSatBtn");
    gsSat.onclick = () => {
      const on = gsSat.getAttribute("aria-pressed") !== "true";
      gsSat.setAttribute("aria-pressed", on);
      addSatellite(map, on);
    };
    const gsPlay = document.getElementById("gsPlayBtn");
    if (gsPlay) gsPlay.onclick = () => {
      if (glyphPlayTimer) { stopGlyphPlay(); return; }
      gsPlay.setAttribute("aria-pressed", "true");
      gsPlay.innerHTML = PAUSE_ICON;
      glyphPlayTimer = setInterval(() => {
        const min = +yearIn.min, max = +yearIn.max;
        yearIn.value = (+yearIn.value >= max) ? min : +yearIn.value + 1;
        draw();
      }, 600);
    };
  } else {
    MAPS.mapGlyph.jumpTo({ center: [g.lon, g.lat], zoom: GLYPH_MAP_ZOOM });
    MAPS.mapGlyph.resize();
    draw();
  }
  if (MAPS.mapGlyph && MAPS.mapGlyph.getLayer("shore-focus"))
    MAPS.mapGlyph.setPaintProperty("shore-focus", "line-color",
      ink(g.kind === "gain" ? "gain" : "loss"));
}

/* the card grows out of the tile that opened it - the app-store move: one FLIP on the
   dialog box, and the contents faded in behind it once it has arrived */
function openGlyph(g, tile) {
  const dlg = document.getElementById("glyphSheet");
  if (!dlg) return;
  glyphOpen = g;
  fillGlyphSheet(g);
  dlg.showModal();
  requestAnimationFrame(() => glyphMap(g));

  if (reduce) return;
  const from = tile.getBoundingClientRect(), to = dlg.getBoundingClientRect();
  if (!to.width || !to.height) return;
  dlg.animate([
    { transform: `translate(${from.left + from.width / 2 - (to.left + to.width / 2)}px,`
        + ` ${from.top + from.height / 2 - (to.top + to.height / 2)}px)`
        + ` scale(${from.width / to.width}, ${from.height / to.height})`,
      opacity: .25, borderRadius: "14px" },
    { transform: "none", opacity: 1, borderRadius: "4px" }
  ], { duration: 460, easing: "cubic-bezier(.22,.9,.28,1)" });
  dlg.querySelector(".gsheet-in").animate(
    [{ opacity: 0, transform: "translateY(14px)" }, { opacity: 1, transform: "none" }],
    { duration: 340, delay: 140, easing: "cubic-bezier(.2,.8,.3,1)", fill: "backwards" });
}

function closeGlyph() {
  const dlg = document.getElementById("glyphSheet");
  if (!dlg || !dlg.open) return;
  stopGlyphPlay();
  const tile = glyphOpen &&
    document.querySelector(`.gtile[data-id="${glyphOpen.id}"]`);
  if (reduce || !tile) { dlg.close(); return; }
  const from = tile.getBoundingClientRect(), to = dlg.getBoundingClientRect();
  dlg.animate([
    { transform: "none", opacity: 1 },
    { transform: `translate(${from.left + from.width / 2 - (to.left + to.width / 2)}px,`
        + ` ${from.top + from.height / 2 - (to.top + to.height / 2)}px)`
        + ` scale(${from.width / to.width}, ${from.height / to.height})`,
      opacity: 0 }
  ], { duration: 260, easing: "cubic-bezier(.4,0,.75,.5)" })
    .finished.then(() => dlg.close(), () => dlg.close());
}

function wireGlyphs() {
  document.querySelectorAll("[data-gsort]").forEach(b => b.onclick = () => {
    glyphSort = b.dataset.gsort;
    buildGlyphGrid();
  });
  document.querySelectorAll("[data-gdir]").forEach(b => b.onclick = () => {
    glyphDir = b.dataset.gdir;
    buildGlyphGrid();
  });
  const close = document.getElementById("glyphClose");
  if (close) close.onclick = closeGlyph;
  const dlg = document.getElementById("glyphSheet");
  if (dlg) {
    // clicking the backdrop closes it; the dialog box itself must not
    dlg.addEventListener("click", e => { if (e.target === dlg) closeGlyph(); });
    dlg.addEventListener("cancel", e => { e.preventDefault(); closeGlyph(); });
  }
}

/* -------- 05  the drawer -------- */
let metric = "pct_coast_retreat", selected = "PNG";

const METRIC_LABEL = {
  pct_coast_retreat: "% of coast retreating",
  area_lost_km2: "km² of land lost",
  pop_retreat_1km: "people affected",
  pct_retreat: "% of people affected",
  coast_km_assessed: "km of coast measured"
};

const RAMP = [.12, .3, .5, .72, 1];   // five steps of the loss colour, pale to full

function choroBreaks(m) {
  const vals = D.territories.map(t => t[m]).filter(v => v != null).sort((a, b) => a - b);
  return RAMP.slice(1).map((_, i) =>
    vals[Math.floor((i + 1) / RAMP.length * (vals.length - 1))]);
}

/* MapLibre wants a literal colour. Resolve through a canvas so this works for hex,
   rgb() and oklch() alike - the cloth skin's tokens are oklch and hex parsing gave NaN. */
function mix(css, amount) {
  const nums = v => cssColour(v).match(/[\d.]+/g).map(Number);
  const a = nums(css), b = nums(ink("paper-2") || "#ffffff");
  const m = (x, y) => Math.round(y + (x - y) * amount);
  return `rgb(${m(a[0],b[0])},${m(a[1],b[1])},${m(a[2],b[2])})`;
}

function choroExpr(m) {
  const br = choroBreaks(m), c = ink("loss");
  const expr = ["step", ["coalesce", ["get", m], 0], mix(c, RAMP[0])];
  br.forEach((b, i) => expr.push(b, mix(c, RAMP[i + 1])));
  return expr;
}

function drawChoroScale() {
  const br = choroBreaks(metric), dec = metric.startsWith("pct") ? 1 : 0;
  document.getElementById("choroScale").innerHTML =
    `<span>${METRIC_LABEL[metric]}</span>`
    + RAMP.map((o, i) => `<i style="background:${mix(ink("loss"), o)}"></i>`
        + (i < br.length ? `<span>${fmt(br[i], dec)}</span>` : "")).join("");
}

let dashPlayTimer = null;

function stopDashPlay() {
  if (!dashPlayTimer) return;
  clearInterval(dashPlayTimer);
  dashPlayTimer = null;
  const btn = document.getElementById("dashPlayBtn");
  if (btn) { btn.setAttribute("aria-pressed", "false"); btn.innerHTML = PLAY_ICON; }
}

/* Imagery is added on demand rather than sitting in the initial style, so a slow or
   unreachable Esri never delays a map's first paint. */
function addSatellite(map, on) {
  if (!on) {
    if (map.getLayer("satellite")) map.setPaintProperty("satellite", "raster-opacity", 0);
    return;
  }
  if (!map.getSource("sat"))
    map.addSource("sat", { type: "raster", tiles: [SAT_URL], tileSize: 256, maxzoom: 18,
                           attribution: "Imagery &copy; Esri" });
  if (!map.getLayer("satellite")) {
    const under = map.getStyle().layers.find(l => l.id !== "paper");
    map.addLayer({ id: "satellite", type: "raster", source: "sat",
                   paint: { "raster-opacity": 0 } }, under ? under.id : undefined);
  }
  map.setPaintProperty("satellite", "raster-opacity", 1);
}

function setMetric(m) {
  metric = m;
  document.querySelectorAll("[data-metric]").forEach(b =>
    b.setAttribute("aria-pressed", b.dataset.metric === m));
  const map = MAPS.mapChoro;
  if (map && map.getLayer("choro")) map.setPaintProperty("choro", "fill-color", choroExpr(m));
  drawChoroScale();
}

/* One map instead of two: it opens on the whole region, satellite and the choropleth
   both on, so picking a country and reading it close up happen on the same canvas.
   Clicking a territory - on the map or a chip - flies in and layers the close-up tools
   (year slider, trail, population grid, movement dots) over the same imagery, rather
   than handing off to a second map. */
// the union of every territory's own bounds - fitting to this rather than a
// hand-picked centre/zoom means the opening view always frames the whole record
const regionBounds = () => [
  [Math.min(...D.territories.map(t => t.w)), Math.min(...D.territories.map(t => t.s))],
  [Math.max(...D.territories.map(t => t.e)), Math.max(...D.territories.map(t => t.n))]
];

// dark under satellite so the choropleth ramp still pops; a paper-family light grey
// when satellite is off, so the empty sea reads as part of the page, not a void
const seaFor = satOn => ink(satOn ? "ink" : "paper-2");

function initRegionMap() {
  const map = makeMap("mapChoro", { center: [180, -8], zoom: 2.2, maxZoom: 17,
                                    home: { center: [180, -8], zoom: 2.2 } });
  map.jumpTo(map.cameraForBounds(regionBounds(), { padding: 24 }));
  const yearIn = document.getElementById("dashYear");
  const drawYear = () => {
    const y = +yearIn.value;
    document.getElementById("dashYearOut").textContent = y;
    document.getElementById("dashStamp").textContent = y;
    if (map.getLayer("shore-year")) map.setFilter("shore-year", yearFilter(y));
  };

  onStyle(map, () => {
    map.setPaintProperty("paper", "background-color", seaFor(true));
    map.addLayer({ id: "choro", type: "fill", source: "bnd",
      paint: { "fill-color": choroExpr(metric),
        // full colour at the region view, where it is the whole point; fades as a
        // territory is zoomed into, so the imagery and the close-up layers take over
        "fill-opacity": ["interpolate", ["linear"], ["zoom"], 2, .6, 5, .45, 8, .16, 11, .08] } });
    map.addLayer({ id: "choro-line", type: "line", source: "bnd",
      paint: { "line-color": ink("paper"), "line-width": .8, "line-opacity": .5 } });
    map.addLayer({ id: "choro-sel", type: "line", source: "bnd",
      filter: ["==", ["get", "territory"], selected],
      paint: { "line-color": ink("loss"), "line-width": 2.4 } });

    if (TILES.populationRaster) {
      map.addLayer(popRasterLayer());
      map.setLayoutProperty("people", "visibility", "none");
    }
    addTrail(map, D.meta.year_min, D.meta.year_max);
    map.setLayoutProperty("shore-trail", "visibility", "none");
    map.addLayer({
      id: "shore-year", type: "line", source: "dep", "source-layer": "shorelines_annual",
      filter: yearFilter(+yearIn.value),
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#ffffff", "line-width": 1.6, "line-opacity": .9 }
    });
    // direction comes from each point's long-run trend, so it holds as the year moves
    map.addLayer({
      id: "dir", type: "circle", source: "dep", "source-layer": "rates_of_change", minzoom: 4,
      filter: ["all", ...sigOnly()],
      paint: {
        "circle-color": dirColour(),
        "circle-radius": ["interpolate", ["linear"], ["zoom"], 4, .9, 6, 1.6, 11, 3.4, 15, 7],
        "circle-opacity": .85,
        "circle-stroke-width": .5, "circle-stroke-color": "rgba(0,0,0,.45)"
      }
    });

    addSatellite(map, true);
    addRegionFurniture(map, { track: true });

    map.on("click", "choro", e => {
      const t = e.features[0] && e.features[0].properties.territory;
      if (t) selectTerritory(t);
    });
    map.on("mouseenter", "choro", () => map.getCanvas().style.cursor = "pointer");
    const tip = new maplibregl.Popup({ closeButton: false, closeOnClick: false, offset: 8 });
    map.on("mousemove", "choro", e => {
      const p = e.features[0].properties;
      tip.setLngLat(e.lngLat).setHTML(
        `<b>${p.name}</b><br>${METRIC_LABEL[metric]}: `
        + `${fmt(p[metric], metric.startsWith("pct") ? 1 : 0)}`).addTo(map);
    });
    map.on("mouseleave", "choro", () => {
      map.getCanvas().style.cursor = "";
      tip.remove();
    });

    drawChoroScale();
    syncLayerToggles(map);
  });

  yearIn.addEventListener("input", () => { stopDashPlay(); drawYear(); });
  const dashKey = document.getElementById("dashPopKey");
  bindLayerToggle(map, "dashTrailBtn", "shore-trail");
  bindLayerToggle(map, "dashDotsBtn", "dir");
  bindLayerToggle(map, "dashPopBtn", "people", on => { if (dashKey) dashKey.hidden = !on; });

  const sat = document.getElementById("dashSatBtn");
  sat.onclick = () => {
    const on = sat.getAttribute("aria-pressed") !== "true";
    sat.setAttribute("aria-pressed", on);
    addSatellite(map, on);
    map.setPaintProperty("paper", "background-color", seaFor(on));
  };

  const dashPlay = document.getElementById("dashPlayBtn");
  if (dashPlay) dashPlay.onclick = () => {
    if (dashPlayTimer) { stopDashPlay(); return; }
    dashPlay.setAttribute("aria-pressed", "true");
    dashPlay.innerHTML = PAUSE_ICON;
    dashPlayTimer = setInterval(() => {
      const min = +yearIn.min, max = +yearIn.max;
      yearIn.value = (+yearIn.value >= max) ? min : +yearIn.value + 1;
      drawYear();
    }, 600);
  };
}

function flyToTerritory(code) {
  const t = D.territories.find(x => x.territory === code);
  if (!t || !MAPS.mapChoro) return;
  // w/s/e/n sit on a 0-360 axis so the territories either side of the date line hold together
  MAPS.mapChoro.fitBounds([[t.w, t.s], [t.e, t.n]],
    { padding: 30, duration: reduce ? 0 : 1200, maxZoom: 11 });
  MAPS.mapChoro.markSelected?.(code);
  if (MAPS.mapChoro.getLayer("choro-sel"))
    MAPS.mapChoro.setFilter("choro-sel", ["==", ["get", "territory"], code]);
}

function buildChips() {
  const box = document.getElementById("ctryChips");
  box.innerHTML = "";
  [...D.territories].sort((a, b) => b[metric] - a[metric]).forEach(t => {
    const b = document.createElement("button");
    b.className = "chip";
    b.textContent = t.territory;
    b.title = t.name;
    b.setAttribute("aria-label", `${t.name} (${t.territory})`);
    b.setAttribute("aria-pressed", t.territory === selected);
    b.onclick = () => selectTerritory(t.territory);
    box.appendChild(b);
  });
}

/* share of the regional total, the worst places in this country, and somewhere to read on */
function dashDetail(t) {
  const hot = COUNTRY_HOT[t.territory] || [];
  const list = document.getElementById("dashHot");
  list.innerHTML = hot.length
    ? hot.map(h => `<li><b>${h.label}</b> — <span class="rate">${fmt(h.rate_time, 1)} m/yr</span>`
        + `, about ${fmt(h.pop_near)} people within about 2 km</li>`).join("")
    : `<li>No stretch of this coast has a clear enough retreat trend to name.</li>`;

  // no stored headlines: send people to a live search instead of inventing any
  const q = encodeURIComponent(`"${t.name}" (coastal erosion OR shoreline OR "sea level")`);
  document.getElementById("dashNews").innerHTML =
    `<a href="https://news.google.com/search?q=${q}" target="_blank" rel="noreferrer noopener">`
    + `News about ${t.name} and its coastline &rarr;</a><br>`
    + `<a href="https://www.google.com/search?q=${q}&tbs=cdr:1,cd_min:1/1/1999,cd_max:12/31/2023"`
    + ` target="_blank" rel="noreferrer noopener">Restricted to 1999&ndash;2023 &rarr;</a>`;
}

/* Retreat, growth and what is left, as a waterfall: the two sides start from zero and
   the third bar is what survives the cancelling, hanging where the second one stopped. */
function dashBars(t) {
  const svg = document.getElementById("dashBars");
  const W = 420, HT = 186, m = { t: 30, r: 14, b: 46, l: 46 };
  frame(svg, W, HT);
  defsFor(svg, ["hatch-gain", "hatch-loss"]);
  const r = rng(88);

  const lost = t.area_lost_sig_km2, gained = t.area_net_sig_km2 + t.area_lost_sig_km2;
  const net = t.area_net_sig_km2;
  const steps = [
    { k: "taken by retreat", v: -lost, tone: "loss" },
    { k: "added by growth", v: gained, tone: "gain" },
    { k: "difference", v: net, tone: net < 0 ? "loss" : "gain", total: true }
  ];
  let run = 0;
  const seq = steps.map(st => {
    const a = st.total ? 0 : run, b = st.total ? st.v : run + st.v;
    if (!st.total) run += st.v;
    return { ...st, a, b };
  });

  const vals = seq.flatMap(st => [st.a, st.b]).concat(0);
  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo) * .18 || 1;
  const y = v => m.t + (hi + pad - v) / (hi - lo + 2 * pad) * (HT - m.t - m.b);
  const slot = (W - m.l - m.r) / seq.length, bw = slot * .5;
  const cx = i => m.l + slot * (i + .5);

  ticks(lo - pad, hi + pad, 3).forEach(v => {
    el("path", { d: roughLine(m.l - 6, y(v), W - m.r, y(v), r, v === 0 ? .7 : .4),
      stroke: v === 0 ? "var(--ink-2)" : "var(--grid-strong)",
      "stroke-width": v === 0 ? 1.3 : 1, fill: "none" }, svg);
    txt(svg, m.l - 9, y(v) + 3.5, fmt(v, Math.abs(v) < 10 ? 1 : 0),
      { "text-anchor": "end", "font-size": 9, fill: "var(--ink-3)" });
  });

  seq.forEach((st, i) => {
    const top = Math.min(y(st.a), y(st.b)), h = Math.max(3, Math.abs(y(st.a) - y(st.b)));
    const g = el("g", { class: "fadein", style: `--d:${i * 110}ms` }, svg);
    el("path", { d: roughRect(cx(i) - bw / 2, top, bw, h, r, .9),
      fill: st.total ? "none" : purl(svg, `hatch-${st.tone}`), stroke: `var(--${st.tone})`,
      "stroke-width": st.total ? 2 : 1.5, "stroke-linejoin": "round" }, g);
    txt(g, cx(i), st.v >= 0 ? top - 6 : top + h + 13, sign(st.v, 2),
      { "text-anchor": "middle", "font-size": 10, "font-weight": 600,
        fill: `var(--${st.tone})` });
    const lab = el("text", { x: cx(i), y: HT - m.b + 15, "text-anchor": "middle",
      "font-size": 9, fill: "var(--ink-3)" }, g);
    st.k.split(" ").forEach((wd, k) => {
      const ts = el("tspan", { x: cx(i), dy: k ? 10 : 0 }, lab);
      ts.textContent = wd;
    });
    if (i < seq.length - 1 && !seq[i + 1].total)
      el("path", { d: `M${cx(i) + bw / 2} ${y(st.b)}H${cx(i + 1) - bw / 2}`,
        stroke: "var(--ink-3)", "stroke-width": 1, "stroke-dasharray": "3 3" }, g);
  });

  txt(svg, m.l - 9, m.t - 12, "km²", { "text-anchor": "end", "font-size": 9, fill: "var(--ink-3)" });
  svg.setAttribute("aria-label",
    `${t.name}: ${fmt(lost, 2)} square kilometres taken by retreat, ${fmt(gained, 2)} added `
    + `by growth, leaving ${sign(net, 2)}, counting only the points with a clear trend.`);
}

let dashHistKind = "count";

/* The country's own trend distribution, drawn on the region's edges so two countries -
   or a country and the region - can be set side by side without the axis moving. Equal
   count is the default, the same way round as the chart on page one. */
function dashHist(t) {
  const svg = document.getElementById("dashHist");
  if (!svg) return;
  const even = dashHistKind === "even";
  const src = even ? D.rate_hist_terr : D.rate_hist_terr_count;
  if (!src || !src.terr[t.territory]) return;
  const E = src.terr[t.territory];
  const W = 420, HT = 156, m = { t: 18, r: 12, b: 46, l: 40 };
  const plotW = W - m.l - m.r, plotH = HT - m.t - m.b;
  frame(svg, W, HT);
  defsFor(svg, ["hatch-ink-3"]);
  const pal = HIST_PALETTES[histPalette];
  const base = m.t + plotH;

  if (even) {
    const nb = E.n.length, half = nb / 2, bw = plotW / nb;
    const cols = ramp(pal.retreat, half).concat(ramp(pal.advance, half));
    const maxN = Math.max(1, ...E.n);
    const px = v => m.l + (v + src.cap) / (2 * src.cap) * plotW;
    E.n.forEach((n, i) => {
      if (!n) return;
      const h = Math.max(1, n / maxN * plotH);
      el("rect", { x: m.l + i * bw, y: base - h, width: Math.max(1, bw - .4), height: h,
        fill: cols[i] }, svg);
    });
    [-5, -2, 0, 2, 5].forEach(v => {
      el("path", { d: `M${px(v)} ${base}v${v === 0 ? 7 : 4}`, stroke: "var(--ink-3)",
        "stroke-width": v === 0 ? 1.2 : 1 }, svg);
      txt(svg, px(v), base + 17, v > 0 ? "+" + v : String(v),
        { "text-anchor": "middle", "font-size": 9,
          "font-weight": v === 0 ? 600 : 400, fill: "var(--ink-3)" });
    });
    txt(svg, m.l - 6, m.t + 6, fmt(maxN),
      { "text-anchor": "end", "font-size": 8.5, fill: "var(--ink-3)" });
    txt(svg, m.l + plotW / 2, base + 34, `trend, m a year · bins of ${src.step}`,
      { "text-anchor": "middle", "font-size": 8.5, fill: "var(--ink-3)" });
  } else {
    /* the region's equal-count edges: bar width is the speed range that bar covers, so
       height has to be density, exactly as on page one */
    const bins = D.rate_hist;
    const core = bins.map((b, i) => ({ ...b, i }))
      .filter(b => !b.tail && b.side !== "unclear");
    const cap = D.meta.hist_cap_m_yr || 5;
    const tailW = 26, gapW = 6, midW = 34;
    const coreW = (plotW - 2 * tailW - 2 * gapW - midW) / 2;
    let x = m.l;
    const slots = bins.map((b, i) => {
      const w = b.tail ? tailW : b.side === "unclear" ? midW : (b.hi - b.lo) / cap * coreW;
      const o = { ...b, i, x, w, n: E.n[i] };
      x += w + (b.tail ? gapW : 0);
      return o;
    });
    const dens = o => o.tail || o.side === "unclear" ? null : o.n / (o.hi - o.lo);
    const maxD = Math.max(...slots.map(o => dens(o) || 0)) * 1.08 || 1;
    const retreatCols = ramp(pal.retreat, 6), advanceCols = ramp(pal.advance, 6);
    let ri = 0, ai = 0;

    const mid = slots.find(o => o.side === "unclear");
    const unclear = Math.max(0, (t.n_points_all || 0) - E.told);
    el("rect", { x: mid.x, y: m.t - 4, width: mid.w, height: plotH + 4,
      fill: purl(svg, "hatch-ink-3") }, svg);
    el("rect", { x: mid.x, y: m.t - 4, width: mid.w, height: plotH + 4, fill: "none",
      stroke: "var(--ink-3)", "stroke-width": 1, "stroke-dasharray": "3 3" }, svg);

    slots.forEach(o => {
      if (o.side === "unclear") return;
      if (o.tail) {
        const top = m.t + 22, c = o.side === "retreat" ? retreatCols[0] : advanceCols[5];
        el("rect", { x: o.x, y: top, width: o.w, height: base - top, fill: c, opacity: .18 }, svg);
        el("rect", { x: o.x, y: top, width: o.w, height: base - top, fill: "none",
          stroke: c, "stroke-width": 1, "stroke-dasharray": "3 2" }, svg);
        txt(svg, o.x + o.w / 2, top - 5, fmt(o.n),
          { "text-anchor": "middle", "font-size": 8, fill: c });
        return;
      }
      const h = Math.max(1, plotH * dens(o) / maxD);
      el("rect", { x: o.x, y: base - h, width: Math.max(1, o.w - .5), height: h,
        fill: o.side === "retreat" ? retreatCols[++ri] : advanceCols[ai++] }, svg);
    });

    txt(svg, mid.x + mid.w / 2, m.t + 12, fmt(unclear),
      { "text-anchor": "middle", "font-size": 8, fill: "var(--ink-2)" });
    const xAt = v => {
      const side = v < 0 ? "retreat" : "advance";
      const b = slots.find(o => !o.tail && o.side === side && v >= o.lo && v <= o.hi)
        || slots[v < 0 ? 1 : slots.length - 2];
      return b.x + (v - b.lo) / (b.hi - b.lo) * b.w;
    };
    [-5, -1, 1, 5].forEach(v => {
      el("path", { d: `M${xAt(v)} ${base}v4`, stroke: "var(--ink-3)", "stroke-width": 1 }, svg);
      txt(svg, xAt(v), base + 17, (v > 0 ? "+" : "−") + Math.abs(v),
        { "text-anchor": "middle", "font-size": 9, fill: "var(--ink-3)" });
    });
    txt(svg, m.l + plotW / 2, base + 34, "equal-count bins · width is the speed range",
      { "text-anchor": "middle", "font-size": 8.5, fill: "var(--ink-3)" });
  }

  el("path", { d: `M${m.l} ${base}H${m.l + plotW}`, stroke: "var(--ink-2)",
    "stroke-width": 1.2 }, svg);

  const note = document.getElementById("dashHistNote");
  if (note) note.innerHTML =
    `<span class="num">${fmt(E.told)}</span> of ${t.name}'s points have a trend clear enough `
    + `to call. <span class="num">${fmt(E.lo_n != null ? E.lo_n : E.n[0])}</span> retreat and `
    + `<span class="num">${fmt(E.hi_n != null ? E.hi_n : E.n[E.n.length - 1])}</span> move `
    + `faster than ${D.meta.hist_cap_m_yr} m a year. The scale is the region's, so countries `
    + `can be set side by side.`;
  svg.setAttribute("aria-label",
    `Distribution of ${t.name}'s coastal trends, on the same axis as the regional histogram.`);
  document.querySelectorAll("[data-dhist]").forEach(x =>
    x.setAttribute("aria-pressed", String(x.dataset.dhist === dashHistKind)));
}

function selectTerritory(code, scroll) {
  selected = code;
  const t = D.territories.find(x => x.territory === code);
  document.getElementById("dashName").textContent = t.name;
  document.getElementById("dashSub").textContent =
    `${t.territory} · ${fmt(t.coast_km_assessed)} km measured of ${fmt(t.coast_km_total)} km`;
  // The three area figures the waterfall above already draws are not repeated here.
  document.getElementById("dashKv").innerHTML = `
    <dt>coast retreating</dt><dd class="loss">${fmt(t.coast_km_retreat)} km · ${fmt(t.pct_coast_retreat,1)}%</dd>
    <dt>coast building out</dt><dd class="gain">${fmt(t.coast_km_advance)} km</dd>
    <dt>coast holding still</dt><dd>${fmt(t.coast_km_stable)} km</dd>
    <div class="sep"></div>
    <dt>people in 2020</dt><dd>${fmt(t.pop_total)}</dd>
    <dt>living on the coast</dt><dd class="ppl">${fmt(t.pop_coastal_1km)} · ${fmt(t.pct_coastal,1)}%</dd>
    <dt>where it is retreating</dt><dd class="loss">${fmt(t.pop_retreat_1km)} · ${fmt(t.pct_retreat,1)}%</dd>
    <dt>where it is retreating more than 5 m per year</dt><dd class="loss">${fmt(t.pop_fast_1km)} · ${fmt(t.pct_fast,1)}%</dd>`;
  const ledger = document.getElementById("dashLedgerNote");
  if (ledger) ledger.innerHTML =
    `These areas count only the points whose trend is clear enough to call &mdash; the same `
    + `points as the lengths above, so the two describe one thing. Counting every point, `
    + `weak trends included, the figures are `
    + `<span class="num loss">${fmt(t.area_lost_km2, 2)}</span> and `
    + `<span class="num gain">${fmt(t.area_gained_km2, 2)} km²</span>, netting to `
    + `<span class="num">${sign(t.area_net_km2, 2)}</span>. The regional headline uses that `
    + `wider count, which is why it is the larger number.`;
  dashBars(t);
  dashHist(t);
  dashDetail(t);
  bandGlyphs(t);
  const place = document.getElementById("dashPlace");
  if (place) place.textContent = t.name;
  // shareable/bookmarkable: a journalist citing one territory gets a link back to it,
  // via replaceState so browsing 22 territories does not fill up the back button
  history.replaceState(null, "", "#s5/" + code);
  flyToTerritory(code);
  [...document.getElementById("ctryChips").children].forEach(c =>
    c.setAttribute("aria-pressed", c.textContent === code));
  if (scroll) document.getElementById("s5").scrollIntoView({ behavior: reduce ? "auto" : "smooth" });
}

/* ================================================================
   what 51 km2 actually looks like
   Areas in km2, so the multiples come out of the data rather than being
   written down and left to rot when the pipeline changes.
   ================================================================ */
const YARDSTICKS = [
  { km2: 26,      whole: "Tuvalu",         unit: "times the size of Tuvalu" },
  { km2: 0.00714, whole: "a football pitch", unit: "football pitches" },
  { km2: 21,      whole: "Nauru",          unit: "times the size of Nauru" },
  { km2: 3.41,    whole: "Central Park",   unit: "Central Parks" },
  { km2: 59.1,    whole: "Manhattan",      unit: "times the size of Manhattan" },
  { km2: 9.7,     whole: "Majuro, the Marshallese capital", unit: "times the size of Majuro" },
];

function comparisonPhrases(area) {
  const round = n => n >= 100 ? Math.round(n / 100) * 100
                   : n >= 10  ? Math.round(n)
                   : Math.round(n * 10) / 10;
  return YARDSTICKS.map(y => {
    const k = area / y.km2, n = round(k);
    if (k >= 0.85 && k <= 1.15) return `about the size of ${y.whole}`;
    if (k < 0.85)               return `most of ${y.whole}`;
    if (k >= 1.75 && k <= 2.15) return `nearly twice the size of ${y.whole}`;
    return `${fmt(n, n % 1 ? 1 : 0)} ${y.unit}`;
  });
}

/* the motion.dev typewriter, without the framework: type it, hold it, take it
   back, move on. Anyone who asked for less motion just gets the first one. */
function lossComparisons() {
  const box = document.getElementById("lossCmp");
  const sr  = document.getElementById("lossCmpSr");
  if (!box) return;
  const area = Math.abs(D.pacific.area_net_km2);
  const lead = `${fmt(area, 0)} km² is `;
  const phrases = comparisonPhrases(area);

  if (sr) sr.textContent = lead + phrases.join(", or ") + ".";
  if (reduce) { box.textContent = lead + phrases[0] + "."; return; }

  box.innerHTML = `<span class="tw-lead"></span><span class="tw-swap"></span>`
                + `<span class="tw-dot">.</span><span class="tw-caret"></span>`;
  box.querySelector(".tw-lead").textContent = lead;
  const swap = box.querySelector(".tw-swap");

  let i = 0, n = 0, back = false;
  const tick = () => {
    const t = phrases[i];
    n += back ? -1 : 1;
    swap.textContent = t.slice(0, n);
    let wait = back ? 26 : 46 + Math.random() * 34;
    if (!back && n === t.length) { back = true;  wait = 2600; }
    else if (back && n === 0)    { back = false; i = (i + 1) % phrases.length; wait = 420; }
    setTimeout(tick, wait);
  };
  setTimeout(tick, 900);
}

/* ================================================================
   headline, reveals, wiring
   ================================================================ */
function headline() {
  // ponytail: the prose in index.html is hand-edited, so any span here can vanish -
  // a dud node degrades that one number instead of throwing and killing boot
  const $ = id => document.getElementById(id) || { style: {} };
  const P = D.pacific, m = D.meta;
  // the headline is the net figure - what is left after retreat and growth cancel - and
  // it is rounded, because a projection of 1.3 million trends does not have a unit digit
  $("heroNum").innerHTML =
    '<span class="hero-unit">≈</span>' + fmt(Math.abs(P.area_net_km2), 0)
    + '<span class="hero-unit"> km²</span>';
  $("sNet").textContent = fmt(P.area_lost_km2, 0);
  $("sRate").textContent = "−" + fmt(Math.abs(P.area_net_km2) / m.span_years, 1);
  $("sPct").textContent = fmt(P.pct_coast_retreat, 1) + "%";
  $("sKm").textContent = fmt(P.coast_km_retreat, 0);
  $("cardLost").textContent = fmt(P.area_lost_km2, 0);
  $("cardGained").textContent = fmt(P.area_gained_km2, 0);
  lossComparisons();
  const kept = P.n_transects / P.n_points_all * 100;
  $("countedKv").innerHTML = `
    <dt>points available</dt><dd>${fmt(P.n_points_all)}</dd>
    <dt>points used</dt><dd>${fmt(P.n_transects)}</dd>
    <dt>coast in the record</dt><dd>${fmt(P.coast_km_total)} km</dd>
    <dt>coast measured</dt><dd>${fmt(P.coast_km_assessed)} km</dd>
    <div class="sep"></div>
    <dt>record spans</dt><dd>${m.year_min} to ${m.year_max}</dd>
    <dt>window per point</dt><dd>${m.span_years_min} to ${m.span_years} years</dd>`;

  /* the quality note under the headline, from the same figures */
  $("qKept").style.width = kept.toFixed(1) + "%";
  $("qDrop").style.width = (100 - kept).toFixed(1) + "%";
  $("qualityKv").innerHTML = `
    <dt>points that passed</dt><dd>${fmt(P.n_transects)} · ${fmt(kept, 1)}%</dd>
    <dt>points thrown out</dt>
      <dd>${fmt(P.n_points_all - P.n_transects)} · ${fmt(100 - kept, 1)}%</dd>
    <dt>coast this page covers</dt><dd>${fmt(P.coast_km_assessed)} km</dd>
    <dt>coast the record holds</dt><dd>${fmt(P.coast_km_total)} km</dd>`;
  $("qCovers").textContent = fmt(P.coast_km_assessed);
  $("qHolds").textContent = fmt(P.coast_km_total);
  $("buildLine").textContent = "Author:Edgar Rodriguez-Huerta";
}

function redrawCharts() {
  flowChart(); drawHistograms();
  countryWaterfall(); pctChart();
  kiribatiCards(); peopleBar(); popChart();
  const t = D.territories.find(x => x.territory === selected);
  if (t) { dashBars(t); dashHist(t); }
  clothGround();
}

function lazyMap(sectionId, fn) {
  // #flat is the capture mode: nothing ever scrolls, so build every map straight away
  if (location.hash === "#flat") { fn(); return; }
  const io = new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting) { io.disconnect(); fn(); }
  }), { rootMargin: "220px" });
  io.observe(document.getElementById(sectionId));
}

function wire() {
  const io = new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }), { threshold: .12, rootMargin: "0px 0px -6% 0px" });
  const flat = location.hash === "#flat";
  if (flat) document.documentElement.classList.add("flat");
  else document.querySelectorAll("[data-reveal]").forEach(n => io.observe(n));

  const tabs = [...document.querySelectorAll(".tabs button")];
  tabs.forEach(b => b.onclick = () =>
    document.getElementById(b.dataset.goto).scrollIntoView({ behavior: reduce ? "auto" : "smooth" }));
  const spy = new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting) tabs.forEach(b => b.setAttribute("aria-current", b.dataset.goto === e.target.id));
  }), { threshold: .01, rootMargin: "-45% 0px -45% 0px" });
  document.querySelectorAll("section").forEach(s => spy.observe(s));

  // the tabs are page furniture; they have no business over the opening cloth
  const hero = document.getElementById("hero");
  if (hero) new IntersectionObserver(es => es.forEach(e =>
    document.documentElement.classList.toggle("hero-open", e.isIntersecting)),
    { threshold: .18 }).observe(hero);

  document.querySelectorAll("[data-metric]").forEach(b => b.onclick = () => {
    setMetric(b.dataset.metric);
    buildChips();
  });

  document.querySelectorAll("[data-dhist]").forEach(b => b.onclick = () => {
    dashHistKind = b.dataset.dhist;
    const t = D.territories.find(x => x.territory === selected);
    if (t) dashHist(t);
  });

  document.querySelectorAll("[data-hist]").forEach(b => b.onclick = () => {
    histKind = b.dataset.hist;
    drawHistograms();
  });

  document.querySelectorAll("[data-wf]").forEach(b => b.onclick = () => {
    wfMode = b.dataset.wf;
    countryWaterfall();
  });
  document.querySelectorAll("[data-wfunit]").forEach(b => b.onclick = () => {
    wfUnit = b.dataset.wfunit;
    countryWaterfall();
  });

  wireGlyphs();
}

/* The opening cloth: one photograph cut into strips that slide independently, so the
   printed registers undulate. Cover-fitting is done once here rather than in CSS,
   because each strip has to show its own slice of the same fitted image. */
const CLOTH_IMG = { w: 446, h: 670, strips: 40 };

function buildHeroCloth() {
  const box = document.getElementById("heroCloth");
  if (!box || box.dataset.built) return;
  box.dataset.built = "1";
  for (let i = 0; i < CLOTH_IMG.strips; i++) {
    const d = document.createElement("div");
    d.className = "strip";
    d.style.setProperty("--i", i);
    box.appendChild(d);
  }
  const fit = () => {
    if (!box.offsetWidth) return;
    const W = box.offsetWidth * 1.14, H = box.offsetHeight;
    const k = Math.max(W / CLOTH_IMG.w, H / CLOTH_IMG.h);
    box.style.setProperty("--bw", (CLOTH_IMG.w * k).toFixed(1) + "px");
    box.style.setProperty("--bh", (CLOTH_IMG.h * k).toFixed(1) + "px");
    box.style.setProperty("--oy", ((H - CLOTH_IMG.h * k) / 2).toFixed(1) + "px");
    box.style.setProperty("--sh", (H / CLOTH_IMG.strips).toFixed(2) + "px");
  };
  fit();
  if (window.ResizeObserver) new ResizeObserver(fit).observe(box);
}

/* One span per letter so the cloth's swell can run through the headline. Done in
   JS rather than in the markup so the source stays a readable sentence, and the
   original text is left on the element for anything reading it aloud. */
function splitHeroLetters() {
  const h = document.getElementById("heroTitle");
  if (!h || h.dataset.split) return;
  // a <br> is a word break to a reader, so it has to survive into the label
  const label = [...h.childNodes]
    .map(n => n.nodeName === "BR" ? " " : n.textContent).join("")
    .replace(/\s+/g, " ").trim();
  const esc = c => c === "&" ? "&amp;" : c === "<" ? "&lt;" : c;
  const html = [...h.childNodes].map(n => {
    if (n.nodeName === "BR") return "<br>";
    // one nowrap span per word, so a line can only break between words - a bare
    // run of inline-block letters breaks anywhere and splits the word in half
    return n.textContent.split(/(\s+)/).map(w =>
      /^\s+$/.test(w) ? `<span class="ch"> </span>`
        : `<span class="wd">${[...w].map(c => `<span class="ch">${esc(c)}</span>`).join("")}</span>`
    ).join("");
  }).join("");
  h.innerHTML = html;
  h.classList.add("wavy");
  h.setAttribute("aria-label", label);
  [...h.querySelectorAll(".ch")].forEach((c, i) => c.style.setProperty("--i", i));
  h.dataset.split = "1";
}

/* the one failure that leaves every number on the page blank with no explanation -
   everything else in boot degrades one component at a time, this can't */
function dataFail(e) {
  console.error("boot failed - could not load data/stats.json", e);
  const bar = document.createElement("div");
  bar.className = "dataFail";
  bar.setAttribute("role", "alert");
  bar.textContent = "This page couldn't load its data. Try refreshing the page.";
  (document.querySelector("main.wrap") || document.body).prepend(bar);
}

/* ---------- boot ---------- */
(async () => {
  try {
    const [stats, tiles, motifs, hot, bg, glyphs] = await Promise.all([
      fetch("data/stats.json").then(r => r.json()),
      fetch("data/tiles.json").then(r => r.json()).catch(() => ({
        tiles: "http://127.0.0.1:8081/dep_coastlines_slim/{z}/{x}/{y}.mvt", maxzoom: 13
      })),
      fetch("data/motifs.json").then(r => r.json()).catch(() => null),
      fetch("data/country_hotspots.json").then(r => r.json()).catch(() => ({})),
      fetch("data/background_lines.json").then(r => r.json()).catch(() => null),
      fetch("data/glyph_sites.json").then(r => r.json()).catch(() => [])
    ]);
    D = stats; TILES = tiles; MOTIFS = motifs; COUNTRY_HOT = hot || {}; BGLINES = bg;
    GLYPHS = glyphs || [];
    const sum = k => D.territories.reduce((s, t) => s + (t[k] || 0), 0);
    POP = {
      total:   sum("pop_total"),
      coastal: sum("pop_coastal_1km"),
      retreat: sum("pop_retreat_1km"),
      fast:    sum("pop_fast_1km")
    };

    headline();
    flowChart();
    drawHistograms();
    countryWaterfall();
    pctChart();
    kiribatiCards();
    peopleBar();
    popChart();
    buildChips();
    buildGlyphGrid();
    clothGround();
    // #s5/CODE deep-links straight to one territory's drawer - a link a journalist can cite
    const deepLink = /^#s5\/([A-Za-z]{2,4})$/.exec(location.hash);
    const linkCode = deepLink && deepLink[1].toUpperCase();
    const startCode = linkCode && D.territories.some(t => t.territory === linkCode) ? linkCode : "PNG";
    selectTerritory(startCode, !!deepLink && startCode === linkCode);
    buildHeroCloth();
    splitHeroLetters();
    wire();

    popLegend();

    lazyMap("s5", () => {
      try { initRegionMap(); } catch (e) { console.error("initRegionMap", e); }
    });
  } catch (e) {
    dataFail(e);
  }
})();

/* ================================================================
   THE CLOTH  —  every territory's own coastline, stamped
   Marks per band = length of measured coast. Red share = share retreating.
   ================================================================ */
/* The country's own stretches from p.04: the record's real shorelines for this place. */
function bandGlyphs(t) {
  const box = document.getElementById("bandGlyphs");
  const note = document.getElementById("bandGlyphNote");
  if (!box) return;
  const all = GLYPHS.filter(g => g.territory === t.territory)
    .sort((a, b) => Math.abs(b.rate_m_yr) - Math.abs(a.rate_m_yr));
  const mine = all.slice(0, TILE_CAP);
  box.innerHTML = "";
  mine.forEach(g => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "gtile";
    b.dataset.kind = g.kind;
    b.dataset.src = g.glyph;
    b.dataset.id = g.id;
    b.title = `${g.place} — ${fmt(Math.abs(g.rate_m_yr), 1)} m a year`;
    b.setAttribute("aria-label",
      `${g.place}: coast ${GLYPH_KIND[g.kind].verb} ${fmt(Math.abs(g.rate_m_yr), 1)} metres a year`);
    b.innerHTML = `<span class="gt-art" aria-hidden="true"></span>`
      + `<span class="gt-lab"><b>${g.place || g.territory}</b> ${fmt(Math.abs(g.rate_m_yr), 0)}</span>`;
    b.onclick = () => openGlyph(g, b);
    box.appendChild(b);
    paintGlyph(b.querySelector(".gt-art"), g.glyph);
  });
  if (note) note.innerHTML = all.length
    ? `${t.name} has <span class="num">${fmt(all.length)}</span> `
      + `${all.length === 1 ? "stretch" : "stretches"} of coast moving at least `
      + `${GLYPH_CUT} metres a year, drawn the same way as page four`
      + (all.length > mine.length
          ? `. The ${mine.length} fastest are shown here; the rest are in the grid on page four`
          : ``)
      + `. Open one for where it is.`
    : `No stretch of ${t.name}'s coast moves as much as ${GLYPH_CUT} metres a year, so there `
      + `are no glyphs to show here. The band above is still its own shoreline.`;
}

/* ================================================================
   THE FABRIC GROUND
   A tiling barkcloth register built from real coastline, standing in for the
   notebook grid when the cloth skin is on. Registers of combed hatching, with
   a coastline profile reserved through two of them.
   ================================================================ */
function clothGround() {
  if (!BGLINES || !BGLINES.sites || !BGLINES.sites.length) return;

  // Two registers per tile, one per site. The lines are the real 2013 / 2017 / 2021
  // shorelines at the two places where the trend is clearest, so the pattern is a
  // reading. Kept faint: legible if you go looking, invisible if you are reading.
  const W = 1080, bandH = 232, H = bandH * BGLINES.sites.length;
  const BRICK = "%2372402c", DARK = "%233c2e24";
  let out = "";

  BGLINES.sites.forEach((site, si) => {
    const top = si * bandH;

    // combed ground, the way each register on the cloth is ruled
    out += `<rect x='0' y='${top}' width='${W}' height='${bandH}' fill='${BRICK}'`
         + ` fill-opacity='0.038'/>`;
    for (let y = top + 5; y < top + bandH; y += 9)
      out += `<path d='M0 ${y}H${W}' stroke='${BRICK}' stroke-opacity='0.048'`
           + ` stroke-width='1'/>`;

    // the shorelines, oldest palest, repeated across the strip
    const inner = bandH - 58;
    site.years.forEach((yr, yi) => {
      const op = 0.085 + yi * 0.048;
      const wgt = 1.1 + yi * 0.5;
      const col = yi === site.years.length - 1 ? BRICK : DARK;
      (site.bands[yr] || []).forEach(b => {
        for (let rep = 0; rep < 2; rep++) {
          let d = "";
          for (let q = 0; q < b.length; q += 2) {
            const x = (b[q] * W * 0.52) + rep * W * 0.52;
            const y = top + 24 + b[q + 1] * inner;
            d += (q ? "L" : "M") + x.toFixed(1) + " " + y.toFixed(1);
          }
          out += `<path d='${d}' fill='none' stroke='${col}' stroke-opacity='${op}'`
               + ` stroke-width='${wgt}' stroke-linejoin='round' stroke-linecap='round'/>`;
        }
      });
    });

    // the annotation: there if you look for it, gone if you are not
    const note = `${site.territory} ${site.lat}\u00b0 ${site.lon}\u00b0`
               + `  \u00b7  ${site.rate_time} m/yr  \u00b7  ${site.years[0]}\u2013`
               + `${site.years[site.years.length - 1]}  \u00b7  7,250 m across`;
    // single quotes throughout: a double quote here would close the CSS url("...")
    // early and silently invalidate the whole custom property
    out += `<text x='14' y='${top + 15}' font-family='IBM Plex Mono, monospace'`
         + ` font-size='8.5' letter-spacing='1.2' fill='${DARK}' fill-opacity='0.20'>`
         + note.replace(/&/g, "&amp;").replace(/</g, "&lt;") + `</text>`;
    out += `<path d='M0 ${top + 0.5}H${W}' stroke='${DARK}' stroke-opacity='0.10'`
         + ` stroke-width='1'/>`;
  });

  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='${W}' height='${H}'`
            + ` viewBox='0 0 ${W} ${H}'>${out}</svg>`;
  document.documentElement.style.setProperty(
    "--cloth-bg", `url("data:image/svg+xml,${svg}")`);
}



/* the raster ramp is fixed at build time, so the legend is read from the same file */
async function popLegend() {
  const boxes = ["dashPopRamp", "gsPopRamp"].map(id => document.getElementById(id)).filter(Boolean);
  if (!boxes.length) return;
  const r = await fetch("data/population_ramp.json").then(x => x.json()).catch(() => null);
  if (!r) return;
  const html = r.colours.map((c, i) =>
    `<i style="background:${c}"></i><b>${fmt(r.breaks[i])}</b>`).join("");
  boxes.forEach(b => b.innerHTML = html);
}

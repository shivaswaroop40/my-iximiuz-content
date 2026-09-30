// Helpers over Excalidraw's element skeleton API, in a "pen on graph paper" style:
// thin black ink, 3D-ish objects with gray shading, blue curves for connections,
// salmon clouds for callouts, and free-floating handwritten labels.

export const INK = "#1e1e1e";
export const BLUE = "#2f6fe4";
export const SALMON = "#f08c8c";
export const RED = "#e03131";
export const GREEN = "#2f9e44";
export const MUTED = "#868e96";
const FACE_TOP = "#f1f3f5";
const FACE_SIDE = "#dee2e6";
const FONT = 1; // Virgil, Excalidraw's original hand-drawn font: for notes, callouts and titles
export const LABEL_FONT = 6; // Nunito, Excalidraw's "Normal" font: for the names of things

const shapes = new Map(); // id -> { x, y, w, h } of the front face, for anchoring curves

const base = { roughness: 1, strokeWidth: 1.5, strokeColor: INK, fillStyle: "solid", roundness: null };

// Free-floating handwritten text. align: left | center | right (x is the anchor).
export function text(x, y, str, o = {}) {
  // Excalidraw's converter treats x as the left edge, the centre or the right edge
  // depending on textAlign, so x is simply the anchor.
  return {
    type: "text", x, y, text: str, fontSize: o.size || 22, fontFamily: o.font || FONT,
    strokeColor: o.color || INK, textAlign: o.align || "left",
  };
}

function poly(points, o = {}) {
  const [x0, y0] = points[0];
  return {
    ...base, type: "line", x: x0, y: y0,
    points: points.map(([x, y]) => [x - x0, y - y0]),
    backgroundColor: o.fill || "transparent", strokeColor: o.color || INK,
    strokeWidth: o.strokeWidth || base.strokeWidth, strokeStyle: o.dashed ? "dashed" : "solid",
    roundness: o.smooth ? { type: 2 } : null,
  };
}

// A 3D block: white front face, light top, darker right side. Label goes on the front.
export function block(id, x, y, w, h, label, o = {}) {
  const d = o.depth ?? 22;
  shapes.set(id, { x, y, w, h, d });
  const els = [
    poly([[x, y], [x + d, y - d], [x + w + d, y - d], [x + w, y], [x, y]], { fill: FACE_TOP, dashed: o.dashed }),
    poly([[x + w, y], [x + w + d, y - d], [x + w + d, y + h - d], [x + w, y + h], [x + w, y]], { fill: FACE_SIDE, dashed: o.dashed }),
    { ...base, type: "rectangle", id, x, y, width: w, height: h, backgroundColor: "#ffffff",
      strokeStyle: o.dashed ? "dashed" : "solid" },
  ];
  if (label) els.push(text(x + w / 2, y + (o.labelY ?? h / 2 - (label.split("\n").length * (o.size || 22) * 1.25) / 2), label,
    { size: o.size || 22, align: "center", color: o.color, font: o.font || LABEL_FONT }));
  return els;
}

// A sheet of paper with a folded corner: a Kubernetes object you can `cat`.
export function doc(id, x, y, w, h, title, body = "", o = {}) {
  const f = 22;
  shapes.set(id, { x, y, w, h, d: 0 });
  return [
    { ...base, type: "rectangle", id, x, y, width: w, height: h, backgroundColor: "transparent", strokeColor: "transparent" },
    poly([[x, y], [x + w - f, y], [x + w, y + f], [x + w, y + h], [x, y + h], [x, y]], { fill: "#ffffff", color: o.color }),
    poly([[x + w - f, y], [x + w - f, y + f], [x + w, y + f]], { fill: FACE_SIDE, color: o.color }),
    text(x + 16, y + 12, title, { size: o.titleSize || 22, color: o.color, font: o.titleFont || LABEL_FONT }),
    ...(body ? [text(x + 16, y + 12 + (o.titleSize || 22) * 1.5, body, { size: o.size || 17, font: o.bodyFont || 3, color: o.bodyColor || o.color })] : []),
  ];
}

// A database cylinder (etcd).
export function cylinder(id, x, y, w, h, label) {
  const e = 26;
  shapes.set(id, { x, y, w, h, d: 0 });
  const bottom = [];
  for (let i = 0; i <= 12; i++) {
    const a = Math.PI * (i / 12);
    bottom.push([x + w / 2 - (w / 2) * Math.cos(a), y + h - e / 2 + (e / 2) * Math.sin(a)]);
  }
  return [
    { ...base, type: "rectangle", id, x, y, width: w, height: h, backgroundColor: "transparent", strokeColor: "transparent" },
    poly([[x, y + e / 2], ...bottom, [x + w, y + e / 2], [x, y + e / 2]], { fill: "#ffffff", color: "transparent" }),
    poly([[x, y + e / 2], [x, y + h - e / 2]]),
    poly([[x + w, y + e / 2], [x + w, y + h - e / 2]]),
    poly(bottom, { smooth: true }),
    { ...base, type: "ellipse", x, y, width: w, height: e, backgroundColor: FACE_TOP },
    text(x + w / 2, y + h / 2 - 8, label, { size: 22, align: "center", font: LABEL_FONT }),
  ];
}

// A bumpy cloud callout with text inside.
export function cloud(id, cx, cy, w, h, label, o = {}) {
  const color = o.color || SALMON;
  shapes.set(id, { x: cx - w / 2, y: cy - h / 2, w, h, d: 0 });
  // Scallops: walk around an ellipse and bulge each segment outwards like a bump of a cloud.
  const n = Math.max(9, Math.round((w + h) / 45));
  const ring = (i) => [cx + (w / 2) * 0.9 * Math.cos((2 * Math.PI * i) / n), cy + (h / 2) * 0.82 * Math.sin((2 * Math.PI * i) / n)];
  const pts = [];
  for (let i = 0; i < n; i++) {
    const [ax, ay] = ring(i), [bx, by] = ring(i + 1);
    const len = Math.hypot(bx - ax, by - ay), nx = (by - ay) / len, ny = -(bx - ax) / len; // outward normal
    for (let k = 0; k < 6; k++) {
      const t = k / 6, bump = Math.sin(Math.PI * t) * len * 0.32;
      pts.push([ax + (bx - ax) * t + nx * bump, ay + (by - ay) * t + ny * bump]);
    }
  }
  pts.push(pts[0]);
  return [
    { ...base, type: "rectangle", id, x: cx - w / 2, y: cy - h / 2, width: w, height: h, backgroundColor: "transparent", strokeColor: "transparent" },
    poly(pts, { smooth: true, color, fill: "#ffffff" }),
    text(cx, cy - (label.split("\n").length * (o.size || 19) * 1.25) / 2, label, { size: o.size || 19, align: "center", color: o.textColor || INK }),
  ];
}

// A stick figure (the human in the loop).
export function person(x, y, label = "you") {
  return [
    { ...base, type: "ellipse", x: x - 14, y, width: 28, height: 28, backgroundColor: "#ffffff" },
    poly([[x, y + 28], [x, y + 72]]),
    poly([[x - 22, y + 44], [x, y + 38], [x + 22, y + 44]]),
    poly([[x - 16, y + 104], [x, y + 72], [x + 16, y + 104]]),
    text(x, y + 112, label, { size: 22, align: "center" }),
  ];
}

// A trash can (the garbage collector).
export function bin(id, x, y, w, h, label) {
  shapes.set(id, { x, y, w, h, d: 0 });
  const t = 10;
  return [
    { ...base, type: "rectangle", id, x, y, width: w, height: h, backgroundColor: "transparent", strokeColor: "transparent" },
    poly([[x - 6, y + 14], [x + w + 6, y + 14], [x + w + 2, y], [x - 2, y], [x - 6, y + 14]], { fill: FACE_TOP }),
    poly([[x + w / 2 - 12, y], [x + w / 2 - 10, y - 8], [x + w / 2 + 10, y - 8], [x + w / 2 + 12, y]]),
    poly([[x, y + 14], [x + t, y + h], [x + w - t, y + h], [x + w, y + 14], [x, y + 14]], { fill: "#ffffff" }),
    poly([[x + w * 0.3, y + 26], [x + w * 0.34, y + h - 10]]),
    poly([[x + w * 0.5, y + 26], [x + w * 0.5, y + h - 10]]),
    poly([[x + w * 0.7, y + 26], [x + w * 0.66, y + h - 10]]),
    text(x + w / 2, y + h + 10, label, { size: 20, align: "center", font: LABEL_FONT }),
  ];
}

// Where to attach a curve on a shape: left/right/top/bottom of the front face, plus offset.
export function at(id, side, offset = 0) {
  const s = shapes.get(id);
  if (!s) throw new Error(`unknown shape ${id}`);
  switch (side) {
    case "left": return [s.x, s.y + s.h / 2 + offset];
    case "right": return [s.x + s.w + (s.d || 0) / 2, s.y + s.h / 2 + offset];
    case "top": return [s.x + s.w / 2 + offset, s.y - (s.d || 0) / 2];
    case "bottom": return [s.x + s.w / 2 + offset, s.y + s.h];
  }
}

// A smooth hand-drawn curve through points; arrowhead at the end unless head: false.
export function curve(points, o = {}) {
  const [x0, y0] = points[0];
  const head = o.head === false ? null : o.head || "arrow";
  return {
    ...base, type: head ? "arrow" : "line", x: x0, y: y0,
    points: points.map(([x, y]) => [x - x0, y - y0]),
    strokeColor: o.color || BLUE, strokeWidth: o.strokeWidth || 2, strokeStyle: o.dashed ? "dashed" : "solid",
    roundness: points.length > 2 ? { type: 2 } : null,
    ...(head ? { endArrowhead: head, startArrowhead: o.both ? head : null } : {}),
  };
}

// A big red hand-drawn cross over a shape.
export function cross(x, y, w, h) {
  return [
    poly([[x, y], [x + w, y + h]], { color: RED, strokeWidth: 2.5 }),
    poly([[x + w, y], [x, y + h]], { color: RED, strokeWidth: 2.5 }),
  ];
}

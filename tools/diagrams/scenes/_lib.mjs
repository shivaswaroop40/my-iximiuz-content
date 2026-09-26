// Tiny helpers over Excalidraw's element skeleton API, so scenes read like a sketch.
// Colours are Excalidraw's own palette: pastel fill + matching darker stroke.

export const C = {
  blue: { bg: "#a5d8ff", stroke: "#1971c2" },
  green: { bg: "#b2f2bb", stroke: "#2f9e44" },
  yellow: { bg: "#ffec99", stroke: "#f08c00" },
  red: { bg: "#ffc9c9", stroke: "#e03131" },
  violet: { bg: "#d0bfff", stroke: "#6741d9" },
  gray: { bg: "#e9ecef", stroke: "#495057" },
  white: { bg: "#ffffff", stroke: "#1e1e1e" },
  none: { bg: "transparent", stroke: "#1e1e1e" },
};
export const INK = "#1e1e1e";
export const MUTED = "#868e96";

const boxes = new Map();

// A rounded, filled box with a centred label. Remembers its geometry for arrows.
export function box(id, x, y, w, h, text, color = C.white, o = {}) {
  boxes.set(id, { x, y, w, h });
  return {
    type: o.shape || "rectangle", id, x, y, width: w, height: h,
    backgroundColor: color.bg, strokeColor: color.stroke, fillStyle: o.fill || "solid",
    strokeWidth: o.strokeWidth || 2, strokeStyle: o.dashed ? "dashed" : "solid",
    roughness: 1, roundness: o.sharp ? null : { type: 3 },
    ...(text ? { label: { text, fontSize: o.fontSize || 20, strokeColor: o.textColor || color.stroke, textAlign: o.align || "center", verticalAlign: o.valign || "middle" } } : {}),
  };
}

// A zone: a big dashed outline with a title in its top-left corner.
export function zone(id, x, y, w, h, title, color = C.gray) {
  boxes.set(id, { x, y, w, h });
  return [
    { type: "rectangle", id, x, y, width: w, height: h, backgroundColor: "transparent", strokeColor: color.stroke,
      strokeStyle: "dashed", strokeWidth: 1, roughness: 1, roundness: { type: 3 } },
    text(x + 16, y + 10, title, { size: 18, color: color.stroke }),
  ];
}

export function text(x, y, str, o = {}) {
  return { type: "text", x, y, text: str, fontSize: o.size || 18, strokeColor: o.color || INK, textAlign: o.align || "left" };
}

function anchor(id, side, offset = 0) {
  const b = boxes.get(id);
  if (!b) throw new Error(`unknown box ${id}`);
  switch (side) {
    case "left": return [b.x, b.y + b.h / 2 + offset];
    case "right": return [b.x + b.w, b.y + b.h / 2 + offset];
    case "top": return [b.x + b.w / 2 + offset, b.y];
    case "bottom": return [b.x + b.w / 2 + offset, b.y + b.h];
  }
}

// An arrow from one box's side to another's, bound to both so it follows them when edited.
// via: optional list of absolute [x, y] waypoints for elbows.
export function arrow(from, fromSide, to, toSide, o = {}) {
  const [x1, y1] = anchor(from, fromSide, o.fromOffset);
  const [x2, y2] = anchor(to, toSide, o.toOffset);
  const pts = [[0, 0], ...(o.via || []).map(([x, y]) => [x - x1, y - y1]), [x2 - x1, y2 - y1]];
  return {
    type: "arrow", x: x1, y: y1, width: x2 - x1, height: y2 - y1, points: pts,
    strokeColor: o.color || INK, strokeWidth: o.strokeWidth || 2, strokeStyle: o.dashed ? "dashed" : "solid",
    roughness: 1, endArrowhead: o.noHead ? null : "arrow", startArrowhead: o.both ? "arrow" : null,
    start: { id: from }, end: { id: to },
  };
}

// A free arrow between two points (not bound to any box).
export function line(x1, y1, x2, y2, o = {}) {
  const pts = [[0, 0], ...(o.via || []).map(([x, y]) => [x - x1, y - y1]), [x2 - x1, y2 - y1]];
  return {
    type: o.head === false ? "line" : "arrow", x: x1, y: y1, width: x2 - x1, height: y2 - y1, points: pts,
    strokeColor: o.color || INK, strokeWidth: o.strokeWidth || 2, strokeStyle: o.dashed ? "dashed" : "solid",
    roughness: 1, ...(o.head === false ? {} : { endArrowhead: "arrow", startArrowhead: o.both ? "arrow" : null }),
  };
}

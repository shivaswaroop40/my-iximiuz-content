import { INK, BLUE, SALMON, MUTED, text, block, cloud, curve } from "../_lib.mjs";

// 1 minute = 230px. mochi is fed at t=0 with feedEvery: 1m, and fed again at t=4m.
const M = 230, X0 = 130;
const t = (min) => X0 + min * M;
const MOOD_Y = 190, POD_Y = 320, AXIS_Y = 430;

function wake(min, label) {
  return [
    { type: "ellipse", x: t(min) - 9, y: 132, width: 18, height: 18, backgroundColor: BLUE, strokeColor: BLUE, fillStyle: "solid", roughness: 1 },
    text(t(min), 78, label, { size: 18, align: "center", color: BLUE }),
    curve([[t(min), 152], [t(min), AXIS_Y - 4]], { head: false, dashed: true, strokeWidth: 1 }),
  ];
}

function band(id, from, to, label, o = {}) {
  return block(id, t(from), MOOD_Y, (to - from) * M, 70, label, { depth: 10, size: 22, ...o });
}

export default {
  name: "hunger-timeline",
  out: "tutorials/build-a-kubernetes-operator-from-scratch/__static__",
  elements: [
    text(620, -80, "mochi's day", { size: 40, align: "center" }),

    ...wake(0, "feed mochi"),
    ...wake(1, "RequeueAfter"),
    ...wake(3, "RequeueAfter"),
    ...wake(4, "feed mochi"),
    ...cloud("quiet", t(2), 70, 250, 80, "nobody touches\nthe Pet here", { size: 17 }),

    text(0, MOOD_Y + 20, "mood", { size: 24 }),
    ...band("happy", 0, 1, "Happy ( ^.^ )"),
    ...band("hungry", 1, 3, "Hungry ( o.o )"),
    ...band("gone", 3, 4, "ran away", { dashed: true }),
    ...band("happy2", 4, 4.9, "Happy ( ^.^ )"),

    text(0, POD_Y + 12, "Pod", { size: 24 }),
    ...block("pod1", t(0), POD_Y, 3 * M, 50, "Pod mochi", { depth: 10, size: 20 }),
    text(t(3.5), POD_Y + 12, "deleted", { size: 20, align: "center", color: MUTED }),
    ...block("pod2", t(4), POD_Y, 0.9 * M, 50, "new Pod", { depth: 10, size: 20 }),

    curve([[t(0) - 30, AXIS_Y], [t(2.5), AXIS_Y + 3], [t(5.1), AXIS_Y]], { color: INK }),
    text(t(0), AXIS_Y + 14, "lastFedAt", { size: 19, align: "center" }),
    text(t(1), AXIS_Y + 14, "+ feedEvery", { size: 19, align: "center" }),
    text(t(3), AXIS_Y + 14, "+ 3 x feedEvery", { size: 19, align: "center" }),
    text(t(4), AXIS_Y + 14, "fed again", { size: 19, align: "center" }),
    text(t(5.1) - 30, AXIS_Y - 34, "time", { size: 19, color: MUTED }),
  ],
};

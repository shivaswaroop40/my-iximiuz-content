import { C, MUTED, INK, box, text, line } from "../_lib.mjs";

const OUT = "tutorials/build-a-kubernetes-operator-from-scratch/__static__";
// 1 minute = 220px. mochi is fed at t=0 with feedEvery: 1m, and fed again at t=4m.
const M = 220, X0 = 60;
const t = (min) => X0 + min * M;
const MOOD_Y = 120, POD_Y = 230, AXIS_Y = 320;

function wake(min, label, color = C.violet) {
  return [
    { type: "ellipse", x: t(min) - 11, y: 58, width: 22, height: 22, backgroundColor: color.bg, strokeColor: color.stroke, fillStyle: "solid", roughness: 1 },
    text(t(min) - 70, 0, label, { size: 15, color: color.stroke, align: "center" }),
    line(t(min), 82, t(min), AXIS_Y, { head: false, dashed: true, color: color.stroke, strokeWidth: 1 }),
  ];
}

export default {
  name: "hunger-timeline",
  out: OUT,
  elements: [
    // When Reconcile runs
    ...wake(0, "  feed mochi:\n  spec changed"),
    ...wake(1, "RequeueAfter\n  fires"),
    ...wake(3, "RequeueAfter\n  fires"),
    ...wake(4, "  feed mochi:\n  spec changed"),
    text(t(1.6), 25, "nobody touches\nthe Pet here", { size: 15, color: MUTED }),

    // Mood
    text(0 - 50, MOOD_Y + 18, "mood", { size: 18 }),
    box("happy", t(0), MOOD_Y, M, 60, "Happy", C.green, { sharp: true }),
    box("hungry", t(1), MOOD_Y, 2 * M, 60, "Hungry", C.yellow, { sharp: true }),
    box("gone", t(3), MOOD_Y, M, 60, "RanAway", C.red, { sharp: true }),
    box("happy2", t(4), MOOD_Y, 0.8 * M, 60, "Happy", C.green, { sharp: true }),

    // Pod
    text(0 - 50, POD_Y + 12, "Pod", { size: 18 }),
    box("pod1", t(0), POD_Y, 3 * M, 44, "Pod mochi exists", C.green, { sharp: true, fontSize: 17 }),
    box("nopod", t(3), POD_Y, M, 44, "deleted", C.white, { sharp: true, dashed: true, fontSize: 17, textColor: MUTED }),
    box("pod2", t(4), POD_Y, 0.8 * M, 44, "new Pod", C.green, { sharp: true, fontSize: 17 }),

    // Time axis
    line(t(0) - 20, AXIS_Y, t(4.9), AXIS_Y, { color: INK }),
    text(t(0) - 25, AXIS_Y + 12, "lastFedAt", { size: 16 }),
    text(t(1) - 60, AXIS_Y + 12, "+ feedEvery", { size: 16 }),
    text(t(3) - 75, AXIS_Y + 12, "+ 3 x feedEvery", { size: 16 }),
    text(t(4) - 30, AXIS_Y + 12, "fed again", { size: 16 }),
    text(t(4.9) - 20, AXIS_Y - 30, "time", { size: 16, color: MUTED }),
  ],
};

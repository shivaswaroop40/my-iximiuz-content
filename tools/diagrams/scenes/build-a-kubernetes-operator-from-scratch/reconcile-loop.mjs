import { C, MUTED, box, text, arrow, line } from "../_lib.mjs";

const OUT = "tutorials/build-a-kubernetes-operator-from-scratch/__static__";

export default {
  name: "reconcile-loop",
  out: OUT,
  elements: [
    text(0, 0, "What wakes the controller up, and what it does then", { size: 26 }),

    // Triggers
    box("t-pet", 0, 70, 280, 70, "a Pet is created,\nchanged or deleted", C.blue, { fontSize: 17 }),
    box("t-owned", 0, 160, 280, 70, "a Pod or ConfigMap owned\nby a Pet changes: queue\nthe owner", C.green, { fontSize: 16 }),
    box("t-timer", 0, 250, 280, 70, "a RequeueAfter\ntimer fires", C.yellow, { fontSize: 17 }),
    box("t-start", 0, 340, 280, 70, "the operator starts:\nLIST everything", C.gray, { fontSize: 17 }),

    box("queue", 380, 170, 200, 140, "work queue\n\nzoo/mochi\nzoo/smaug", C.white, { fontSize: 18 }),
    text(380, 320, "just names,\nno duplicates", { size: 15, color: MUTED }),

    arrow("t-pet", "right", "queue", "left", { toOffset: -45 }),
    arrow("t-owned", "right", "queue", "left", { toOffset: -15 }),
    arrow("t-timer", "right", "queue", "left", { toOffset: 15 }),
    arrow("t-start", "right", "queue", "left", { toOffset: 45 }),

    // Reconcile
    box("rec", 680, 60, 400, 380, null, C.violet),
    text(700, 72, "Reconcile(ctx, \"zoo/mochi\")", { size: 22, color: C.violet.stroke }),
    box("s1", 705, 120, 350, 60, "1. observe: read the Pet\n(from the informer cache)", C.white, { fontSize: 16, textColor: C.violet.stroke }),
    box("s2", 705, 195, 350, 60, "2. compute: mood from\nlastFedAt + feedEvery + now", C.white, { fontSize: 16, textColor: C.violet.stroke }),
    box("s3", 705, 270, 350, 60, "3. act: CreateOrUpdate the card,\ncreate or delete the Pod", C.white, { fontSize: 16, textColor: C.violet.stroke }),
    box("s4", 705, 345, 350, 75, "4. report: write status,\nreturn RequeueAfter =\ntime until the mood changes", C.white, { fontSize: 16, textColor: C.violet.stroke }),
    arrow("s1", "bottom", "s2", "top", { color: C.violet.stroke }),
    arrow("s2", "bottom", "s3", "top", { color: C.violet.stroke }),
    arrow("s3", "bottom", "s4", "top", { color: C.violet.stroke }),

    arrow("queue", "right", "rec", "left", { fromOffset: -30, toOffset: -30 }),
    text(592, 175, "one\nat a time", { size: 14 }),

    // Loops back
    arrow("s4", "bottom", "t-timer", "left", { color: C.yellow.stroke, dashed: true, via: [[880, 500], [-40, 500], [-40, 285]] }),
    text(330, 470, "schedules the next wake-up (\"call me again in 60s\")", { size: 15, color: C.yellow.stroke }),
    box("err", 1130, 200, 200, 90, "error? e.g. a\nconflict: back in\nthe queue, backoff", C.red, { fontSize: 15 }),
    line(1080, 245, 1128, 245, { color: C.red.stroke }),
    line(1230, 200, 480, 168, { color: C.red.stroke, dashed: true, via: [[1230, 48], [480, 48]] }),
  ],
};

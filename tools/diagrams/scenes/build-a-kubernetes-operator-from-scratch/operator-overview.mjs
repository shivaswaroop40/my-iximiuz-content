import { C, MUTED, box, zone, text, arrow } from "../_lib.mjs";

const OUT = "tutorials/build-a-kubernetes-operator-from-scratch/__static__";

export default {
  name: "operator-overview",
  out: OUT,
  elements: [
    box("you", 0, 90, 170, 90, "you\n(kubectl)", C.gray),

    ...zone("api", 250, 0, 380, 330, "kube-apiserver + etcd"),
    box("pet", 280, 50, 320, 250, null, C.blue),
    text(300, 62, "Pet  zoo/mochi", { size: 22, color: C.blue.stroke }),
    text(300, 102, "spec:\n  species: cat\n  diet:\n    feedEvery: 10m\n  lastFedAt: 12:00", { size: 17, color: C.blue.stroke }),
    text(300, 222, "status:\n  mood: Happy", { size: 17, color: C.violet.stroke }),

    box("ctrl", 760, 95, 250, 110, "pet-operator\nReconcile loop", C.violet, { fontSize: 22 }),

    box("cm", 640, 440, 230, 90, "ConfigMap\nmochi-card", C.yellow),
    box("pod", 990, 440, 200, 90, "Pod\nmochi", C.green),

    arrow("you", "right", "pet", "left", { toOffset: -60 }),
    text(180, 58, "writes spec\n(apply, feed)", { size: 16 }),

    arrow("pet", "right", "ctrl", "left", { fromOffset: -70, toOffset: -25 }),
    text(640, 50, "watch", { size: 16 }),
    arrow("ctrl", "left", "pet", "right", { fromOffset: 25, toOffset: 60 }),
    text(652, 225, "write status", { size: 16, color: C.violet.stroke }),

    arrow("ctrl", "bottom", "cm", "top", { fromOffset: -50 }),
    text(650, 330, "CreateOrUpdate\nthe card", { size: 16, color: C.violet.stroke }),
    arrow("ctrl", "bottom", "pod", "top", { fromOffset: 50 }),
    text(1000, 330, "create, or delete\nif it ran away", { size: 16, color: C.violet.stroke }),

    arrow("cm", "right", "pod", "left"),
    text(890, 440, "mounted\nat /pet", { size: 14 }),

    arrow("cm", "left", "pet", "bottom", { dashed: true, color: MUTED, via: [[440, 485]] }),
    text(470, 370, "ownerReferences:\nboth point at\nthe Pet", { size: 16, color: MUTED }),
    arrow("pod", "bottom", "pet", "bottom", { dashed: true, color: MUTED, fromOffset: 0, toOffset: -60, via: [[1090, 580], [380, 580]] }),
  ],
};

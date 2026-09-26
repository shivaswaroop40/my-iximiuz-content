import { INK, BLUE, SALMON, RED, MUTED, text, block, doc, cloud, bin, cross, curve } from "../_lib.mjs";

export default {
  name: "ownership-gc",
  out: "tutorials/build-a-kubernetes-operator-from-scratch/__static__",
  elements: [
    // Left: the bash controller leaves orphans
    text(200, 0, "bash controller", { size: 32, align: "center" }),
    ...doc("goldie", 70, 110, 200, 110, "Pet goldie", "species: dog", { size: 16 }),
    ...cross(80, 120, 180, 90),
    text(170, 70, "kubectl delete pet goldie", { size: 17, align: "center", color: MUTED }),
    ...block("gpod", 70, 300, 200, 110, "Pod\ngoldie", { size: 22 }),
    text(170, 430, "ownerReferences: none", { size: 18, align: "center" }),
    ...cloud("orphan", 320, 560, 280, 110, "an orphan:\nit runs forever"),
    curve([[260, 420], [285, 470], [300, 500]], { color: SALMON, head: false }),

    curve([[480, -10], [485, 300], [478, 620]], { color: MUTED, head: false, dashed: true, strokeWidth: 1 }),

    // Right: the operator's children are garbage-collected
    text(850, 0, "pet-operator", { size: 32, align: "center" }),
    ...doc("smaug", 560, 110, 200, 110, "Pet smaug", "species: dragon", { size: 16 }),
    ...cross(570, 120, 180, 90),
    text(660, 70, "kubectl delete pet smaug", { size: 17, align: "center", color: MUTED }),
    ...block("spod", 560, 330, 170, 100, "Pod\nsmaug", { size: 22 }),
    ...doc("scm", 780, 320, 200, 120, "ConfigMap", "smaug-card", { size: 16, titleSize: 20 }),
    curve([[640, 308], [630, 268], [640, 226]], { color: SALMON, dashed: true }),
    curve([[870, 318], [860, 250], [765, 205]], { color: SALMON, dashed: true }),
    text(672, 262, "ownerReferences", { size: 18, color: SALMON }),

    ...bin("gc", 1080, 110, 100, 120, "garbage collector"),
    curve([[1070, 205], [1010, 290], [982, 360]], { color: RED }),
    curve([[1130, 280], [1100, 520], [700, 520], [650, 434]], { color: RED }),
    text(860, 548, "owner gone? delete its dependents", { size: 19, color: RED }),
  ],
};

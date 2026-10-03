import { LABEL_FONT, INK, BLUE, SALMON, RED, GREEN, MUTED, text, block, doc, cloud, curve } from "../_lib.mjs";

// The scenario: four animals, each a Deployment; Smaug keeps leaving because its cave is too cold.
const frame = (x, y, w, h) => ({ type: "rectangle", x, y, width: w, height: h, roughness: 1, strokeWidth: 1.5,
  strokeColor: MUTED, strokeStyle: "dashed", backgroundColor: "transparent", fillStyle: "solid", roundness: { type: 3 } });

export default {
  name: "2-the-zoo",
  out: "docs/diagrams",
  elements: [
    text(760, 0, "The zoo", { size: 48, align: "center", font: LABEL_FONT }),
    text(760, 70, "namespace zoo · every animal is a Deployment with one Pod", { size: 21, align: "center", color: MUTED }),

    frame(20, 130, 1480, 300),
    text(40, 142, "namespace: zoo", { size: 19, color: MUTED }),

    ...block("mochi", 70, 220, 200, 110, "mochi\ncat", { size: 24 }),
    text(170, 350, "Running", { size: 22, align: "center", color: GREEN }),
    ...block("rex", 330, 220, 200, 110, "rex\ndog", { size: 24 }),
    text(430, 350, "Running", { size: 22, align: "center", color: GREEN }),
    ...block("prickles", 590, 220, 200, 110, "prickles\ncactus", { size: 24 }),
    text(690, 350, "Running", { size: 22, align: "center", color: GREEN }),

    ...block("smaug", 880, 220, 210, 110, "smaug\ndragon", { size: 24, dashed: true, color: RED }),
    text(985, 350, "Error, restarting", { size: 22, align: "center", color: RED }),

    ...doc("cave", 1180, 200, 300, 130, "ConfigMap smaug-cave", "temperature: \"12\"", { size: 19, titleSize: 20 }),
    curve([[1176, 285], [1145, 300], [1116, 285]]),
    text(1146, 245, "mounted", { size: 18, color: BLUE, align: "center" }),
    text(1330, 372, "too cold!", { size: 22, color: RED }),
    curve([[1340, 370], [1330, 330], [1300, 285]], { color: RED }),

    ...cloud("words", 985, 560, 470, 160, "\"Brr. The cave is 12°C.\nDragons need at least 40°C.\nSmaug is leaving.\""),
    curve([[985, 400], [985, 440], [985, 480]], { color: SALMON, head: false }),
    text(985, 655, "Smaug's log, every time it starts", { size: 18, align: "center", color: MUTED }),

    text(40, 490, "what keeps happening:", { size: 21 }),
    text(40, 528, "Pod starts -> reads /cave/temperature -> 12 < 40\n-> prints its last words -> exit 1\n-> Kubernetes restarts it -> CrashLoopBackOff", { size: 19, color: MUTED }),
    text(40, 660, "the fix: set temperature to 45, restart smaug", { size: 21, color: GREEN }),
  ],
};

import { C, MUTED, box, zone, text, arrow } from "../_lib.mjs";

const OUT = "tutorials/build-a-kubernetes-operator-from-scratch/__static__";

export default {
  name: "ownership-gc",
  out: OUT,
  elements: [
    // Left: the bash controller
    ...zone("left", 0, 0, 440, 400, "bash controller (Part 2)"),
    box("goldie", 40, 60, 170, 70, "Pet goldie\n(deleted)", C.blue, { dashed: true, textColor: MUTED }),
    box("gpod", 40, 240, 200, 90, "Pod goldie\nownerReferences: none", C.green, { fontSize: 16 }),
    text(250, 255, "still running,\nforever", { size: 17, color: C.red.stroke }),
    text(60, 160, "nothing links them", { size: 16, color: MUTED }),

    // Right: the operator
    ...zone("right", 500, 0, 700, 400, "pet-operator (Part 3)"),
    box("smaug", 540, 60, 170, 70, "Pet smaug", C.blue),
    box("spod", 540, 240, 190, 90, "Pod smaug", C.green),
    box("scm", 760, 240, 190, 90, "ConfigMap\nsmaug-card", C.yellow),
    arrow("spod", "top", "smaug", "bottom", { dashed: true, color: MUTED, fromOffset: -40, toOffset: -40 }),
    arrow("scm", "top", "smaug", "bottom", { dashed: true, color: MUTED, toOffset: 40, via: [[855, 172], [665, 172]] }),
    text(690, 186, "ownerReferences\n(controller: true)", { size: 15, color: MUTED }),

    box("gc", 990, 60, 180, 90, "garbage\ncollector", C.gray),
    text(725, 62, "kubectl delete\npet smaug", { size: 16 }),
    arrow("gc", "bottom", "scm", "right", { color: C.red.stroke, fromOffset: 40, via: [[1120, 285]] }),
    arrow("gc", "bottom", "spod", "bottom", { color: C.red.stroke, fromOffset: 70, via: [[1150, 360], [635, 360]] }),
    text(955, 165, "owner gone:\ndelete dependents", { size: 15, color: C.red.stroke }),
  ],
};

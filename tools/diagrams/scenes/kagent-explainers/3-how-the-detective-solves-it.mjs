import { LABEL_FONT, INK, BLUE, SALMON, RED, GREEN, MUTED, text, block, doc, cloud, person, curve } from "../_lib.mjs";

// The investigation: one question, four trips to the model, three tool calls, then the fix.
export default {
  name: "3-how-the-detective-solves-it",
  out: "docs/diagrams",
  elements: [
    text(760, 0, "How the detective solves it", { size: 48, align: "center", font: LABEL_FONT }),

    ...block("model", 250, 110, 220, 100, "model", { size: 26 }),
    ...block("det", 240, 340, 240, 120, "detective\nagent Pod", { size: 24 }),
    curve([[300, 336], [280, 280], [300, 216]]),
    text(170, 262, "everything\nso far", { size: 18, color: BLUE, align: "center" }),
    curve([[420, 216], [440, 280], [420, 336]]),
    text(470, 262, "next tool,\nor the answer", { size: 18, color: BLUE }),

    ...person(70, 330),
    text(90, 480, "\"Where is Smaug?\"", { size: 20, align: "center" }),
    curve([[104, 380], [170, 395], [236, 395]]),

    ...doc("pods", 600, 330, 270, 165, "1  Pods in zoo", "mochi     Running\nrex       Running\nprickles  Running\nsmaug     Error", { size: 16, titleSize: 21 }),
    ...doc("logs", 930, 330, 280, 165, "2  smaug's logs", "Brr. The cave is 12°C.\nDragons need 40°C.\nSmaug is leaving.", { size: 16, titleSize: 21 }),
    ...doc("cave", 1270, 330, 310, 165, "3  ConfigMap smaug-cave", "temperature: \"12\"", { size: 17, titleSize: 20 }),

    curve([[482, 380], [540, 360], [596, 380]]),
    text(540, 400, "list\nPods", { size: 18, color: BLUE, align: "center" }),
    curve([[872, 380], [900, 360], [926, 380]]),
    text(900, 255, "smaug is\nfailing:\nread its logs", { size: 18, color: RED, align: "center" }),
    curve([[1212, 380], [1240, 360], [1266, 380]]),
    text(1240, 255, "the logs name\na ConfigMap:\nread it", { size: 18, color: RED, align: "center" }),

    ...cloud("answer", 1050, 640, 600, 150, "4  \"Found Smaug. The cave is 12°C,\ndragons need 40°C. Fix the ConfigMap.\""),
    curve([[1425, 500], [1400, 545], [1330, 585]], { color: SALMON, head: false }),

    text(40, 600, "5  you warm the cave to 45°C\n    and restart smaug", { size: 21, color: GREEN }),
    text(40, 690, "    ask again: \"Everyone's home.\"", { size: 21, color: GREEN }),

    ...cloud("trip", 760, 140, 460, 140, "each trip, the model asks for ONE tool.\nthe detective runs it and sends\neverything back. the model remembers nothing."),
    curve([[530, 150], [500, 160], [474, 165]], { color: SALMON, head: false }),
  ],
};

import { LABEL_FONT, INK, BLUE, SALMON, MUTED, text, block, doc, cloud, person, curve } from "../_lib.mjs";

// The investigation: one question, four trips to the model, three tool calls through the
// tool server, then the fix. The agent Pod reasons; kagent-tools is what actually reads the cluster.
export default {
  name: "3-how-the-detective-solves-it",
  out: ["docs/diagrams", "tutorials/run-ai-agents-on-kubernetes-with-kagent/__static__"],
  elements: [
    text(780, 0, "How the detective solves it", { size: 48, align: "center", font: LABEL_FONT }),

    // the loop: the model and the detective Pod, trips between them
    ...block("model", 210, 150, 190, 90, "model", { size: 24 }),
    ...block("det", 200, 360, 215, 115, "detective\nagent Pod", { size: 22 }),
    curve([[255, 356], [233, 280], [255, 246]]),
    text(150, 266, "everything\nso far", { size: 17, color: BLUE, align: "center" }),
    curve([[360, 246], [382, 280], [360, 356]]),
    text(402, 266, "next tool,\nor the answer", { size: 17, color: BLUE }),

    ...person(60, 330, ""),
    text(95, 470, "\"Where is Smaug?\"", { size: 19, align: "center" }),
    curve([[120, 400], [160, 418], [196, 418]]),

    // the model remembers nothing: the detective re-sends the whole conversation each trip
    ...cloud("trip", 250, 70, 400, 100, "the model remembers nothing —\nthe detective re-sends it all each trip"),
    curve([[300, 118], [280, 180], [300, 244]], { color: SALMON, head: false }),

    // the tool server is what actually touches the cluster
    ...block("tools", 490, 360, 230, 115, "kagent-tools\nruns every tool\nas cluster-admin", { size: 17 }),
    curve([[415, 418], [452, 418], [486, 418]]),
    text(450, 500, "run a tool", { size: 16, color: BLUE, align: "center" }),

    // the three reads, each a sheet the tool server fetches
    ...doc("pods", 560, 120, 250, 160, "1  Pods in zoo", "mochi     Running\nrex       Running\nprickles  Running\nsmaug     Error", { size: 16, titleSize: 20 }),
    ...doc("logs", 900, 120, 275, 160, "2  smaug's logs", "Brr. The cave is 12°C.\nDragons need 40°C.\nSmaug is leaving.", { size: 16, titleSize: 20 }),
    ...doc("cave", 1265, 120, 300, 160, "3  ConfigMap smaug-cave", "temperature: \"12\"", { size: 17, titleSize: 20 }),

    curve([[590, 358], [610, 330], [655, 284]]),
    text(600, 308, "list Pods", { size: 16, color: BLUE, align: "center" }),
    curve([[700, 358], [880, 334], [1015, 284]]),
    text(950, 312, "read its logs", { size: 16, color: BLUE, align: "center" }),
    curve([[716, 360], [1080, 334], [1385, 284]]),
    text(1330, 316, "read the ConfigMap", { size: 16, color: BLUE, align: "center" }),

    // the write-up, and the fix (yours, not the agent's)
    ...cloud("answer", 1075, 600, 560, 150, "4  \"Found Smaug. The cave is 12°C,\ndragons need 40°C — fix the ConfigMap.\""),
    curve([[1385, 284], [1260, 480], [1145, 552]], { color: SALMON, head: false }),

    text(55, 545, "5  you warm the cave to 45°C and restart smaug,", { size: 19, color: MUTED }),
    text(55, 575, "    then ask again — \"Everyone's home.\"", { size: 19, color: MUTED }),
  ],
};

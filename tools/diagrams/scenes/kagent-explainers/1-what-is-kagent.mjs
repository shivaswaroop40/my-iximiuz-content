import { LABEL_FONT, INK, BLUE, SALMON, MUTED, text, block, doc, cylinder, cloud, person, curve } from "../_lib.mjs";

// What kagent is: an operator for AI agents. YAML in, a running agent loop out.
export default {
  name: "1-what-is-kagent",
  out: "docs/diagrams",
  elements: [
    text(780, 0, "What kagent actually is", { size: 48, align: "center", font: LABEL_FONT }),

    ...person(70, 230, "you write\nYAML"),
    ...doc("agent", 150, 160, 300, 220, "Agent detective",
      "systemMessage: |\n  You are the zoo's\n  detective...\nmodelConfig: claude\ntools:\n  - k8s_get_resources\n  - k8s_get_pod_logs", { size: 16 }),

    curve([[452, 260], [500, 245], [556, 262]]),
    text(504, 168, "kubectl\napply", { size: 19, color: BLUE, align: "center" }),

    ...block("ctrl", 560, 220, 250, 120, "kagent\ncontroller", { size: 26 }),

    ...doc("mc", 470, 500, 240, 125, "ModelConfig", "which LLM, which\nAPI key Secret", { size: 16, titleSize: 20 }),
    ...doc("rmcp", 750, 500, 250, 125, "RemoteMCPServer", "where the tools\nlive (124 of them)", { size: 16, titleSize: 20 }),
    curve([[640, 395], [610, 450], [590, 496]], { color: MUTED, dashed: true }),
    curve([[740, 395], [790, 450], [850, 496]], { color: MUTED, dashed: true }),
    text(685, 430, "looks up", { size: 18, align: "center", color: MUTED }),

    curve([[812, 262], [870, 240], [926, 258]]),
    text(870, 112, "creates a Deployment,\nService, Secret", { size: 18, color: BLUE, align: "center" }),
    ...block("pod", 930, 200, 270, 140, "detective Pod\nthe agent loop", { size: 24 }),

    ...block("llm", 1330, 70, 240, 110, "LLM\nClaude / GPT / stub", { size: 21 }),
    curve([[1150, 196], [1220, 120], [1326, 112]]),
    text(1150, 92, "question +\nlist of tools", { size: 18, color: BLUE, align: "center" }),
    curve([[1360, 186], [1300, 250], [1206, 262]]),
    text(1352, 238, "\"run this tool\"\nor the answer", { size: 18, color: BLUE }),

    ...block("tools", 1330, 380, 240, 110, "kagent-tools\nMCP tool server", { size: 21 }),
    curve([[1120, 344], [1180, 420], [1326, 436]]),
    text(1130, 430, "runs the tool", { size: 18, color: BLUE, align: "center" }),
    ...cylinder("api", 1365, 590, 170, 120, "kube-apiserver"),
    curve([[1450, 494], [1460, 540], [1450, 586]]),
    text(1470, 525, "kubectl get...", { size: 17, color: BLUE }),

    ...cloud("op", 300, 690, 420, 140, "an operator for AI agents:\nYAML in, running agent out"),
    curve([[330, 622], [480, 470], [640, 345]], { color: SALMON, head: false }),
    ...cloud("text", 1030, 700, 400, 140, "the model only writes text.\nthe tools do things."),
    curve([[1200, 670], [1290, 620], [1330, 470]], { color: SALMON, head: false }),
  ],
};

import { LABEL_FONT, INK, BLUE, SALMON, RED, GREEN, MUTED, text, block, doc, cylinder, cloud, person, curve } from "../_lib.mjs";

// What a production setup adds around the same pieces: identity at the door, read-only tools,
// fenced networks, managed secrets, GitOps and traces.
export default {
  name: "4-production-best-practices",
  out: "docs/diagrams",
  elements: [
    text(860, 0, "kagent in production", { size: 48, align: "center", font: LABEL_FONT }),

    // callers
    ...person(110, 140, "developer\n(Claude Code, MCP)"),
    ...block("am", 30, 390, 200, 70, "Alertmanager", { size: 21 }),
    ...block("ci", 30, 520, 200, 70, "CI pipeline", { size: 21 }),

    // the door
    ...block("gate", 320, 290, 220, 170, "Gateway + TLS\noauth2-proxy\ncompany SSO", { size: 20 }),
    curve([[150, 200], [240, 230], [316, 330]]),
    curve([[234, 425], [270, 420], [316, 395]]),
    curve([[234, 555], [280, 520], [316, 440]]),
    text(430, 480, "A2A / MCP,\nwith a token", { size: 18, color: BLUE, align: "center" }),

    ...block("ctrl", 640, 320, 210, 110, "kagent\ncontroller", { size: 24 }),
    curve([[544, 372], [590, 360], [636, 372]]),
    text(590, 300, "verified\nuser", { size: 17, color: BLUE, align: "center" }),
    text(745, 450, "NetworkPolicy: only the proxy\nreaches :8083. trusted-proxy\nmode doesn't check signatures.", { size: 18, color: RED, align: "center" }),

    ...block("agents", 950, 320, 210, 110, "agents\nlook, don't touch", { size: 21 }),
    curve([[854, 372], [900, 360], [946, 372]]),

    ...block("tools", 1260, 310, 240, 130, "kagent-tools\nrbac.readOnly\n+ rules for your CRDs", { size: 19 }),
    curve([[1164, 372], [1210, 360], [1256, 372]]),
    text(1210, 330, "MCP", { size: 17, color: BLUE, align: "center" }),
    text(1170, 210, "NetworkPolicy: only agent\nPods reach the tool server", { size: 18, color: RED }),

    ...cylinder("api", 1590, 320, 170, 110, "kube-apiserver"),
    curve([[1506, 372], [1550, 360], [1586, 372]]),
    text(1546, 455, "get / list / watch", { size: 17, color: BLUE, align: "center" }),

    // model path
    ...block("aigw", 950, 580, 210, 100, "AI gateway\nlimits, cost, logs", { size: 19 }),
    ...block("llm", 1260, 580, 240, 100, "LLM provider\nHaiku / Sonnet", { size: 21 }),
    curve([[1055, 434], [1065, 500], [1055, 576]]),
    curve([[1164, 630], [1210, 620], [1256, 630]]),
    ...doc("secret", 620, 580, 250, 130, "ModelConfig", "apiKeySecret from\nExternal Secrets\nor Vault", { size: 16, titleSize: 20 }),
    curve([[872, 620], [910, 615], [946, 625]], { color: MUTED, dashed: true }),

    // gitops + traces
    ...doc("git", 900, 60, 400, 120, "Git", "Agents, ModelConfigs,\nRemoteMCPServers\nreviewed in PRs, synced by Argo CD", { size: 15, titleSize: 20 }),
    curve([[898, 130], [790, 170], [745, 300]], { color: MUTED, dashed: true }),
    ...cylinder("otel", 1590, 570, 170, 110, "traces (OTel)"),
    curve([[1164, 420], [1350, 520], [1560, 530], [1610, 566]], { color: MUTED, dashed: true }),

    // principles
    ...cloud("p1", 330, 820, 520, 140, "the tool server holds the keys:\nread-only, scoped to what\nagents need. no Secrets."),
    ...cloud("p2", 880, 830, 520, 140, "Ready doesn't mean working:\nask each agent a known\nquestion in CI"),
    ...cloud("p3", 1450, 820, 520, 140, "pin versions: kagent v1\nmoves to api.kagent.dev.\nhumans approve every write."),
  ],
};

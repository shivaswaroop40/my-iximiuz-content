import { LABEL_FONT, INK, BLUE, SALMON, text, block, doc, cloud, person, curve } from "../_lib.mjs";

export default {
  name: "operator-overview",
  out: "tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c/__static__",
  elements: [
    text(660, 0, "A Pet Operator", { size: 48, align: "center", font: LABEL_FONT }),

    ...person(80, 190),
    curve([[112, 250], [190, 240], [258, 280]], { color: INK }),
    text(118, 330, "kubectl apply\n& feed mochi", { size: 20 }),

    ...block("api", 262, 160, 330, 305, "kube-apiserver + etcd", { labelY: 10, size: 20 }),
    ...doc("pet", 285, 200, 285, 240, "Pet zoo/mochi",
      "spec:\n  species: cat\n  diet:\n    feedEvery: 10m\n  lastFedAt: \"12:00\"\nstatus:\n  mood: Happy"),

    ...block("ctrl", 820, 190, 260, 165, "pet-operator", { labelY: 16, size: 26 }),
    curve([[912, 282], [950, 296], [990, 282], [982, 256], [950, 250], [920, 262]], { color: INK, strokeWidth: 1.5 }),
    text(950, 312, "reconcile loop", { size: 18, align: "center" }),

    curve([[572, 245], [700, 205], [818, 232]]),
    text(690, 178, "watch", { size: 20, color: BLUE }),
    curve([[818, 292], [700, 350], [574, 400]]),
    text(632, 272, "writes status", { size: 20, color: BLUE }),

    ...doc("cm", 700, 480, 240, 185, "ConfigMap mochi-card", "  /\\_/\\\n ( ^.^ )\n  > ^ <\nmochi is happy.", { titleSize: 18, size: 17 }),
    ...block("pod", 1040, 510, 200, 140, "Pod\nmochi", { size: 24 }),

    curve([[900, 357], [870, 420], [840, 478]]),
    text(668, 425, "CreateOrUpdate", { size: 19, color: BLUE }),
    curve([[1010, 357], [1080, 420], [1130, 488]]),
    text(1095, 395, "creates, or deletes\nif it runs away", { size: 19, color: BLUE }),
    curve([[942, 575], [990, 568], [1038, 580]]),
    text(990, 540, "mounted", { size: 17, color: BLUE, align: "center" }),

    ...cloud("refs", 450, 650, 330, 120, "ownerReferences:\nboth point at the Pet"),
    curve([[450, 590], [455, 530], [440, 468]], { color: SALMON, dashed: true }),
    curve([[698, 600], [650, 630], [616, 640]], { color: SALMON, head: false }),
    curve([[1140, 652], [1100, 730], [800, 740], [606, 685]], { color: SALMON, head: false }),
  ],
};

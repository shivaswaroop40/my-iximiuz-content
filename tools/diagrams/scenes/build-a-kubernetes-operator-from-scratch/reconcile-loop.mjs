import { INK, BLUE, SALMON, text, block, cloud, curve } from "../_lib.mjs";

export default {
  name: "reconcile-loop",
  out: "tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c/__static__",
  elements: [
    text(640, 0, "What wakes the controller up", { size: 40, align: "center" }),

    // Triggers: every one of them just drops a name into the queue
    text(0, 100, "a Pet is created,\nchanged or deleted", { size: 20 }),
    text(0, 195, "an owned Pod or ConfigMap\nchanges: queue its owner", { size: 20 }),
    text(0, 290, "a RequeueAfter\ntimer fires", { size: 20 }),
    text(0, 385, "the operator starts:\nLIST everything", { size: 20 }),
    curve([[205, 125], [300, 140], [398, 238]]),
    curve([[282, 220], [330, 240], [398, 262]]),
    curve([[168, 315], [290, 300], [398, 288]]),
    curve([[208, 410], [310, 390], [398, 312]]),

    ...block("queue", 400, 200, 220, 140, "work queue", { labelY: 12, size: 22 }),
    text(510, 250, "zoo/mochi\nzoo/smaug", { size: 19, align: "center", font: 3 }),
    text(510, 360, "just names,\nno duplicates", { size: 18, align: "center" }),

    curve([[642, 255], [690, 240], [738, 250]]),
    text(690, 200, "one at\na time", { size: 17, align: "center", color: BLUE }),

    ...block("rec", 740, 120, 430, 330, "Reconcile(\"zoo/mochi\")", { labelY: 14, size: 24 }),
    text(765, 175,
      "1. observe: get the Pet\n     from the cache\n" +
      "2. compute the mood from\n     lastFedAt, feedEvery, now\n" +
      "3. act: CreateOrUpdate the card,\n     create or delete the Pod\n" +
      "4. report: write status, return\n     RequeueAfter = time until\n     the mood changes", { size: 19 }),

    // The timer loop
    curve([[955, 452], [950, 570], [500, 600], [-40, 560], [-30, 330], [-4, 318]]),
    text(330, 548, "RequeueAfter: \"call me again in 60s\"", { size: 20, color: BLUE }),

    // Errors go back into the queue
    ...cloud("err", 1330, 300, 250, 130, "a conflict?\nback in the queue,\nwith a backoff"),
    curve([[1195, 300], [1215, 295], [1210, 300]], { color: SALMON, head: false }),
    curve([[1330, 234], [1300, 80], [520, 80], [510, 176]], { color: SALMON, dashed: true }),
  ],
};

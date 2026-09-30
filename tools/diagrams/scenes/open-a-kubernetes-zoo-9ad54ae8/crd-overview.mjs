import { LABEL_FONT, BLUE, RED, text, block, doc, cylinder, curve, cross } from "../_lib.mjs";

// The opening diagram of the zoo tutorial: what the reader ends up with.
export default {
  name: "crd-overview",
  out: "tutorials/open-a-kubernetes-zoo-9ad54ae8/__static__",
  elements: [
    text(700, 0, "A Pet API that the API server enforces", { size: 44, align: "center", font: LABEL_FONT }),

    // The two folders of manifests the learner starts with.
    ...doc("adopted", 20, 130, 300, 128, "~/pets/adopted/",
      "mochi     cat\nrex       dog\nsmaug     dragon\nprickles  cactus", { titleSize: 20, size: 16 }),
    ...doc("turned", 20, 385, 300, 150, "~/pets/turned-away/",
      "sparkles       unicorn\nspiky-ball     cactus, toy\nsnacky-dragon  every 15m\nlazy-dragon    no diet\nwhenever       feedEvery?", { titleSize: 20, size: 16 }),

    // The API server, with the CRD you build in six layers.
    ...block("api", 420, 150, 430, 440, "kube-apiserver", { labelY: 10, size: 24 }),
    ...doc("crd", 445, 205, 380, 335, "CRD pets.zoo.example.com",
      "names     Pet, pets, pt, zoo\n\nschema    types, enum, lengths,\n          pattern, date-time\n\nCEL       no toys for cacti,\n          dragons eat at most hourly\n\ndefaults  diet: snacks every 10m\n\nstatus    its own /status endpoint\n\ncolumns   kubectl get pets",
      { titleSize: 20, size: 16 }),

    curve([[322, 205], [370, 210], [418, 245]]),
    text(338, 150, "kubectl\napply", { size: 18, color: BLUE }),
    curve([[322, 460], [370, 460], [418, 430]]),
    curve([[418, 525], [340, 610], [205, 600]], { color: RED }),
    ...cross(172, 588, 26, 26),
    text(60, 628, "rejected, with a clear error", { size: 18, color: RED }),

    // Accepted Pets, completed by the defaults, land in etcd.
    ...cylinder("etcd", 1040, 160, 190, 150, "etcd"),
    curve([[875, 238], [950, 226], [1036, 238]]),
    text(880, 150, "stored, with\ndefaults filled in", { size: 17, color: BLUE }),

    // And kubectl shows them with the columns you defined.
    ...doc("get", 925, 395, 450, 160, "kubectl get pets -n zoo",
      "NAME      SPECIES  MOOD   TOY\nmochi     cat      Happy  yarn\nprickles  cactus\nrex       dog             stick\nsmaug     dragon", { titleSize: 20, size: 16 }),
    curve([[1135, 312], [1135, 350], [1125, 393]]),

  ],
};

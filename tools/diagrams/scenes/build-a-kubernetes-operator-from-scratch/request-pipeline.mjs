import { C, MUTED, box, text, arrow, line } from "../_lib.mjs";

const OUT = "tutorials/build-a-kubernetes-operator-from-scratch/__static__";
const Y = 60, H = 110, W = 190, GAP = 50;
const x = (i) => 170 + i * (W + GAP);

export default {
  name: "request-pipeline",
  out: OUT,
  elements: [
    text(0, 0, "What happens to a Pet on its way to etcd", { size: 26 }),

    box("in", 0, Y + 15, 120, 80, "kubectl\napply", C.gray),
    box("decode", x(0), Y, W, H, "1. decode\nunknown fields\nare pruned", C.blue, { fontSize: 18 }),
    box("default", x(1), Y, W, H, "2. defaulting\ndiet: {} then\nsnacks, 10m", C.blue, { fontSize: 18 }),
    box("mutate", x(2), Y, W, H, "mutating\nwebhooks", C.gray, { dashed: true, fontSize: 18 }),
    box("validate", x(3), Y, W, H, "3. validation\nOpenAPI schema\n+ CEL rules", C.blue, { fontSize: 18 }),
    box("vwh", x(4), Y, W, H, "validating\nwebhooks", C.gray, { dashed: true, fontSize: 18 }),
    box("etcd", x(5), Y + 15, 130, 80, "etcd", C.green, { fontSize: 22 }),

    arrow("in", "right", "decode", "left"),
    arrow("decode", "right", "default", "left"),
    arrow("default", "right", "mutate", "left"),
    arrow("mutate", "right", "validate", "left"),
    arrow("validate", "right", "vwh", "left"),
    arrow("vwh", "right", "etcd", "left"),
    text(x(2) + 10, Y + H + 12, "(none here)", { size: 15, color: MUTED }),
    text(x(4) + 10, Y + H + 12, "(none here)", { size: 15, color: MUTED }),

    // What mochi and friends run into
    box("r-unicorn", x(3) - 20, 260, 230, 70, "species: unicorn\nnot in the enum", C.red, { fontSize: 16 }),
    box("r-cactus", x(3) - 20, 345, 230, 70, "cactus with a toy\nCEL rule says no", C.red, { fontSize: 16 }),
    line(x(3) + W / 2, Y + H, x(3) + W / 2, 258, { color: C.red.stroke }),

    box("dragon", x(1) - 20, 440, 230, 80, "dragon, no diet\ngets feedEvery: 10m", C.yellow, { fontSize: 16 }),
    box("r-dragon", x(3) - 20, 440, 230, 80, "then fails\n\"at most once an hour\"", C.red, { fontSize: 16 }),
    arrow("dragon", "right", "r-dragon", "left", { color: C.red.stroke }),
    line(x(1) + W / 2, Y + H, x(1) + W / 2, 438, { color: C.yellow.stroke, dashed: true }),
    text(x(1) - 20, 530, "defaulting runs before validation", { size: 16, color: C.yellow.stroke }),

    box("ok", x(5) - 40, 260, 190, 70, "mochi, a cat\nwith yarn: stored", C.green, { fontSize: 16 }),
    line(x(5) + 65, Y + 95, x(5) + 55, 258, { color: C.green.stroke }),
  ],
};

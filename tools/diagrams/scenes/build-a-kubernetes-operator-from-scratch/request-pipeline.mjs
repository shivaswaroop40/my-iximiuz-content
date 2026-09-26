import { BLUE, SALMON, RED, text, block, doc, cloud, cylinder, curve } from "../_lib.mjs";

const Y = 150, W = 170, H = 100;
const x = (i) => 170 + i * 215;
const mid = (i) => x(i) + W / 2;

export default {
  name: "request-pipeline",
  out: "tutorials/build-a-kubernetes-operator-from-scratch/__static__",
  elements: [
    text(700, 0, "What happens to a Pet on its way to etcd", { size: 40, align: "center" }),

    ...doc("pet", 0, 140, 125, 120, "Pet", "species:\n  dragon", { size: 15 }),
    ...block("decode", x(0), Y, W, H, "decode,\nprune unknown\nfields", { size: 19 }),
    ...block("default", x(1), Y, W, H, "defaulting", { size: 22 }),
    ...block("mutate", x(2), Y, W, H, "mutating\nwebhooks", { size: 20, dashed: true }),
    ...block("validate", x(3), Y, W, H, "schema\n+ CEL rules", { size: 22 }),
    ...block("vwh", x(4), Y, W, H, "validating\nwebhooks", { size: 20, dashed: true }),
    ...cylinder("etcd", x(5), Y - 10, 120, 130, "etcd"),
    text(mid(2), Y + H + 10, "(none here)", { size: 17, align: "center" }),
    text(mid(4), Y + H + 10, "(none here)", { size: 17, align: "center" }),

    curve([[127, 200], [148, 190], [168, 200]]),
    ...[0, 1, 2, 3].map((i) => curve([[x(i) + W + 12, Y + H / 2 - 12], [x(i) + W + 28, Y + H / 2 - 20], [x(i + 1) - 2, Y + H / 2]])),
    curve([[x(4) + W + 12, Y + H / 2 - 12], [x(4) + W + 30, Y + H / 2 - 20], [x(5) - 2, Y + H / 2]]),

    // Rejected at validation
    ...cloud("unicorn", 700, 370, 270, 105, "species: unicorn?\nnot in the enum"),
    ...cloud("cactus", 1110, 370, 270, 105, "a cactus with a toy?\nthe CEL rule says no"),
    curve([[mid(3) - 20, Y + H + 4], [800, 290], [730, 322]], { color: SALMON, head: false }),
    curve([[mid(3) + 20, Y + H + 4], [990, 290], [1080, 322]], { color: SALMON, head: false }),

    // The lazy dragon: defaulted first, rejected second
    ...cloud("dragon", 400, 470, 300, 130, "a dragon with no diet\ngets the default\nfeedEvery: 10m"),
    curve([[mid(1), Y + H + 4], [mid(1) - 10, 340], [415, 410]], { color: SALMON, head: false }),
    ...cloud("fails", 900, 560, 300, 115, "...and then fails\n\"at most once an hour\""),
    curve([[mid(3), Y + H + 4], [895, 400], [900, 505]], { color: SALMON, head: false }),
    curve([[548, 500], [680, 560], [748, 560]], { color: RED }),
    text(240, 595, "defaulting runs before validation", { size: 21, color: RED }),

    // Accepted
    text(x(5) + 60, 310, "mochi, a cat\nwith yarn:\nstored", { size: 19, align: "center", color: BLUE }),
    curve([[x(5) + 60, Y + 125], [x(5) + 64, 285], [x(5) + 60, 305]]),
  ],
};

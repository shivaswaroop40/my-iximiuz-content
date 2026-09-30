# Diagrams

Hand-drawn, Excalidraw-style diagrams for the tutorials and challenges, rendered with
Excalidraw's own library (v0.18), so they look exactly like excalidraw.com exports.

```
scenes/_lib.mjs                  helpers: palette, box(), zone(), text(), arrow(), line()
scenes/<slug>/<name>.mjs         one diagram, described in code
excalidraw/<slug>/<name>.excalidraw  editable source (open on excalidraw.com)
excalidraw/<slug>/<name>.svg     SVG preview, fonts inlined (GitHub renders it)
<scene.out>/<name>.png           what the markdown embeds, e.g. tutorials/<slug>/__static__/
```

## Build

```sh
cd tools/diagrams
npm install
npm run build                 # all diagrams
npm run build -- hunger       # only scenes whose path contains "hunger"
```

It needs a Chromium. Get one with `npx playwright install chromium` and point `CHROMIUM_PATH` at it (the default is `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`).

Embed a diagram in markdown with alt text that says what it shows:

```md
![Mochi's hunger over time: Happy, then Hungry, then it runs away until fed again.](__static__/hunger-timeline.png)
```

## Editing by hand

1. Open `excalidraw/<slug>/<name>.excalidraw` on [excalidraw.com](https://excalidraw.com) (File > Open).
2. Drag things around, restyle, draw.
3. Save it back over the same file (File > Save to disk).
4. `npm run build`: a saved file (its `source` is no longer `"generated"`) wins over the `.mjs` scene,
   and the PNG is re-exported from your version.

To go back to the generated version, delete the `.excalidraw` file and rebuild.

## Style

Pen on graph paper, after the hand-drawn diagrams on iximiuz Labs:

- **Faint 20px grid** behind everything (added at export time, so the `.excalidraw` files stay clean).
- **Thin black ink**, with two fonts: the names of things (block labels, document titles, the text inside a block)
  use Nunito (`LABEL_FONT`), a regular font; notes, callouts, curve labels and titles use Virgil hand-lettering.
  Keep the handwriting for what a person would scribble next to the drawing.
- **Objects are drawn, not boxed**: `block()` for things that run (API server, controller, Pod) as 3D blocks
  with a light top and a gray side; `doc()` for Kubernetes objects you can `cat` (a sheet with a folded
  corner and mono-spaced YAML); `cylinder()` for etcd; `bin()` for the garbage collector; `person()` for you.
- **Colour is only for meaning**:

  | colour | used for |
  |---|---|
  | blue `#2f6fe4` | data flow and actions: smooth `curve()`s, like cables |
  | salmon `#f08c8c` | callouts: `cloud()`s and the lines tying them to things, ownerReferences |
  | red `#e03131` | errors, rejections, deletion, `cross()`-ing things out |
  | gray `#868e96` | commands and side notes |

- Curves, not straight arrows. Labels sit next to curves, never on them.
- One idea per diagram, 2x PNG.

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

It needs a Chromium; set `CHROMIUM_PATH` if it isn't at `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`.

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

- **Excalifont** (Excalidraw's default hand-drawn font), roughness 1, stroke width 2.
- Excalidraw's palette, pastel fill with a matching darker stroke and label:

  | role | colour |
  |---|---|
  | custom resources (Pet), API objects you write | blue `#a5d8ff` / `#1971c2` |
  | Pods, things that run, success | green `#b2f2bb` / `#2f9e44` |
  | ConfigMaps, timers, warnings, defaults | yellow `#ffec99` / `#f08c00` |
  | controllers, Reconcile | violet `#d0bfff` / `#6741d9` |
  | errors, rejections, deletion | red `#ffc9c9` / `#e03131` |
  | users, tools, optional or not-used parts | gray `#e9ecef` / `#495057` (dashed if optional) |

- Dashed gray arrows for references (ownerReferences); solid black arrows for actions and data flow.
- Dashed zones with a title for "where it runs" (kube-apiserver + etcd, a controller).
- One idea per diagram, labels next to arrows rather than on them, white background, 2x PNG.

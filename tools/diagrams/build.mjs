// Renders every scene in scenes/**/*.mjs with Excalidraw's own exporter.
//
// For each scene it writes:
//   <scene.out>/<scene.name>.png         the image the markdown embeds (2x, white background)
//   excalidraw/<slug>/<scene.name>.svg   an SVG preview (fonts inlined) that GitHub renders
//   excalidraw/<slug>/<scene.name>.excalidraw   the editable source: open it on excalidraw.com,
//                                        tweak, and save it back to override the generated one
//
// Usage: npm run build [-- <filter>]      e.g. npm run build -- reconcile
import { build } from "esbuild";
import { chromium } from "playwright-core";
import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const CHROMIUM = process.env.CHROMIUM_PATH || "/opt/pw-browsers/chromium-1194/chrome-linux/chrome";
const filter = process.argv[2] || "";

await build({
  entryPoints: [path.join(HERE, "src/entry.js")],
  bundle: true,
  format: "iife",
  outfile: path.join(HERE, "build/bundle.js"),
  minify: true,
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env": "{}" },
  loader: { ".css": "empty", ".woff2": "empty" },
  logLevel: "warning",
});

// Serve this directory so the page can fetch the bundle and Excalidraw's fonts.
const server = http.createServer(async (req, res) => {
  const file = req.url === "/" ? "src/index.html" : decodeURIComponent(req.url.split("?")[0]).slice(1);
  try {
    const body = await fs.readFile(path.join(HERE, file));
    const type = file.endsWith(".html") ? "text/html" : file.endsWith(".js") ? "text/javascript"
      : file.endsWith(".woff2") ? "font/woff2" : "application/octet-stream";
    res.writeHead(200, { "content-type": type }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/`;

async function findScenes(dir) {
  const out = [];
  for (const e of await fs.readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...(await findScenes(p)));
    else if (e.name.endsWith(".mjs") && !e.name.startsWith("_")) out.push(p);
  }
  return out.sort();
}

const browser = await chromium.launch({ executablePath: CHROMIUM });
const page = await browser.newPage();
page.on("pageerror", (e) => console.error("page error:", e.message));
await page.goto(base);
await page.waitForFunction(() => window.excalidrawExport);

let count = 0;
for (const file of await findScenes(path.join(HERE, "scenes"))) {
  const rel = path.relative(path.join(HERE, "scenes"), file);
  if (filter && !rel.includes(filter)) continue;
  const scene = (await import(pathToFileURL(file).href + `?t=${Date.now()}`)).default;
  const slug = path.dirname(rel);
  const editable = path.join(HERE, "excalidraw", slug, `${scene.name}.excalidraw`);

  // A hand-edited .excalidraw file (saved from excalidraw.com) wins over the generated scene.
  let saved = null;
  try {
    const json = JSON.parse(await fs.readFile(editable, "utf8"));
    if (json.source !== "generated") saved = json.elements;
  } catch {}

  const result = await page.evaluate(async ({ skeleton, saved, grid }) => {
    const { convertToExcalidrawElements, exportToSvg, exportToCanvas } = window.excalidrawExport;
    const elements = saved ?? convertToExcalidrawElements(skeleton, { regenerateIds: false });
    const pad = 36, scale = 2;
    const svg = await exportToSvg({
      elements, files: null, exportPadding: pad,
      appState: { exportBackground: true, viewBackgroundColor: "#ffffff", exportWithDarkMode: false },
    });
    // Draw the diagram on graph paper: white, with a faint 20px grid, like a sketchbook page.
    const art = await exportToCanvas({
      elements, files: null, exportPadding: pad,
      appState: { exportBackground: false, exportWithDarkMode: false },
      getDimensions: (w, h) => ({ width: w * scale, height: h * scale, scale }),
    });
    const page = document.createElement("canvas");
    page.width = art.width;
    page.height = art.height;
    const ctx = page.getContext("2d");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, page.width, page.height);
    if (grid) {
      ctx.strokeStyle = "#eceef1";
      ctx.lineWidth = 2;
      const step = 20 * scale;
      for (let x = 0.5; x < page.width; x += step) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, page.height); ctx.stroke(); }
      for (let y = 0.5; y < page.height; y += step) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(page.width, y); ctx.stroke(); }
    }
    ctx.drawImage(art, 0, 0);
    const blob = await new Promise((r) => page.toBlob(r, "image/png"));
    const png = Array.from(new Uint8Array(await blob.arrayBuffer()));
    return { elements, svg: svg.outerHTML, png };
  }, { skeleton: scene.elements, saved, grid: scene.grid !== false });

  const outDir = path.join(REPO, scene.out);
  await fs.mkdir(outDir, { recursive: true });
  await fs.writeFile(path.join(outDir, `${scene.name}.png`), Buffer.from(result.png));
  await fs.mkdir(path.dirname(editable), { recursive: true });
  await fs.writeFile(editable.replace(/\.excalidraw$/, ".svg"), result.svg);
  if (!saved) {
    await fs.writeFile(editable, JSON.stringify({
      type: "excalidraw", version: 2, source: "generated",
      elements: result.elements, appState: { viewBackgroundColor: "#ffffff", gridSize: null }, files: {},
    }, null, 2));
  }
  console.log(`${saved ? "edited   " : "generated"} ${rel} -> ${path.relative(REPO, outDir)}/${scene.name}.png`);
  count++;
}

await browser.close();
server.close();
console.log(`${count} diagram(s)`);

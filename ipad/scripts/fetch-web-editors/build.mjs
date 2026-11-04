import { build } from "esbuild";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";
const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(root, "../../Resources/WebTools/Excalidraw");
await fs.mkdir(output, { recursive: true });
await build({
  entryPoints: [path.join(root, "main.jsx")], bundle: true, minify: true,
  format: "iife", platform: "browser", target: ["safari18"],
  conditions: ["production"],
  outfile: path.join(output, "main.js"), legalComments: "linked",
  define: { "process.env.NODE_ENV": '"production"' },
  loader: { ".woff2": "file", ".woff": "file", ".ttf": "file", ".svg": "file", ".png": "file" },
  assetNames: "assets/[name]-[hash]"
});
await fs.cp(path.join(root, "node_modules/@excalidraw/excalidraw/dist/prod/fonts"), path.join(output, "fonts"), { recursive: true });
await fs.copyFile(path.join(root, "LICENSE.excalidraw"), path.join(output, "LICENSE"));
const policy = "default-src 'self' nomad-local: file: blob: data:; script-src 'self' nomad-local: file: 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' nomad-local: file: 'unsafe-inline'; img-src 'self' nomad-local: file: data: blob:; font-src 'self' nomad-local: file: data:; connect-src 'self' nomad-local: file: data: blob:; worker-src 'self' nomad-local: file: blob:; object-src 'none'; form-action 'none'; base-uri 'self'";
await fs.writeFile(path.join(output, "index.html"), `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"><meta http-equiv="Content-Security-Policy" content="${policy}"><title>Excalidraw — Offline</title><link rel="stylesheet" href="main.css"><script>window.EXCALIDRAW_ASSET_PATH=new URL('./',location.href).href;</script></head><body><div id="root"></div><script src="main.js"></script></body></html>`);
async function hashes(directory, base = directory) {
  const result = {};
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) Object.assign(result, await hashes(file, base));
    else if (entry.name !== "nomad-installation.json") result[path.relative(base, file)] = crypto.createHash("sha256").update(await fs.readFile(file)).digest("hex");
  }
  return result;
}
const lock = await fs.readFile(path.join(root, "package-lock.json"));
await fs.writeFile(path.join(output, "nomad-installation.json"), JSON.stringify({ project: "excalidraw/excalidraw", version: "0.18.1", package_lock_sha256: crypto.createHash("sha256").update(lock).digest("hex"), files: await hashes(output) }, null, 2));
console.log(`Built complete Excalidraw editor in ${output}`);

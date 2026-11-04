import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, exportToBlob, exportToSvg, serializeAsJSON, restore, convertToExcalidrawElements } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./style.css";

const STORE = "nomad-excalidraw-v1";
const openDatabase = () => new Promise((resolve, reject) => {
  const request = indexedDB.open(STORE, 1);
  request.onupgradeneeded = () => request.result.createObjectStore("documents");
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});
async function readSaved() {
  const db = await openDatabase();
  try {
    return await new Promise((resolve, reject) => {
      const request = db.transaction("documents").objectStore("documents").get("workspace");
      request.onsuccess = () => resolve(request.result || {});
      request.onerror = () => reject(request.error);
    });
  } finally { db.close(); }
}
async function saveWorkspace(value) {
  const db = await openDatabase();
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction("documents", "readwrite");
      tx.objectStore("documents").put(value, "workspace");
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error || new Error("Local save was interrupted"));
    });
  } finally { db.close(); }
}
function download(blob, filename) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url; anchor.download = filename;
  document.body.append(anchor); anchor.click(); anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

function Workspace() {
  const [api, setAPI] = useState(null);
  const [status, setStatus] = useState("Opening local workspace…");
  const [error, setError] = useState("");
  const [initialData, setInitialData] = useState(null);
  const library = useRef([]);
  const pending = useRef({});
  const saveTimer = useRef(null);
  const saveChain = useRef(Promise.resolve());
  const lastQueued = useRef("");
  const ready = useRef(false);
  const queueSave = useCallback(() => {
    if (!ready.current) return;
    const snapshot = JSON.stringify({ ...pending.current, libraryItems: library.current });
    if (snapshot === lastQueued.current) return;
    lastQueued.current = snapshot;
    clearTimeout(saveTimer.current);
    setStatus("Saving on this iPad…");
    saveTimer.current = setTimeout(() => {
      const value = JSON.parse(snapshot);
      saveChain.current = saveChain.current.catch(() => {}).then(() => saveWorkspace(value))
        .then(() => setStatus("Saved on this iPad"))
        .catch(error => { setError("Local save failed: " + error.message + ". Export a copy now."); setStatus("Not saved"); });
    }, 350);
  }, []);
  useEffect(() => {
    readSaved().then(saved => {
      library.current = saved.libraryItems || [];
      setInitialData({ ...saved, scrollToContent: true });
      ready.current = true;
      setStatus("Local workspace ready");
    }).catch(error => { setError("Could not open saved workspace: " + error.message); setInitialData({}); ready.current = true; });
  }, []);
  useEffect(() => {
    if (!api) return;
    // Exposes the pinned editor API to the reproducible local smoke test.
    window.nomadExcalidraw = {
      api, readSaved, saveWorkspace, convertToExcalidrawElements,
      exportJSON: () => serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local")
    };
    return () => { delete window.nomadExcalidraw; };
  }, [api]);
  async function exportDrawing(kind) {
    if (!api) return;
    try {
      const scene = { elements: api.getSceneElements(), appState: api.getAppState(), files: api.getFiles() };
      if (kind === "json") download(new Blob([serializeAsJSON(scene.elements, scene.appState, scene.files, "local")], { type: "application/json" }), "drawing.excalidraw");
      else if (kind === "png") download(await exportToBlob({ ...scene, mimeType: "image/png", exportPadding: 20 }), "drawing.png");
      else {
        const svg = await exportToSvg({ ...scene, exportPadding: 20 });
        download(new Blob([svg.outerHTML], { type: "image/svg+xml" }), "drawing.svg");
      }
    } catch (error) { setError("Export failed: " + error.message); }
  }
  async function importScene(event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file || !api) return;
    try {
      const content = JSON.parse(await file.text());
      if (content.type === "excalidrawlib") {
        await api.updateLibrary({ libraryItems: content.libraryItems || content.library, merge: true, openLibraryMenu: true });
      } else {
        if (!Array.isArray(content.elements)) throw new Error("Choose an .excalidraw scene or .excalidrawlib library file");
        if (api.getSceneElements().length && !confirm("Replace the current drawing? Export it first if you need a separate copy.")) return;
        const scene = restore(content, null, null);
        api.updateScene({ ...scene, appState: { ...scene.appState, isLoading: false } });
        if (content.files) api.addFiles(Object.values(content.files));
        api.scrollToContent();
      }
      setError("");
    } catch (error) { setError("Import failed: " + error.message); }
  }
  return <div className="nomad-workspace">
    <header className="nomad-toolbar">
      <strong>Excalidraw</strong><span className="nomad-save-status" role="status">{status}</span>
      <label className="nomad-button">Import<input aria-label="Import drawing or library" type="file" accept=".excalidraw,.excalidrawlib,.json" hidden onChange={importScene} /></label>
      <button onClick={() => exportDrawing("json")}>Save .excalidraw</button>
      <button onClick={() => exportDrawing("png")}>PNG</button>
      <button onClick={() => exportDrawing("svg")}>SVG</button>
      <button onClick={() => download(new Blob([JSON.stringify({ type: "excalidrawlib", version: 2, source: "NomadPad", libraryItems: library.current })], { type: "application/json" }), "library.excalidrawlib")}>Save library</button>
    </header>
    {error && <div className="nomad-error" role="alert">{error}<button onClick={() => setError("")}>Dismiss</button></div>}
    <main>{initialData && <Excalidraw excalidrawAPI={setAPI} initialData={initialData}
      onChange={(elements, appState, files) => {
        // serializeAsJSON removes transient/non-cloneable editor state.
        pending.current = JSON.parse(serializeAsJSON(elements, appState, files, "local"));
        queueSave();
      }}
      onLibraryChange={items => { library.current = items; queueSave(); }}
      UIOptions={{ canvasActions: { export: { saveFileToDisk: true }, loadScene: true } }}
    />}</main>
  </div>;
}
createRoot(document.getElementById("root")).render(<Workspace />);

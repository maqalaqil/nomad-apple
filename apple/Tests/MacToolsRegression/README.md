# Native Mac tools checks

```sh
python3 apple/Tests/MacToolsRegression/run.py
python3 apple/Tests/MacToolsRegression/web.py
```

`run.py` runs 71 checks against the production Mac sketch stroke builder and vault clipboard helper. It creates pen, pencil, and marker strokes, serializes/reopens real PencilKit drawings, verifies point geometry and nonblank PNG pixels, rejects invalid/oversized strokes, verifies real eraser intersections while preserving empty areas inside diagonal/curved bounds, exercises affine transforms, varying widths, stroke masks, swept drags and all canvas zoom levels, checks safe rejection of excessive erase work and unchanged bytes for no-op gestures, and tests expiring copies plus preservation of newer copies. PencilKit runs inside a temporary app bundle with a unique identifier; the harness removes only its own test preferences domain. Clipboard tests use a unique named pasteboard; they do not read or modify the general clipboard or Keychain.

The native Mac sketch canvas preserves the existing PencilKit drawing format and supports pointer drawing, color/width/tool selection, whole-stroke erasing, zoom, and bounded undo/redo. iPhone/iPad retain PKCanvasView and its native tool picker. Mac edits are limited to 5,000 strokes, 20,000 points per new stroke, 64 MiB encoded drawing data, and 32 MiB/20 snapshots per undo/redo list. PNG exports remain bounded to 4,096 pixels on their longest side. Whole-stroke erasing uses interpolated PencilKit nib geometry and masks in drawing coordinates, with up to one-point sample spacing and a half-point tolerance after stroke transforms. It checks at most 250,000 samples per gesture; exceeding that limit preserves the drawing and shows a shorter-gesture error.

`web.py` requires the pinned CyberChef bundle to be fetched. It exercises the production Mac web-tool coordinator with a nonpersistent WKWebView: actual upstream Base64 conversion, remote-fetch blocking, and byte-exact native blob export. The view's native representable is separately SDK-typechecked. The harness opens no visible window and performs no deletion of browser data. It removes only its own temporary exported file and executable.

PDF output, inventory persistence, media/AVPlayer behavior, Files workspace safety, and vault cryptography retain their separate existing regression suites. Successful native checks do not establish signed-app Touch ID, macOS sandbox file panels, camera/microphone permission flows, every web utility, or physical iPhone/iPad input acceptance.

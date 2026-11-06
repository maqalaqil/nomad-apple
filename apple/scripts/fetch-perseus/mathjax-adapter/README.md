# Local MathJax adapter

This independently written Apache-2.0 module implements the renderer/speech
interface used by NOMAD's pinned Kolibri and math-input integration. It uses
MathJax 3.2.2 and Speech Rule Engine 4.1.5. No source from the unpublished-license
`@khanacademy/mathjax-renderer` package is included.

The npm dependency retains that import name as an alias to this local directory
so the pinned upstream integration can remain unchanged. The bundler verifies
the actual package identity and esbuild input paths and retains this source and
license in the generated distribution.

Fonts and speech maps resolve only under `nomad-perseus://local/renderer/`.
Speech Rule Engine's path is configured during module evaluation, before its
asynchronous startup can load a locale. Unsupported speech locales fall back
to English; this is not an Arabic speech engine. Imported Arabic text is
preserved using the system text font.

Each expression gets a fresh TeX processor to isolate user-defined macros.
Expression length and macro expansion are bounded. HTML/link/action macros are
excluded, and MathJax's safe handler rejects external URLs. A static CHTML
stylesheet supports previously rendered expressions when the input processor
changes; the live style element is replaced instead of accumulating copies.

Run the real WebKit regression after preparing dependencies:

```sh
node apple/scripts/fetch-perseus/mathjax-regression.mjs
```

It checks equation geometry, chemistry, colors, Arabic text, assistive MathML,
spoken labels, keypad speech, macro isolation, malformed/oversized input,
external-link/font rejection and network blocking. The existing full Perseus
smoke test separately exercises scoring, restoration and the mobile keypad.

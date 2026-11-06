// SPDX-License-Identifier: Apache-2.0
// Independently implemented against MathJax 3.2.2's public APIs. No source from
// @khanacademy/mathjax-renderer is incorporated into this adapter.
import {mathjax} from 'mathjax-full/js/mathjax.js';
import {TeX} from 'mathjax-full/js/input/tex.js';
import {CHTML} from 'mathjax-full/js/output/chtml.js';
import {browserAdaptor} from 'mathjax-full/js/adaptors/browserAdaptor.js';
import {RegisterHTMLHandler} from 'mathjax-full/js/handlers/html.js';
import {AssistiveMmlHandler} from 'mathjax-full/js/a11y/assistive-mml.js';
import {SafeHandler} from 'mathjax-full/js/ui/safe/SafeHandler.js';
import {AllPackages} from 'mathjax-full/js/input/tex/AllPackages.js';
import {setupEngine, engineReady, toSpeech} from 'speech-rule-engine/js/common/system.js';
import {SystemExternal} from 'speech-rule-engine/js/common/system_external.js';

const MAX_TEX_LENGTH = 16_384;
const LOCAL_ROOT = 'nomad-perseus://local/renderer/';
// SRE schedules its initial locale load in a microtask when imported. Configure
// its local map root during module evaluation, before that initialization runs.
SystemExternal.jsonPath = LOCAL_ROOT + 'speech/';
const supportedSpeech = new Set(['af','ca','da','de','en','es','fr','hi','it','ko','nb','nn','sv']);
const speechLocale = value => supportedSpeech.has(String(value).split(/[-_]/)[0]) ? String(value).split(/[-_]/)[0] : 'en';
const packages = AllPackages.filter(name => !['html','action','noerrors','noundefined'].includes(name));
const colors = {blue:'#1865f2',green:'#00856d',red:'#d92916',purple:'#9059ff',orange:'#bf5a00',gray:'#626569',pink:'#d33682',teal:'#008080',gold:'#997300',maroon:'#800000'};
// TeX expands #1 inside a macro, including a hex color beginning with #1.
// MathJax's RGB model keeps the color literal separate from argument markers.
const macros = Object.fromEntries(Object.entries(colors).map(([name,color]) => {
  const rgb = color.slice(1).match(/../g).map(value => parseInt(value,16)).join(',');
  return [name,[`\\textcolor[RGB]{${rgb}}{#1}`,1]];
}));
let registered = false;
function register() {
  if (!registered) {
    SafeHandler(AssistiveMmlHandler(RegisterHTMLHandler(browserAdaptor())));
    registered = true;
  }
}
function checkedTex(tex) {
  if (typeof tex !== 'string' || tex.length > MAX_TEX_LENGTH) throw Error('Math expression must be text of at most 16,384 characters.');
  return tex;
}
function localFontURL(value) {
  const url = new URL(value || LOCAL_ROOT + 'mathjax/fonts');
  if (url.protocol !== 'nomad-perseus:' || url.host !== 'local' || url.username || url.password || url.search || url.hash || !url.pathname.startsWith('/renderer/')) {
    throw Error('Math fonts must come from the bundled local renderer.');
  }
  return url.href.replace(/\/$/, '');
}

export class MathJaxRenderer {
  constructor({fontURL, locale = 'en'} = {}) {
    register();
    this.locale = speechLocale(locale);
    this.output = new CHTML({fontURL:localFontURL(fontURL), adaptiveCSS:false, mtextInheritFont:true});
    this.style = null;
  }
  render(source) {
    const tex = checkedTex(source);
    // A fresh input processor prevents a definition in one exercise from
    // changing subsequent exercises. The output cache contains font CSS only.
    const input = new TeX({packages, macros, maxBuffer:32_768, maxMacros:1_000,
      formatError:(_jax,error) => { throw Error('Math expression could not be rendered: ' + error.message); }});
    const document = mathjax.document(globalThis.document, {InputJax:input, OutputJax:this.output,
      enableAssistiveMml:true,
      safeOptions:{allow:{URLs:'none',classes:'none',cssIDs:'none',styles:'safe'}},
      compileError:(_document,_item,error) => { throw error; },
      typesetError:(_document,_item,error) => { throw error; }});
    const domElement = document.convert(tex, {display:false, em:16, ex:8, containerWidth:640});
    domElement.dataset.nomadTex = tex;
    this.document = document;
    const addLabel = async () => {
      const engine = await SpeechRuleEngine.setup(this.locale);
      const mml = domElement.querySelector('mjx-assistive-mml math');
      const label = mml ? engine.mathmlToSpeech(mml.outerHTML) : tex;
      domElement.setAttribute('aria-label', label || tex);
      domElement.setAttribute('lang', this.locale);
      return label;
    };
    return {domElement, normalizedTex:tex, error:null, addLabel};
  }
  getStyleSheet() {
    if (!this.document) throw Error('Render an expression before requesting its stylesheet.');
    return this.output.styleSheet(this.document);
  }
  updateStyles() {
    const next = this.getStyleSheet();
    // Keep a stable style element so rerendering cannot leave obsolete sheets.
    if (!this.style?.isConnected) {
      this.style = globalThis.document.createElement('style');
      this.style.dataset.nomadMathjax = 'true';
      globalThis.document.head.appendChild(this.style);
    }
    this.style.textContent = next.textContent;
  }
}

let setupQueue = Promise.resolve();
let speechRenderer;
export const SpeechRuleEngine = {
  setup(locale = 'en') {
    const selected = speechLocale(locale);
    // SRE has process-global locale state. Serialize setup calls and reapply
    // the requested locale for each synchronous conversion after initialization.
    const ready = setupQueue.then(async () => {
      SystemExternal.jsonPath = LOCAL_ROOT + 'speech/';
      await setupEngine({locale:selected, domain:'mathspeak', style:'default', mode:'http', json:LOCAL_ROOT + 'speech/'});
      await engineReady();
      const mathmlToSpeech = value => {
        // All supported maps are loaded above; the synchronous locale update
        // does not start a new network request.
        setupEngine({locale:selected});
        return toSpeech(value);
      };
      return {mathmlToSpeech, texToSpeech:tex => {
        speechRenderer ||= new MathJaxRenderer();
        const {domElement} = speechRenderer.render(tex);
        const mml = domElement.querySelector('mjx-assistive-mml math');
        return mml ? mathmlToSpeech(mml.outerHTML) : tex;
      }};
    });
    setupQueue = ready.catch(() => {});
    return ready;
  }
};

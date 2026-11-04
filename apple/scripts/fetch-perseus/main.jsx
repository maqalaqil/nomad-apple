import React from 'react';
import {createRoot} from 'react-dom/client';
import * as perseus from '@khanacademy/perseus';
import {parseAndMigratePerseusItem, isFailure} from '@khanacademy/perseus-core';
import {MathInputI18nContextProvider, MobileKeypad} from '@khanacademy/math-input';
import {KeypadContext, StatefulKeypadContextProvider} from '@khanacademy/keypad-context';
import {RenderStateRoot} from '@khanacademy/wonder-blocks-core';
import {SystemExternal} from 'speech-rule-engine/js/common/system_external.js';
import {scoreItem} from './upstream/scoring.js';
import {localizeNumericResponses, readUserInput} from './upstream/numericResponses.js';
import {wrapPerseusMessages} from './upstream/translationUtils.js';
import translator from './upstream/translator.js';
import TeX from './upstream/Tex.js';
import {logger} from './shims.js';
import pins from '../../Resources/WebTools/Perseus/release.json';
import '@khanacademy/wonder-blocks-tokens/styles.css';
import '@khanacademy/perseus/styles.css';
import '@khanacademy/math-input/styles.css';
import './style.css';

const ROOT = 'nomad-perseus://local/renderer/';
SystemExternal.jsonPath = ROOT + 'speech/';
const post = (type, body = {}) => window.webkit?.messageHandlers?.perseus?.postMessage({type, ...body});
const strings = wrapPerseusMessages(translator);
const noOpAnalyticsEvent = async () => {};
const dependencies = {analytics: {onAnalyticsEvent: noOpAnalyticsEvent}, generateUrl: ({url}) => url,
  useVideo: () => ({status: 'success', data: {video: null}})};
const staticURLs = new Map(pins.static_assets.map(asset => [asset.url, ROOT + 'static/' + asset.file]));
function staticURL(url) {
  if (staticURLs.has(url)) return staticURLs.get(url);
  if (/^(data:|blob:|nomad-perseus:)/.test(url)) return url;
  throw Error(`This exercise requires an unbundled built-in asset: ${url}`);
}
perseus.Dependencies.setDependencies({JIPT: {useJIPT: false}, TeX, isDevServer: false,
  kaLocale: 'en', isMobile: true, staticUrl: staticURL, Log: logger});
perseus.init();

// The original Graphie metadata/SVG pair is served from the exercise package.
const graphieBase = url => url.replace(/^web\+graphie:/, '');
perseus.Util.getDataUrl = url => graphieBase(url) + '-data.json';
perseus.Util.getSvgUrl = url => graphieBase(url) + '.svg';
perseus.Util.getRealImageUrl = url => perseus.Util.isLabeledSVG(url) ? perseus.Util.getSvgUrl(url) : (staticURLs.get(url) || url);
perseus.Util.getImageSizeModern = url => new Promise((resolve, reject) => {
  const image = new Image(); image.onload = () => resolve([image.naturalWidth, image.naturalHeight]);
  image.onerror = () => reject(Error('A required exercise image is missing from this package.'));
  image.src = perseus.Util.getRealImageUrl(url);
});
perseus.Util.getImageSize = (url, callback) => perseus.Util.getImageSizeModern(url).then(([width, height]) => callback?.(width, height)).catch(report);

let renderer, current, root, revision = 0, hintsVisible = 0, stateTimer, failed = false;
let loadResolve, loadReject;
function report(error) {
  failed = true;
  const message = String(error?.message || error);
  document.getElementById('error').textContent = message;
  post('error', {message}); loadReject?.(Error(message)); loadReject = null; loadResolve = null;
}
const mapStrings = (value, change) => typeof value === 'string' ? change(value) : Array.isArray(value)
  ? value.map(item => mapStrings(item, change)) : value && typeof value === 'object'
    ? Object.fromEntries(Object.entries(value).map(([key, item]) => [change(key), mapStrings(item, change)])) : value;
const localizeAssets = (value, base) => mapStrings(value, text => text.replaceAll('${☣ LOCALPATH}/', base));
const restoreAssets = value => mapStrings(value, text => text.replaceAll(current.assetBaseURL, '${☣ LOCALPATH}/'));
function answerState() {
  if (!renderer || !current) return null;
  return restoreAssets({userInput: readUserInput(renderer.getUserInput(), current.item.question.widgets, current.locale), hintsVisible});
}
function emitState() {
  if (renderer && current) post('state', {itemId: current.itemId, answerState: answerState(), hintsVisible});
}
function interaction() {
  requestAnimationFrame(emitState);
  clearTimeout(stateTimer); stateTimer = setTimeout(emitState, 100);
}

class ErrorBoundary extends React.Component {
  state = {failed: false};
  static getDerivedStateFromError() { return {failed: true}; }
  componentDidCatch(error) { report(error); }
  render() { return this.state.failed ? <p>This exercise could not be rendered.</p> : this.props.children; }
}

function Contents({generation}) {
  const keypad = React.useContext(KeypadContext);
  const mounted = React.useRef(false);
  const attach = React.useCallback(instance => {
    renderer = instance;
    if (!instance || mounted.current || generation !== revision) return;
    mounted.current = true;
    // Keep the official migration/legacy-answer conversion and numeric rules.
    const state = current.answerState;
    let input = state?.userInput;
    if (!input && state?.question) input = perseus.deriveUserInputFromSerializedState(state.question, current.item.question.widgets);
    if (input) {
      input = localizeNumericResponses(localizeAssets(input, current.assetBaseURL), current.item.question.widgets, current.locale);
      for (const id of instance.getWidgetIds()) if (input[id] !== undefined) instance.questionRenderer.props.handleUserInput(id, input[id], false);
    }
    setTimeout(() => {
      if (generation !== revision || !renderer) return;
      post('loaded', {itemId: current.itemId, hintsVisible, totalHints: current.item.hints.length});
      emitState(); loadResolve?.({itemId: current.itemId, hintsVisible}); loadResolve = null; loadReject = null;
    }, 40);
  }, [generation]);
  return <>
    <perseus.ServerItemRenderer ref={attach} key={generation} item={current.item} hintsVisible={hintsVisible}
      problemNum={1} reviewMode={false} showSolutions="none" dependencies={dependencies} keypadElement={keypad.keypadElement}
      apiOptions={{isArticle: false, isMobile: true, customKeypad: true, readOnly: false,
        interactionCallback: interaction, trackInteraction: interaction, onFocusChange: interaction,
        onInputError: message => report(Error(String(message)))}} />
    <MobileKeypad onElementMounted={keypad.setKeypadElement} onAnalyticsEvent={noOpAnalyticsEvent} />
  </>;
}
function render() {
  root ||= createRoot(document.getElementById('exercise'));
  root.render(<ErrorBoundary key={revision}><RenderStateRoot><StatefulKeypadContextProvider>
    <perseus.Dependencies.DependenciesContext.Provider value={dependencies}>
      <MathInputI18nContextProvider locale={current.locale} strings={strings}>
        <perseus.PerseusI18nContextProvider locale={current.locale} strings={strings}>
          <Contents generation={revision} />
        </perseus.PerseusI18nContextProvider>
      </MathInputI18nContextProvider>
    </perseus.Dependencies.DependenciesContext.Provider>
  </StatefulKeypadContextProvider></RenderStateRoot></ErrorBoundary>);
}
function assertSupported(value) {
  if (!value || typeof value !== 'object') return;
  if (value.widgets && typeof value.widgets === 'object') {
    for (const widget of Object.values(value.widgets)) {
      const registered = perseus.Widgets.getWidgetExport(widget.type);
      if (!registered || registered.name === 'deprecated-standin' || widget.type === 'video' || widget.type === 'iframe') {
        throw Error(`Unsupported offline exercise widget: ${widget.type}. This question cannot be graded by this build.`);
      }
    }
  }
  for (const child of Object.values(value)) if (child && typeof child === 'object') assertSupported(child);
}
window.NomadPerseus = {
  async loadItem(configuration) {
    emitState();
    loadReject?.(Error('A different question was opened.')); loadResolve = null; loadReject = null;
    root?.unmount(); root = null;
    renderer = null; current = null; revision++; clearTimeout(stateTimer);
    failed = false;
    document.getElementById('error').textContent = '';
    try {
      if (!configuration || typeof configuration.itemId !== 'string' || configuration.itemId.length > 500) throw Error('Invalid assessment item identifier.');
      if (new TextEncoder().encode(JSON.stringify(configuration.item)).byteLength > 8 * 1024 * 1024) throw Error('This assessment item exceeds the 8 MB renderer limit.');
      const base = new URL(configuration.assetBaseURL || 'nomad-perseus://local/package/');
      if (base.protocol !== 'nomad-perseus:' || base.host !== 'local' || !base.pathname.startsWith('/package/')) throw Error('Exercise assets must be inside the local package.');
      if (!base.pathname.endsWith('/')) base.pathname += '/';
      const parsed = parseAndMigratePerseusItem(configuration.item);
      if (isFailure(parsed)) throw Error('Perseus could not migrate this assessment item: ' + JSON.stringify(parsed.detail).slice(0, 500));
      assertSupported(parsed.value);
      current = {...configuration, item: localizeAssets(parsed.value, base.href), assetBaseURL: base.href, locale: configuration.locale || 'en'};
      const requestedHints = configuration.hintsVisible ?? configuration.answerState?.hintsVisible ?? 0;
      hintsVisible = Math.max(0, Math.min(current.item.hints.length, Number.isInteger(requestedHints) ? requestedHints : 0));
      return await new Promise((resolve, reject) => { loadResolve = resolve; loadReject = reject; render(); });
    } catch (error) { report(error); throw error; }
  },
  checkAnswer() {
    if (failed) throw Error('This question has a rendering or asset error and cannot be graded.');
    if (!renderer || !current) throw Error('Wait for the question to finish loading.');
    try {
      const state = answerState();
      const score = scoreItem(restoreAssets(current.item.question), state.userInput, current.locale);
      const result = {itemId: current.itemId, score, answerState: state, hintsVisible};
      post('result', result); return result;
    } catch (error) { report(error); throw error; }
  },
  showHint() {
    if (!current || !renderer) return;
    hintsVisible = Math.min(hintsVisible + 1, current.item.hints.length); render(); emitState();
  },
  getState: answerState,
  flush() { emitState(); return answerState(); },
  get widgetTypes() { return perseus.Widgets.getAllWidgetTypes(); },
};
document.addEventListener('click', event => { if (event.target.closest('a[href]')) event.preventDefault(); });
document.addEventListener('visibilitychange', () => { if (document.visibilityState !== 'visible') emitState(); });
window.addEventListener('pagehide', emitState);
document.addEventListener('error', event => {
  if (event.target instanceof HTMLImageElement) report(Error('A required exercise image is missing or cannot be loaded offline.'));
}, true);
window.addEventListener('error', event => { if (event.message) report(Error(event.message)); });
window.addEventListener('unhandledrejection', event => report(event.reason));
post('ready');

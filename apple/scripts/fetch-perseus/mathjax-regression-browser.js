import {MathJaxRenderer, SpeechRuleEngine} from './mathjax-adapter/index.js';
import './mathjax-adapter/style.css';

async function run() {
  const checks=[];
  function check(value,name) { if(!value) throw Error(name); checks.push(name); window.webkit.messageHandlers.mathTest.postMessage({progress:name}); }
  const renderer=new MathJaxRenderer({locale:'en'});
  function expression(tex) {
    const result=renderer.render(tex);
    document.body.appendChild(result.domElement);
    renderer.updateStyles();
    return result;
  }
  const fraction=expression('\\frac{1}{2}+\\sqrt{x^2+1}');
  check(fraction.domElement.querySelector('mjx-mfrac') && fraction.domElement.querySelector('mjx-msqrt'),'fraction and root CHTML');
  check(fraction.domElement.querySelector('mjx-assistive-mml math'),'accessible MathML');
  check(expression('\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}').domElement.querySelector('mjx-mtable'),'matrix');
  check(expression('\\ce{H2O + CO2}').domElement.querySelector('mjx-msub'),'chemistry');
  const colored=expression('\\blue{x}+\\cancel{y}').domElement;
  check(colored.querySelector('[style*="color"]') && colored.querySelector('mjx-ustrike'),'color and cancellation');
  const arabic=expression('\\text{مرحبا بالعالم} + x');
  check(arabic.domElement.querySelector('mjx-mtext').textContent.includes('مرحبا'),'Arabic text preserved');
  await document.fonts.ready;
  check(arabic.domElement.getBoundingClientRect().width>20,'Unicode layout has measurable width');
  const numerator=fraction.domElement.querySelector('mjx-num').getBoundingClientRect();
  const denominator=fraction.domElement.querySelector('mjx-den').getBoundingClientRect();
  const fractionLine=fraction.domElement.querySelector('mjx-line').getBoundingClientRect();
  check(numerator.width>0 && denominator.width>0 && numerator.y<denominator.y && fractionLine.width>0,'fraction numerator, denominator and rule geometry');
  check(document.querySelectorAll('style[data-nomad-mathjax]').length===1,'stylesheet replacement is bounded');
  check([...document.querySelectorAll('style')].some(style=>style.textContent.includes('nomad-perseus://local/renderer/mathjax/fonts')),'local font URLs');
  const label=await fraction.addLabel();
  check(label.length>3 && fraction.domElement.getAttribute('aria-label')===label,'spoken math label');
  const english=await SpeechRuleEngine.setup('en');
  check(english.texToSpeech('x^2').length>3,'keypad TeX to speech');
  const fallback=await SpeechRuleEngine.setup('ar-AE');
  check(fallback.texToSpeech('x^2')===english.texToSpeech('x^2'),'unsupported speech locale falls back locally to English');
  expression('\\newcommand{\\nomadtest}{7}\\nomadtest');
  let isolated=false;try{expression('\\nomadtest')}catch{isolated=true}
  check(isolated,'macros do not leak between expressions');
  for(const [tex,name] of [['\\unknownNomadCommand{x}','unknown command'],['\\frac{1}{','malformed TeX'],['x'.repeat(16_385),'bounded TeX'],['\\href{https://example.com}{x}','external link macro']]) {
    let rejected=false;try{expression(tex)}catch{rejected=true}
    check(rejected,name+' rejection');
  }
  let remoteFontRejected=false;try{new MathJaxRenderer({fontURL:'https://example.com/fonts'})}catch{remoteFontRejected=true}
  check(remoteFontRejected,'external fonts rejected');
  check(!document.querySelector('a[href^="http"]'),'no external links emitted');
  let blocked=false;try{await fetch('https://example.com/mathjax-regression')}catch{blocked=true}
  check(blocked,'network blocked');
  window.webkit.messageHandlers.mathTest.postMessage({passed:checks.length,checks});
}
run().catch(error=>window.webkit.messageHandlers.mathTest.postMessage({error:String(error.message||error), stack:String(error.stack||error)}));

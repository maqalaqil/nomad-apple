import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import crypto from 'node:crypto';
import {copyPackageNotices} from './package-notices.mjs';
const root=path.dirname(fileURLToPath(import.meta.url));
const output=path.resolve(root,'../../Resources/WebTools/Perseus');
const pins=JSON.parse(await fs.readFile(path.join(output,'release.json'),'utf8'));
const aliases={
  'kolibri-common/utils/localeNumbers':path.join(root,'upstream/localeNumbers.js'),
  'kolibri-common/utils/numeralNormalization':path.join(root,'upstream/numeralNormalization.js'),
  '@khanacademy/mathjax-renderer/src/css/mathjax.css':path.join(root,'mathjax-adapter/style.css'),
  '@khanacademy/mathjax-renderer/src/css/safari-hacks.css':path.join(root,'mathjax-adapter/style.css'),
  '@khanacademy/mathjax-renderer/src/css/selectable.css':path.join(root,'mathjax-adapter/style.css'),
};
const plugin={name:'kolibri-offline-adapter',setup(build){
  build.onResolve({filter:/^(kolibri\/utils\/i18n|kolibri-logging|kolibri\/urls)$/},args=>({path:args.path,namespace:'kolibri-shim'}));
  build.onLoad({filter:/.*/,namespace:'kolibri-shim'},args=>({contents:args.path==='kolibri-logging'?`export {logging as default} from ${JSON.stringify(path.join(root,'shims.js'))}`:args.path==='kolibri/urls'?`export {urls as default} from ${JSON.stringify(path.join(root,'shims.js'))}`:`export {createTranslator} from ${JSON.stringify(path.join(root,'shims.js'))}`,resolveDir:root,loader:'js'}));
  build.onLoad({filter:/translationUtils\.js$/},async args=>({contents:(await fs.readFile(args.path,'utf8')).replace('module.exports = {','export {'),loader:'js',resolveDir:path.dirname(args.path)}));
  build.onLoad({filter:/\.css$/},async args=>{
    let contents=(await fs.readFile(args.path,'utf8')).replaceAll('https://cdn.kastatic.org/fonts/mathjax/MathJax_Main-Regular.woff',path.join(root,'static/MathJax_Main-Regular.woff'));
    // The pinned math-input CSS modules need greater specificity than Wonder
    // Blocks' later-injected !important flex defaults, or keypad grids collapse.
    if(args.path.includes('/@khanacademy/math-input/dist/')) contents=contents.replace(/\.perseus_([\w-]+)/g,'#exercise .perseus_$1');
    return {contents,loader:'css',resolveDir:path.dirname(args.path)};
  });
  // A legacy built-in protractor bypasses dependency injection; localize its
  // fixed asset reference while leaving upstream scoring/rendering unchanged.
  build.onLoad({filter:/perseus\/dist\/(?:es\/)?index\.js$/},async args=>({contents:(await fs.readFile(args.path,'utf8')).replaceAll('https://ka-perseus-graphie.s3.amazonaws.com/e9d032f2ab8b95979f674fbfa67056442ba1ff6a.png','nomad-perseus://local/renderer/static/protractor-legacy.png'),loader:'js',resolveDir:path.dirname(args.path)}));
}};
await fs.mkdir(output,{recursive:true});
for (const [group, directory] of [['static_assets','static'],['integration_sources','upstream'],['source_archives','third-party']]) {
  for(const asset of pins[group]){const bytes=await fs.readFile(path.join(root,directory,asset.file));if(crypto.createHash('sha256').update(bytes).digest('hex')!==asset.sha256)throw Error('Pinned source checksum mismatch: '+asset.file);}
}
// Remove only generated output, after validating every source. Keep tracked pins/docs.
for (const entry of await fs.readdir(output)) if (!['.gitignore','README.md','release.json'].includes(entry)) await fs.rm(path.join(output,entry),{recursive:true,force:true});
const rendererPackage=JSON.parse(await fs.readFile(path.join(root,'node_modules/@khanacademy/mathjax-renderer/package.json'),'utf8'));
if(rendererPackage.name!=='@nomad-apple/mathjax-adapter' || rendererPackage.license!=='Apache-2.0') throw Error('Refusing to bundle the unlicensed upstream mathjax-renderer package. Restore the local adapter with npm ci.');
const result=await build({entryPoints:[path.join(root,'main.jsx')],bundle:true,minify:true,format:'iife',platform:'browser',target:['safari18'],outfile:path.join(output,'main.js'),legalComments:'linked',metafile:true,alias:aliases,plugins:[plugin],define:{'process.env.NODE_ENV':'"production"','process.env':'{}','__filename':'"NOMAD-Perseus"'},loader:{'.woff':'file','.woff2':'file','.ttf':'file','.eot':'file','.svg':'file','.png':'file'},assetNames:'assets/[name]-[hash]'});
const inputs=Object.keys(result.metafile.inputs).sort();
if(inputs.some(name=>name.includes('node_modules/@khanacademy/mathjax-renderer/')) || !inputs.some(name=>name.endsWith('mathjax-adapter/index.js'))) throw Error('Unexpected MathJax renderer source in bundle.');
await fs.writeFile(path.join(output,'bundle-inputs.json'),JSON.stringify(inputs,null,2)+'\n');
await fs.cp(path.join(root,'static'),path.join(output,'static'),{recursive:true});
await fs.cp(path.join(root,'node_modules/mathjax-full/es5/output/chtml/fonts/woff-v2'),path.join(output,'mathjax/fonts'),{recursive:true});
await fs.cp(path.join(root,'node_modules/speech-rule-engine/lib/mathmaps'),path.join(output,'speech'),{recursive:true});
await fs.mkdir(path.join(output,'licenses'),{recursive:true});
await fs.copyFile(path.join(root,'upstream/LICENSE'),path.join(output,'licenses/Kolibri-MIT.txt'));
await fs.cp(path.join(root,'upstream'),path.join(output,'licenses/Kolibri-integration-source'),{recursive:true});
await fs.cp(path.join(root,'third-party'),path.join(output,'licenses/MathQuill'),{recursive:true});
await copyPackageNotices(path.join(root,'node_modules'),path.join(output,'licenses/npm'),[path.join(root,'mathjax-adapter')]);
await fs.cp(path.join(root,'mathjax-adapter'),path.join(output,'licenses/NOMAD-math-adapter-source'),{recursive:true});
const csp="default-src 'self' nomad-perseus: data: blob:; script-src 'self' nomad-perseus: 'unsafe-eval'; style-src 'self' nomad-perseus: 'unsafe-inline'; font-src 'self' nomad-perseus: data:; img-src 'self' nomad-perseus: data: blob:; connect-src 'self' nomad-perseus: data: blob:; media-src 'self' nomad-perseus: data: blob:; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'";
await fs.writeFile(path.join(output,'index.html'),`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="${csp}"><title>Offline Exercise</title><link rel="stylesheet" href="main.css"></head><body><div id="error" role="alert"></div><div id="exercise"></div><script src="main.js"></script></body></html>`);
console.log('Built complete pinned Perseus renderer.');

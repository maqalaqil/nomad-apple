import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=path.dirname(fileURLToPath(import.meta.url));
const resources=path.resolve(root,'../../Resources/WebTools/Perseus');
const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'nomad-mathjax-regression-'));
function command(program,args) {
  const result=spawnSync(program,args,{stdio:'inherit',timeout:90_000});
  if(result.error || result.status!==0) throw result.error||Error(`${program} exited ${result.status}`);
}
try {
  await build({entryPoints:[path.join(root,'mathjax-regression-browser.js')],bundle:true,platform:'browser',format:'iife',outfile:path.join(temporary,'main.js'),legalComments:'linked'});
  await fs.cp(path.join(resources,'mathjax'),path.join(temporary,'mathjax'),{recursive:true});
  await fs.cp(path.join(resources,'speech'),path.join(temporary,'speech'),{recursive:true});
  await fs.writeFile(path.join(temporary,'index.html'),'<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="main.css"></head><body><script src="main.js"></script></body></html>');
  const binary=path.join(temporary,'runner');
  command('xcrun',['swiftc','-parse-as-library','-swift-version','5','-module-cache-path',path.join(os.tmpdir(),'nomad-webkit-module-cache'),path.join(root,'mathjax-regression.swift'),'-o',binary]);
  command(binary,[temporary]);
} finally { await fs.rm(temporary,{recursive:true,force:true}); }

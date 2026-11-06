import fs from 'node:fs/promises';
import path from 'node:path';

// Keep original package metadata and every available license/notice file. The
// inventory includes build-time packages too, so it is a conservative superset.
export async function copyPackageNotices(modules, output, localPackages = []) {
  const inventory = [];
  const visited = new Set();
  async function packageDirectories(directory) {
    let entries;
    try { entries = await fs.readdir(directory,{withFileTypes:true}); } catch { return; }
    for(const entry of entries.sort((a,b)=>a.name.localeCompare(b.name))) {
      if(!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const location = path.join(directory,entry.name);
      if(entry.name.startsWith('@')) await packageDirectories(location);
      else await packageNotice(location);
    }
  }
  async function packageNotice(directory) {
    const metadata = JSON.parse(await fs.readFile(path.join(directory,'package.json'),'utf8'));
    const key = metadata.name + '@' + metadata.version;
    if(!visited.has(key)) {
      visited.add(key);
      const destination = path.join(output,key.replaceAll('/','__'));
      await fs.mkdir(destination,{recursive:true});
      await fs.copyFile(path.join(directory,'package.json'),path.join(destination,'package.json'));
      const notices = [];
      async function walk(relative='') {
        for(const entry of (await fs.readdir(path.join(directory,relative),{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))) {
          if(entry.name==='node_modules' || entry.name.startsWith('.')) continue;
          const file = path.join(relative,entry.name);
          if(entry.isDirectory()) await walk(file);
          else if(entry.isFile() && /^(licen[cs]e|notice|copying|copyright|ofl)([._-]|$)/i.test(entry.name)) {
            await fs.mkdir(path.dirname(path.join(destination,file)),{recursive:true});
            await fs.copyFile(path.join(directory,file),path.join(destination,file));
            notices.push(file);
          }
        }
      }
      await walk();
      inventory.push({name:metadata.name,version:metadata.version,declaredLicense:metadata.license??null,notices,repository:metadata.repository??null});
    }
    await packageDirectories(path.join(directory,'node_modules'));
  }
  await packageDirectories(modules);
  // npm local-directory dependencies are symlinks. Traverse only the explicit
  // repository-owned paths supplied by the builder, not arbitrary link targets.
  for (const directory of localPackages) await packageNotice(directory);
  await fs.writeFile(path.join(output,'inventory.json'),JSON.stringify(inventory,null,2)+'\n');
  const unresolved=inventory.filter(item=>!item.declaredLicense && !item.notices.length);
  await fs.writeFile(path.join(output,'UNRESOLVED-NOTICES.txt'),
    'These published npm packages contain no license field or notice file. No license is inferred. Review upstream permissions before redistribution.\n'+unresolved.map(item=>`${item.name}@${item.version}`).join('\n')+'\n');
}

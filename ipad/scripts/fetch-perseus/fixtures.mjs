// Synthetic tests plus Kolibri's original public sorter fixture; no user data.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import * as core from '@khanacademy/perseus-core';

const source=path.dirname(fileURLToPath(import.meta.url));
const output=path.resolve(process.argv[2] || '/tmp/nomad-perseus-fixtures');
await fs.mkdir(output,{recursive:true});
await fs.copyFile(path.join(source,'upstream/sorter-item.json'),path.join(output,'sorter.json'));
const graph='web+graphie:${☣ LOCALPATH}/graph';
const item=core.generateTestPerseusItem({
  question:{content:`Compute $6 \\times 7$.\n\n[[☃ numeric-input 1]]\n\n![Local graph](${graph})`,
    images:{[graph]:{width:240,height:160}},
    widgets:{'numeric-input 1':core.generateNumericInputWidget({options:core.generateNumericInputOptions({
      answers:[core.generateNumericInputAnswer({value:42,status:'correct',message:'',simplify:'required'})],
    })})}},
  hints:[{content:'Six groups of seven equal $42$.',images:{},widgets:{}}],
});
await fs.writeFile(path.join(output,'numeric.json'),JSON.stringify(item,null,2)+'\n');
await fs.writeFile(path.join(output,'graph.svg'),'<svg xmlns="http://www.w3.org/2000/svg" width="240" height="160"><path d="M10 140L230 20" stroke="green" stroke-width="4"/></svg>');
await fs.writeFile(path.join(output,'graph-data.json'),JSON.stringify({range:[[0,10],[0,10]],labels:[{coordinates:[5,5],content:'x=42',alignment:'above',typesetAsMath:true}]}));
console.log(`Wrote synthetic test fixtures to ${output}`);

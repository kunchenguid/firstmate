// Progress snapshots only; durable notification receipts retain their own owner.
import fs from 'node:fs';
import path from 'node:path';
import {performance} from 'node:perf_hooks';

const sleeper=new Int32Array(new SharedArrayBuffer(4));

export function saveHostEvidence(runtime,evidence){
 const file=path.join(runtime,'host.json'),temporary=file+'.tmp';
 fs.writeFileSync(temporary,JSON.stringify(evidence,null,2));
 const deadline=performance.now()+250;
 for(;;){
  try{fs.renameSync(temporary,file);return;}
  catch(error){
   const remaining=deadline-performance.now();
   // Windows can refuse replacement while an ordinary reader has the old file open.
   // Keep the complete old snapshot visible; persistent errors still stop the host.
   if(process.platform!=='win32'||error.code!=='EPERM'||remaining<=0)throw error;
   Atomics.wait(sleeper,0,0,Math.min(5,remaining));
  }
 }
}

#!/usr/bin/env node
import {parse} from './parser.mjs';
let input = Buffer.alloc(0), finished = false;
const fail = () => { if (!finished) { finished=true; process.stderr.write('Reply parsing failed.\n'); process.exitCode=1; } };
process.on('uncaughtException',fail);
process.on('unhandledRejection',fail);
process.stdin.on('data', chunk => {
  if (finished) return;
  input = Buffer.concat([input, chunk]);
  if (input.length > 3_000_000) { fail(); process.stdin.destroy(); return; }
  const newline=input.indexOf(10);
  if (newline < 0) return;
  if (newline !== input.length-1) { fail(); process.stdin.destroy(); return; }
  try {
    const text=input.subarray(0,newline).toString('utf8');
    if (!Buffer.from(text,'utf8').equals(input.subarray(0,newline))) throw new Error('invalid frame');
    const result=parse(JSON.parse(text));
    finished=true;
    process.stdout.write(JSON.stringify(result)+'\n',()=>process.exit(0));
  } catch { fail(); process.stdin.destroy(); }
});
process.stdin.on('end',()=>{if(!finished) fail();});
setTimeout(()=>{fail();process.exit(1);},3000).unref();

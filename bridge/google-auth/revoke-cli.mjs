#!/usr/bin/env node
import {hardenEnvironment} from './token.mjs';
hardenEnvironment();
const fail = () => {process.stderr.write('Google grant revocation unavailable.\n'); process.exit(1);};
process.on('uncaughtException', fail);
process.on('unhandledRejection', fail);
const deadline = setTimeout(fail, 12000);
try {
  if (process.argv.length !== 2) throw new Error();
  let frame = Buffer.alloc(0);
  for await (const chunk of process.stdin) {
    if (frame.length + chunk.length > 131072) throw new Error();
    frame = Buffer.concat([frame, chunk]);
    if (frame.includes(10)) break;
  }
  if (!frame.length || frame[frame.length - 1] !== 10 || frame.subarray(0, -1).includes(10)) throw new Error();
  const value = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(frame));
  const {revokeRefreshToken} = await import('./revoke.mjs');
  process.stdout.write(JSON.stringify(await revokeRefreshToken(value)) + '\n');
  clearTimeout(deadline);
  process.stdin.destroy();
} catch {fail();}

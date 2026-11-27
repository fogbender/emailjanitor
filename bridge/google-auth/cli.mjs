#!/usr/bin/env node
import {fetchToken, readConfiguration, writeToken, hardenEnvironment} from './token.mjs';

// The Nix launcher clears NODE_OPTIONS before Node starts. Clear remaining SDK
// debug/ambient credential settings before dynamically loading provider code.
hardenEnvironment();
const fail = () => {process.stderr.write('Google service token refresh failed.\n'); process.exit(1);};
process.on('uncaughtException', fail);
process.on('unhandledRejection', fail);
const deadline = setTimeout(fail, 45000);
try {
  const [configFlag, configPath, outputFlag, outputPath, ...rest] = process.argv.slice(2);
  if (configFlag !== '--config' || outputFlag !== '--output' || rest.length || !configPath || !outputPath) throw new Error();
  const config = await readConfiguration(configPath);
  await writeToken(outputPath, await fetchToken(config));
  process.stdout.write('Google service token refreshed.\n');
  clearTimeout(deadline);
} catch {fail();}

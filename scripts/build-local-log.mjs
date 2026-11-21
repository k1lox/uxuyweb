import {build} from 'vite';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
await build({root, configFile:false, build:{lib:{entry:'frontend/local-log/localExecutionLog.ts',formats:['es'],fileName:()=> 'execution-history.js'}, outDir:'frontend/web/web', emptyOutDir:false}});

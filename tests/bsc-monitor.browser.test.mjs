import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';

test('the retired monitor entry and files are absent from the built site', async t => {
  const server = spawn(process.execPath, ['scripts/serve.mjs'], {
    cwd: fileURLToPath(new URL('../', import.meta.url)),
    env: {...process.env, PORT: '0', UXUY_PROXY_TARGET: 'http://127.0.0.1:1'},
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  t.after(() => server.kill());
  const [ready] = await once(server.stdout, 'data');
  const base = String(ready).match(/http:\/\/127\.0\.0\.1:\d+/)[0];
  assert.equal((await fetch(base)).status, 200);
  for (const path of ['/monitor', '/monitor/', '/monitor/index.html', '/monitor/assets/index-ClsQXkZc.js']) {
    assert.equal((await fetch(base + path, {redirect: 'manual'})).status, 404, path);
  }
});

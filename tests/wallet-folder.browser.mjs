import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {mkdir} from 'node:fs/promises';
import {test} from 'node:test';
import {chromium} from 'playwright';

async function capture(page, view) {
  const shots = process.env.UXUY_BACKUP_SHOTS;
  if (!shots) return;
  await mkdir(shots, {recursive: true});
  await page.screenshot({path: path.join(shots, view + '.png')});
}

// An isolated browser profile acts as the test folder. Only the OS picker is
// substituted; the directory handles, writable streams and IndexedDB are real.
async function openWorkspace(t) {
  let base = process.env.UXUY_TEST_URL;
  if (base) {
    base = new URL(base).origin;
  } else {
    const server = spawn(process.execPath, [fileURLToPath(new URL('../scripts/serve.mjs', import.meta.url))], {
      env: {...process.env, PORT: '0', UXUY_PROXY_TARGET: 'http://127.0.0.1:1'},
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    t.after(() => server.kill());
    const [ready] = await once(server.stdout, 'data');
    base = String(ready).match(/http:\/\/127\.0\.0\.1:\d+/)[0];
  }
  const browser = await chromium.launch({channel: 'chrome', headless: true});
  t.after(() => browser.close());
  const context = await browser.newContext({serviceWorkers: 'block', viewport: {width: 1280, height: 720}, locale: 'zh-CN'});
  await context.addInitScript(() => {
    window.showDirectoryPicker = async () => {
      const root = await navigator.storage.getDirectory();
      return root.getDirectoryHandle('UAgent-Test', {create: true});
    };
  });
  const page = await context.newPage();
  page.setDefaultTimeout(10000);
  const errors = [], disclosures = [], iconFonts = [];
  page.on('response', response => {
    const pathname = new URL(response.url()).pathname;
    if (pathname.includes('/fonts/MaterialIcons-')) iconFonts.push([pathname, response.status()]);
  });
  const key = '0x' + '7'.padStart(64, '0');
  page.on('pageerror', (e) => errors.push(e.name));
  page.on('dialog', (dialog) => dialog.accept());
  await context.route('**/*', async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    if (req.url().includes(key.slice(2)) || req.postData()?.includes(key.slice(2))) disclosures.push(url.pathname);
    if (url.origin !== base) return route.abort();
    if (!url.pathname.startsWith('/api/')) return ['GET', 'HEAD'].includes(req.method()) ? route.continue() : route.abort();
    let response = {ok: true, payload: {data: [], tokens: []}};
    if (url.pathname === '/api/v1/config') response = {ok: true, chainId: 56, router: '0x00000000000000000000000000000000000c0de1', routeSource:'uxuy', routeEnabled:true, approvalSpender:'0x00000000000000000000000000000000000c0de2', maxPriceImpactPercent: 7, fastPreflightVersion: 1};
    if (url.pathname === '/api/v1/wallets/state') response = {ok: true, wallets: []};
    if (/\/transactions|\/bundles/.test(url.pathname)) throw Error('Unexpected transaction submission');
    return route.fulfill({json: response});
  });
  async function enableSemantics() {
    await page.waitForFunction(() => !document.querySelector('#loading'));
    const placeholder = page.locator('flt-semantics-placeholder');
    if (await placeholder.count()) await placeholder.evaluate(e => e.click());
  }
  await page.goto(base);
  await enableSemantics();
  return {page, enableSemantics, key, errors, disclosures, iconFonts};
}

test('the Web entry saves a previously entered wallet to the chosen folder and reconnects after reload', {timeout: 120000}, async (t) => {
  const {page, enableSemantics, key, errors, disclosures, iconFonts} = await openWorkspace(t);
  await capture(page, 'desktop');
  const button = (name) => page.getByRole('button', {name, exact: typeof name === 'string'}).first();
  await button('批量买卖').click();
  await button('新建组').click(); await button(/^普通组/).click();
  await button('输入私钥').click();
  await page.getByRole('textbox').last().click();
  const editor = page.locator('textarea:focus, input:focus');
  await editor.waitFor();
  await editor.fill(key);
  await button('仅暂存').click();
  await button('仅暂存').waitFor({state: 'hidden'});
  await button(/^组01\s+1 个钱包/).waitFor();
  await page.evaluate(() => {
    const original = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = async function(data) {
      if (typeof data === 'string' && data.includes('uagent-wallet-backup-v2')) {
        FileSystemWritableFileStream.prototype.write = original;
        await new Promise(resolve => { window.finishFixtureWrite = resolve; });
      }
      return original.call(this, data);
    };
  });
  await button(/连接本地文件夹/).click();
  await page.waitForFunction(() => typeof window.finishFixtureWrite === 'function');
  const connected = page.getByText('已连接 · UAgent-wallets', {exact: true}).first();
  await page.getByText('1 项待保存', {exact: true}).first().waitFor();
  assert.equal(await connected.isVisible(), false, 'pending writes must not report a successful backup');
  await page.evaluate(() => window.finishFixtureWrite());
  await connected.waitFor();
  const address = '0xd41c057fd1c78805aac12b0a94a405c0461a6fbb';
  async function verifySaved() {
    const valid = await page.evaluate(async ({address, key}) => {
      const root = await navigator.storage.getDirectory();
      const chosen = await root.getDirectoryHandle('UAgent-Test');
      const base = await chosen.getDirectoryHandle('UAgent-wallets');
      const names = [];
      for await (const entry of base.values()) names.push([entry.kind, entry.name]);
      if (names.length !== 1 || names[0][0] !== 'file' || names[0][1] !== 'wallets.json') return false;
      const file = await (await base.getFileHandle('wallets.json')).getFile();
      const archive = JSON.parse(await file.text());
      if (archive.format !== 'uagent-wallet-backup-v2' || archive.wallets.length !== 1) return false;
      const [wallet] = archive.wallets;
      return wallet.purpose === '批量交易组' && wallet.address === address &&
        wallet.privateKey === key && wallet.usages.length === 1 &&
        wallet.usages[0].category === 'trade-group' &&
        wallet.usages[0].scope === '组01' && wallet.usages[0].relatedAddress === null;
    }, {address, key});
    assert.equal(valid, true, 'the confirmed group wallet must match its file after reopening it');
  }
  await verifySaved();
  const inBrowserStorage = await page.evaluate(() => JSON.stringify([Object.entries(localStorage), Object.entries(sessionStorage)]));
  assert.ok(!inBrowserStorage.includes(key.slice(2)));
  await page.reload(); await enableSemantics();
  await connected.waitFor(); await verifySaved();
  await page.setViewportSize({width:390, height:844});
  await button('工具').click(); await connected.waitFor();
  await capture(page, 'mobile');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.ok(iconFonts.some(([p, status]) => status === 200 && /MaterialIcons-Regular-[0-9a-f]{16}\.otf$/.test(p)));
  assert.ok(iconFonts.every(([p]) => !p.endsWith('/MaterialIcons-Regular.otf')));
  assert.deepEqual(disclosures, []); assert.deepEqual(errors, []);
});

test('the idle backup indicator follows write permission changes without asking for access', {timeout: 120000}, async t => {
  const {page, errors} = await openWorkspace(t);
  await page.getByRole('button', {name: '生成私钥', exact: true}).click();
  await page.getByRole('button', {name: /连接本地文件夹/}).first().click();
  await page.mouse.move(1210, 690);
  const connected = page.getByText('已连接 · UAgent-wallets', {exact: true}).first();
  const reconnect = page.getByRole('button', {name: /重新连接文件夹/}).first();
  const permissionHint = page.getByText(/读写权限已失效/).first();
  await connected.waitFor();

  // Simulate a grant being revoked while the tab stays visible. Neither a new
  // wallet operation nor a lifecycle event should be needed to update the UI.
  await page.evaluate(() => {
    window.fixturePermission = 'prompt';
    window.promptAttempts = 0;
    const refusePrompt = async () => {
      window.promptAttempts++;
      throw new Error('unexpected interactive permission check');
    };
    window.showDirectoryPicker = refusePrompt;
    FileSystemHandle.prototype.requestPermission = refusePrompt;
    FileSystemHandle.prototype.queryPermission = async () => window.fixturePermission;
  });
  await reconnect.waitFor({timeout: 20000});
  await connected.waitFor({state: 'hidden'});
  await permissionHint.waitFor();
  await capture(page, 'desktop-permission-revoked');

  // A return to the tab should notice the restored grant before the next poll.
  await page.evaluate(() => {
    window.fixturePermission = 'granted';
    window.dispatchEvent(new Event('focus'));
  });
  await connected.waitFor({timeout: 4000});
  await reconnect.waitFor({state: 'hidden'});
  await page.evaluate(() => {
    window.fixturePermission = 'denied';
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await reconnect.waitFor({timeout: 4000});
  await connected.waitFor({state: 'hidden'});
  await page.setViewportSize({width: 390, height: 844});
  await page.getByRole('button', {name: '工具', exact: true}).click();
  await reconnect.waitFor();
  await permissionHint.waitFor();
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await capture(page, 'mobile-permission-revoked');
  assert.equal(await page.evaluate(() => window.promptAttempts), 0);
  assert.deepEqual(errors, []);
});

test('a failed backup stays pending with valid permission until a retry commits the wallet archive', {timeout: 120000}, async t => {
  const {page, errors} = await openWorkspace(t);
  const button = name => page.getByRole('button', {name, exact: true}).first();
  await button('生成私钥').click();
  await page.getByRole('button', {name: /连接本地文件夹/}).first().click();
  const connected = page.getByText('已连接 · UAgent-wallets', {exact: true}).first();
  await connected.waitFor();
  await page.evaluate(() => {
    window.fixtureDiskFull = true;
    const write = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = function(data) {
      if (window.fixtureDiskFull && typeof data === 'string' && data.includes('uagent-wallet-backup-v2')) {
        throw new DOMException('test volume is full', 'QuotaExceededError');
      }
      return write.call(this, data);
    };
  });
  await button('生成').click();
  const failure = page.getByText(/5 项待保存.*空间不足/).first();
  await failure.waitFor();
  await connected.waitFor({state: 'hidden'});
  await page.evaluate(() => { window.fixtureDiskFull = false; });
  await button('重试').click();
  await connected.waitFor();
  await failure.waitFor({state: 'hidden'});
  const savedCount = await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory();
    const chosen = await root.getDirectoryHandle('UAgent-Test');
    const base = await chosen.getDirectoryHandle('UAgent-wallets');
    const file = await (await base.getFileHandle('wallets.json')).getFile();
    const {format, wallets} = JSON.parse(await file.text());
    const addresses = new Set();
    if (format === 'uagent-wallet-backup-v2') {
      for (const wallet of wallets) {
        if (wallet.purpose === '工具生成钱包' && wallet.usages[0]?.category === 'tool-generated') {
          addresses.add(wallet.address);
        }
      }
    }
    return addresses.size;
  });
  assert.equal(savedCount, 5);
  assert.deepEqual(errors, []);
});

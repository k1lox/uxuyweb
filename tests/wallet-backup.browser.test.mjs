import {after, before, test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright';

// The picker returns an origin-private test directory in a disposable Chromium
// profile. Locks, streams, permission checks and IndexedDB are the browser's.
const source = await readFile(new URL('../frontend/web/web/wallet_backup.js', import.meta.url), 'utf8');
const url = 'http://127.0.0.1:3190/backup-fixture';
const address = '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf';
const record = {
  category: 'tool-generated', scope: '', address, relatedAddress: null,
  privateKey: '0x' + '1'.padStart(64, '0'),
};
const dev = {
  category: 'launch-dev', scope: '', relatedAddress: null,
  address: '0x2b5ad5c4795c026514f8317c7a215e218dccd6cf',
  privateKey: '0x' + '2'.padStart(64, '0'),
};
let browser;

before(async () => {
  browser = await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
});
after(async () => browser?.close());

async function fixture(t) {
  const context = await browser.newContext();
  t.after(() => context.close());
  const unexpected = [];
  t.after(() => assert.deepEqual(unexpected, []));
  await context.route('**/*', async route => {
    if (new URL(route.request().url()).pathname === '/execution-history.js') return route.fulfill({contentType:'text/javascript', body:await readFile(new URL('../frontend/web/web/execution-history.js',import.meta.url))});
    if (route.request().url() === url) {
      return route.fulfill({contentType: 'text/html', body: '<!doctype html><title>backup fixture</title>'});
    }
    unexpected.push(route.request().url());
    return route.abort();
  });
  await context.addInitScript(() => {
    window.fixtureFolder = 'test-selection';
    window.showDirectoryPicker = async () => {
      if (window.cancelPicker) throw new DOMException('cancel', 'AbortError');
      const root = await navigator.storage.getDirectory();
      return root.getDirectoryHandle(window.fixtureFolder, {create: true});
    };
  });
  await context.addInitScript({content: source});
  async function newPage() {
    const page = await context.newPage();
    await page.goto(url);
    return page;
  }
  return {page: await newPage(), newPage};
}

function call(page, method, records) {
  return page.evaluate(async ({method, records}) => {
    const api = window.uagentWalletBackup;
    return JSON.parse(await (records ? api[method](JSON.stringify(records)) : api[method]()));
  }, {method, records});
}

// Read only the aggregate in the synthetic OPFS directory selected by the test.
function readArchive(page, name = 'test-selection') {
  return page.evaluate(async name => {
    const root = await navigator.storage.getDirectory();
    try {
      const picked = await root.getDirectoryHandle(name);
      const base = await picked.getDirectoryHandle('UAgent-wallets');
      return await (await (await base.getFileHandle('wallets.json')).getFile()).text();
    } catch (error) {
      if (error.name === 'NotFoundError') return null;
      throw error;
    }
  }, name);
}

async function inspectTestFolder(page, name) {
  const text = await readArchive(page, name);
  if (!text) return [];
  const archive = JSON.parse(text);
  assert.equal(archive.format, 'uagent-wallet-backup-v2');
  return archive.wallets;
}

test('one JSON keeps each key and its original purpose across concurrent tabs, refresh and retries', async t => {
  const {page, newPage} = await fixture(t);
  assert.equal((await call(page, 'reconnect')).value, null);
  assert.ok((await call(page, 'save', [record])).error);
  assert.equal((await call(page, 'chooseDirectory')).value, 'test-selection');
  const second = await newPage();
  assert.equal((await call(second, 'reconnect')).value, null);
  assert.equal((await call(second, 'chooseDirectory')).value, 'test-selection');
  const buyer = {...record, category: 'linked-transit', scope: '组01', relatedAddress: dev.address};
  const relabeled = {...buyer, scope: '组02'};
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const replies = await Promise.all([
    call(page, 'save', [buyer, buyer, dev]),
    call(second, 'save', [record, relabeled]),
  ]);
  assert.ok(replies.every(reply => !reply.error));
  await page.reload();
  assert.equal((await call(page, 'reconnect')).value, 'test-selection');
  const original = await readArchive(page);
  assert.equal((await call(page, 'save', [dev, relabeled, record, buyer])).error, undefined);
  assert.equal(await readArchive(page), original);
  const restored = await inspectTestFolder(page);
  assert.equal(restored.length, 2);
  const wallet = restored.find(r => r.address === address);
  assert.equal(wallet.privateKey, record.privateKey);
  assert.equal(wallet.purpose, '工具生成钱包');
  assert.deepEqual(wallet.usages[0], {category: record.category, scope: '', relatedAddress: null});
  assert.deepEqual(wallet.usages.slice(1).map(u => u.scope).sort(), ['组01', '组02']);
  assert.ok(wallet.usages.slice(1).every(u => u.category === 'linked-transit' && u.relatedAddress === dev.address));
  assert.equal(restored.find(r => r.address === dev.address).purpose, '发币开发者');
  for (const {privateKey} of [record, dev]) assert.equal(original.split(privateKey).length - 1, 1);

  const layout = await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory();
    const picked = await root.getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const names = [];
    for await (const handle of base.values()) names.push([handle.kind, handle.name]);
    const db = await new Promise(resolve => {
      const req = indexedDB.open('uagent-wallet-directory-v1');
      req.onsuccess = () => resolve(req.result);
    });
    const handles = await new Promise(resolve => {
      const req = db.transaction('selection').objectStore('selection').getAll();
      req.onsuccess = () => resolve(req.result);
    });
    db.close();
    return {names, kinds: handles.map(h => h.kind), localStorage: localStorage.length};
  });
  assert.deepEqual(layout.names, [['file', 'wallets.json']]);
  assert.deepEqual(layout.kinds, ['directory']);
  assert.equal(layout.localStorage, 0);

  await page.evaluate(() => { window.cancelPicker = true; });
  assert.equal((await call(page, 'chooseDirectory')).value, null);
  assert.equal((await call(page, 'save', [record])).error, undefined);
  assert.equal(await readArchive(page), original);
  await page.evaluate(() => { window.cancelPicker = false; window.fixtureFolder = 'fresh-folder'; });
  assert.equal((await call(page, 'chooseDirectory')).value, 'fresh-folder');
  assert.equal((await inspectTestFolder(page, 'fresh-folder')).length, 0);
  const existingDevInNewRole = {...dev, category: 'trade-group', scope: '组03', originalCategory: 'launch-dev'};
  assert.equal((await call(page, 'save', [existingDevInNewRole])).error, undefined);
  const [freshWallet] = await inspectTestFolder(page, 'fresh-folder');
  assert.equal(freshWallet.address, dev.address);
  assert.equal(freshWallet.purpose, '发币开发者');
  assert.deepEqual(freshWallet.usages, [{category: 'trade-group', scope: '组03', relatedAddress: null}]);
  assert.equal(await readArchive(second), original);
});

test('an interrupted first write can be retried; an invalid batch cannot partly change an existing archive', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await page.evaluate(() => {
    const original = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = function () {
      FileSystemWritableFileStream.prototype.write = original;
      throw new DOMException('disk full', 'QuotaExceededError');
    };
  });
  assert.match((await call(page, 'save', [record])).error, /空间/);
  assert.equal((await inspectTestFolder(page)).length, 0);
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const before = await readArchive(page);
  const wrong = {...record, category: 'linked-seller', privateKey: dev.privateKey};
  assert.ok((await call(page, 'save', [dev, wrong])).error);
  assert.equal(await readArchive(page), before);
  await page.evaluate(() => { FileSystemHandle.prototype.queryPermission = async () => 'denied'; });
  const denied = await call(page, 'save', [record]);
  assert.match(denied.error, /授权/);
  assert.equal(denied.code, 'permission');
  assert.ok(await page.evaluate(() => !('readAll' in window.uagentWalletBackup)));
});

test('saving beside a legacy wallet does not open, change or import the legacy file', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  const original = JSON.stringify({format: 'uagent-wallet-backup-v1', ...record});
  await page.evaluate(async ({original, address}) => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const legacy = await base.getDirectoryHandle('工具生成钱包', {create: true});
    const file = await legacy.getFileHandle('wallet-' + address + '.json', {create: true});
    const out = await file.createWritable();
    await out.write(original); await out.close();
    window.fixtureLegacyRead = () => FileSystemFileHandle.prototype.getFile.call(file);
    const getFile = FileSystemFileHandle.prototype.getFile;
    window.legacyReadCount = 0;
    FileSystemFileHandle.prototype.getFile = function () {
      if (this.name === file.name) window.legacyReadCount++;
      return getFile.call(this);
    };
  }, {original, address});
  assert.equal((await call(page, 'save', [dev])).error, undefined);
  assert.deepEqual((await inspectTestFolder(page)).map(w => w.address), [dev.address]);
  assert.equal(await page.evaluate(() => window.legacyReadCount), 0);
  assert.equal(await page.evaluate(async () => (await window.fixtureLegacyRead()).text()), original);
});

test('live access checks detect revocation and missing folders without prompting or writing', async t => {
  const {page} = await fixture(t);
  assert.equal((await call(page, 'checkAccess')).value, false);
  assert.equal((await call(page, 'chooseDirectory')).value, 'test-selection');
  await page.evaluate(() => {
    window.permissionState = 'granted';
    window.unexpectedCalls = [];
    FileSystemHandle.prototype.queryPermission = async ({mode}) =>
      mode === 'readwrite' ? window.permissionState : 'granted';
    for (const [proto, method] of [
      [FileSystemHandle.prototype, 'requestPermission'],
      [FileSystemFileHandle.prototype, 'createWritable'],
      [window, 'showDirectoryPicker'],
    ]) {
      proto[method] = () => { window.unexpectedCalls.push(method); throw Error(method); };
    }
  });
  assert.deepEqual(await call(page, 'checkAccess'), {value: true});
  for (const state of ['prompt', 'denied']) {
    await page.evaluate(state => { window.permissionState = state; }, state);
    assert.deepEqual(await call(page, 'checkAccess'), {value: false});
  }
  await page.evaluate(async () => {
    window.permissionState = 'granted';
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    await picked.removeEntry('UAgent-wallets', {recursive: true});
  });
  assert.match((await call(page, 'checkAccess')).error, /移动或删除/);
  assert.deepEqual(await page.evaluate(() => window.unexpectedCalls), []);
});

test('connection and restoration require a verified write and preserve existing files on failure', async t => {
  const {page} = await fixture(t);
  await page.evaluate(async () => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection', {create: true});
    const base = await picked.getDirectoryHandle('UAgent-wallets', {create: true});
    const note = await base.getFileHandle('keep.txt', {create: true});
    const writer = await note.createWritable();
    await writer.write('untouched'); await writer.close();
    const collision = await base.getFileHandle('uagent-write-check-reserved.txt', {create: true});
    const existing = await collision.createWritable();
    await existing.write('user file'); await existing.close();
    const uuid = crypto.randomUUID.bind(crypto);
    window.forceCollision = true;
    crypto.randomUUID = () => window.forceCollision ? 'reserved' : uuid();
    window.failProbe = true;
    const write = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = function (data) {
      if (window.failProbe) throw new DOMException('private path', 'QuotaExceededError');
      return write.call(this, data);
    };
  });
  assert.match((await call(page, 'chooseDirectory')).error, /验证目录写入/);
  await page.evaluate(() => { window.forceCollision = false; });
  assert.match((await call(page, 'chooseDirectory')).error, /空间/);
  assert.deepEqual(await call(page, 'checkAccess'), {value: false});
  assert.ok((await call(page, 'save', [record])).error);
  await page.evaluate(() => { window.failProbe = false; });
  assert.deepEqual(await call(page, 'chooseDirectory'), {value: 'test-selection'});
  const contents = await page.evaluate(async () => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const files = [];
    for await (const entry of base.values()) files.push([entry.name, await (await entry.getFile()).text()]);
    return files;
  });
  assert.deepEqual(contents.sort(), [['keep.txt', 'untouched'], ['uagent-write-check-reserved.txt', 'user file']]);
  await page.evaluate(() => { window.fixtureFolder = 'bad-folder'; window.failProbe = true; });
  assert.match((await call(page, 'chooseDirectory')).error, /空间/);
  await page.evaluate(() => { window.failProbe = false; });
  assert.ok(!(await call(page, 'save', [record])).error);
  assert.equal((await inspectTestFolder(page, 'bad-folder')).length, 0);

  await page.reload();
  await page.evaluate(() => {
    FileSystemFileHandle.prototype.createWritable = () => { throw new DOMException('private path', 'NoModificationAllowedError'); };
  });
  assert.match((await call(page, 'reconnect')).error, /无法写入/);
  assert.deepEqual(await call(page, 'checkAccess'), {value: false});
  await page.evaluate(() => { FileSystemHandle.prototype.queryPermission = async () => 'prompt'; });
  assert.equal((await call(page, 'reconnect')).code, 'permission');
  await page.reload();
  assert.deepEqual(await call(page, 'reconnect'), {value: 'test-selection'});
});

test('a corrupted stream that closes successfully is detected and is never overwritten on retry', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await page.evaluate(() => {
    const write = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = function (content) {
      FileSystemWritableFileStream.prototype.write = write;
      return write.call(this, content.replace('uagent-wallet-backup', 'xagent-wallet-backup'));
    };
  });
  assert.ok((await call(page, 'save', [record])).error);
  const damaged = await readArchive(page);
  assert.equal(JSON.parse(damaged).format, 'xagent-wallet-backup-v2');
  assert.ok((await call(page, 'save', [record])).error);
  assert.equal(await readArchive(page), damaged);
});

function corruptNextReplacementCharacter(page) {
  return page.evaluate(() => {
    const write = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = function (content) {
      const data = new TextEncoder().encode(content);
      const index = data.findIndex((b, i) => b === 0xef && data[i + 1] === 0xbf && data[i + 2] === 0xbd);
      if (index < 0) throw new Error('fixture marker missing');
      data.set([0xf0, 0x90, 0x80], index);
      window.fixtureDecodedSame = new TextDecoder().decode(data) === content;
      FileSystemWritableFileStream.prototype.write = write;
      return write.call(this, data);
    };
  });
}

test('readback rejects invalid UTF-8 even if decoded text and size appear correct', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await corruptNextReplacementCharacter(page);
  const withUnicodeScope = {...record, category: 'trade-group', scope: '组�'};
  assert.ok((await call(page, 'save', [withUnicodeScope])).error);
  assert.equal(await page.evaluate(() => window.fixtureDecodedSame), true);
  assert.ok((await call(page, 'save', [withUnicodeScope])).error);
  const log = (await call(page, 'history')).value;
  assert.match(log, /未通过/);
  assert.ok(!log.includes(withUnicodeScope.privateKey) && !log.includes(withUnicodeScope.scope));
});

test('duplicate saves and malformed archives are never rewritten', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const before = await readArchive(page);
  await page.evaluate(async () => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const handle = await base.getFileHandle('wallets.json');
    const createWritable = FileSystemFileHandle.prototype.createWritable;
    window.replaceFixtureText = async content => {
      const stream = await createWritable.call(handle);
      await stream.write(content);
      await stream.close();
    };
    window.walletWrites = 0;
    FileSystemFileHandle.prototype.createWritable = function (options) {
      if (this.name === 'wallets.json') window.walletWrites++;
      return createWritable.call(this, options);
    };
  });
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const brokenDocuments = [
    '',
    '{',
    before.replace('uagent-wallet-backup-v2', 'unknown-format'),
    before.replace('"wallets":', '"wallets":[{"address":"earlier wallet"}],"wallets":'),
    before.replace('"address":', '"address":"invalid duplicate","address":'),
    before.replace('"wallets":', String.raw`"w\u0061llets":[],"wallets":`),
  ];
  for (const text of brokenDocuments) {
    assert.notEqual(text, before);
    await page.evaluate(text => window.replaceFixtureText(text), text);
    assert.ok((await call(page, 'save', [dev])).error);
    assert.equal(await readArchive(page), text);
  }
  assert.equal(await page.evaluate(() => window.walletWrites), 0);

  const extended = JSON.parse(before);
  extended.note = '用户手记 { "wallets": [] }';
  extended.wallets[0].memo = '我的备注';
  const extendedText = JSON.stringify(extended);
  await page.evaluate(text => window.replaceFixtureText(text), extendedText);
  const result = await call(page, 'save', [dev]);
  if (result.error) {
    assert.equal(await readArchive(page), extendedText);
  } else {
    const merged = JSON.parse(await readArchive(page));
    assert.equal(merged.note, extended.note);
    assert.deepEqual(merged.wallets[0], extended.wallets[0]);
    assert.equal(merged.wallets[1].address, dev.address);
  }
});

test('a full disk during append preserves every byte of the old aggregate until a successful retry', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const before = await readArchive(page);
  await page.evaluate(() => {
    const write = FileSystemWritableFileStream.prototype.write;
    FileSystemWritableFileStream.prototype.write = async function (content) {
      FileSystemWritableFileStream.prototype.write = write;
      await write.call(this, content.slice(0, 20));
      throw new DOMException('disk full', 'QuotaExceededError');
    };
  });
  assert.match((await call(page, 'save', [dev])).error, /空间/);
  assert.equal(await readArchive(page), before);
  assert.equal((await call(page, 'save', [dev])).error, undefined);
  assert.deepEqual((await inspectTestFolder(page)).map(w => w.address).sort(), [record.address, dev.address].sort());
});

test('a save detects an external edit made after merging and retries from the latest data', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const externalArchive = JSON.parse(await readArchive(page));
  externalArchive.wallets[0].usages.push({category: 'trade-group', scope: '另一个应用', relatedAddress: null});
  const externalText = JSON.stringify(externalArchive);
  await page.evaluate(externalText => {
    const open = FileSystemFileHandle.prototype.createWritable;
    FileSystemFileHandle.prototype.createWritable = async function (options) {
      if (this.name === 'wallets.json') {
        FileSystemFileHandle.prototype.createWritable = open;
        const editor = await open.call(this);
        await editor.write(externalText);
        await editor.close();
      }
      return open.call(this, options);
    };
  }, externalText);
  assert.ok((await call(page, 'save', [dev])).error);
  assert.equal(await readArchive(page), externalText);
  assert.equal((await call(page, 'save', [dev])).error, undefined);
  const wallets = await inspectTestFolder(page);
  assert.deepEqual(wallets[0], externalArchive.wallets[0]);
  assert.equal(wallets[1].address, dev.address);
});

test('readback rejects an archive replaced with an older valid copy immediately after close', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  assert.equal((await call(page, 'save', [record])).error, undefined);
  const before = await readArchive(page);
  await page.evaluate(async before => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const close = FileSystemWritableFileStream.prototype.close;
    FileSystemWritableFileStream.prototype.close = async function () {
      FileSystemWritableFileStream.prototype.close = close;
      await close.call(this);
      await base.removeEntry('wallets.json');
      const replacement = await base.getFileHandle('wallets.json', {create: true});
      const stream = await replacement.createWritable();
      await stream.write(before);
      await stream.close();
    };
  }, before);
  assert.ok((await call(page, 'save', [dev])).error);
  assert.equal(await readArchive(page), before);
  assert.equal((await call(page, 'save', [dev])).error, undefined);
});

test('a new session-only directory is used despite IndexedDB failure and its predecessor is never reconnected', async t => {
  const {page, newPage} = await fixture(t);
  assert.equal((await call(page, 'chooseDirectory')).value, 'test-selection');
  await page.evaluate(() => {
    window.fixtureFolder = 'session-only';
    IDBFactory.prototype.open = () => { throw new DOMException('blocked', 'SecurityError'); };
  });
  assert.equal((await call(page, 'chooseDirectory')).value, 'session-only');
  assert.ok(!(await call(page, 'save', [record])).error);
  assert.equal((await inspectTestFolder(page)).length, 0);
  assert.equal((await inspectTestFolder(page, 'session-only')).length, 1);
  await page.reload(); // IndexedDB is available again and still contains the old handle.
  assert.equal((await call(page, 'reconnect')).value, null);
  assert.ok((await call(page, 'save', [record])).error);
  assert.equal((await call(await newPage(), 'reconnect')).value, null);
});

test('removed directory entries are recreated on a new save or fail verification if removed during commit', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  assert.ok(!(await call(page, 'save', [record])).error);
  await page.evaluate(async () => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    await picked.removeEntry('UAgent-wallets', {recursive: true});
  });
  assert.ok(!(await call(page, 'save', [record])).error);
  assert.equal((await inspectTestFolder(page)).length, 1);
  await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory();
    const picked = await root.getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const original = FileSystemWritableFileStream.prototype.close;
    FileSystemWritableFileStream.prototype.close = async function () {
      FileSystemWritableFileStream.prototype.close = original;
      await original.call(this);
      await base.removeEntry('wallets.json');
    };
  });
  assert.ok((await call(page, 'save', [{...record, category: 'trade-group', scope: 'second'}])).error);
  await page.evaluate(async () => {
    await (await navigator.storage.getDirectory()).removeEntry('test-selection', {recursive: true});
  });
  assert.ok((await call(page, 'save', [record])).error);
});


function readLogFile(page, filename = 'logs.json') {
  return page.evaluate(async name => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle(window.fixtureFolder);
    const handle = await picked.getFileHandle(name);
    return (await handle.getFile()).text();
  }, filename);
}

test('execution history survives reload with exact file readback and redacted labelled credentials', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  const time = Date.UTC(2026, 9, 19, 10, 2, 3, 4);
  const saved = await page.evaluate(async time =>
    JSON.parse(await window.uagentWalletBackup.recordLog('模拟成交 / password=synthetic-only', 'info', time)),
  time);
  assert.equal(saved.error, undefined);
  await page.reload();
  assert.equal((await call(page, 'reconnect')).value, 'test-selection');
  const archive = JSON.parse(await readLogFile(page));
  assert.equal(archive.version, 1);
  assert.equal(archive.entries.length, 1);
  const [entry] = archive.entries;
  assert.ok(entry.id);
  assert.equal(entry.time, new Date(time).toISOString());
  assert.equal(entry.source, 'info');
  assert.match(entry.message, /模拟成交/);
  assert.doesNotMatch(entry.message, /synthetic-only/);
  const restored = (await call(page, 'history')).value;
  assert.match(restored, /模拟成交/);
  assert.doesNotMatch(restored, /synthetic-only/);
});

test('the JSON retains complete legacy text and every new event beyond the visible log limits', async t => {
  const {page} = await fixture(t);
  const old = '第一条旧记录\r\n' + 'legacy line\r\n'.repeat(23500) + '旧版最后一条';
  const count = 2045;
  const oversizedLength = 2 * 1024 * 1024 + 1;
  const ending = '最终回执';
  await page.evaluate(async ({old, count, oversizedLength, ending}) => {
    const root = await navigator.storage.getDirectory();
    const picked = await root.getDirectoryHandle(window.fixtureFolder, {create: true});
    const legacy = await picked.getFileHandle('logs.txt', {create: true});
    const stream = await legacy.createWritable();
    await stream.write(old);
    await stream.close();
    // Events may arrive before a user picks a directory or opens the log panel.
    await Promise.all(Array.from({length: count}, (_, i) =>
      window.uagentWalletBackup.recordLog('event ' + i + '\n' + '模拟记录'.repeat(34), 'fixture', i + 1)));
    await window.uagentWalletBackup.recordLog('x'.repeat(oversizedLength) + ending, 'info', count + 1);
  }, {old, count, oversizedLength, ending});
  assert.equal((await call(page, 'chooseDirectory')).value, 'test-selection');
  const archive = JSON.parse(await readLogFile(page));
  assert.ok(archive.legacyText === old);
  assert.equal(archive.entries.length, count + 1);
  assert.equal(new Set(archive.entries.map(entry => entry.id)).size, count + 1);
  for (const [i, entry] of archive.entries.slice(0, count).entries()) {
    assert.equal(entry.message, 'event ' + i + '\n' + '模拟记录'.repeat(34));
    assert.equal(entry.time, new Date(i + 1).toISOString());
  }
  const largeMessage = archive.entries.at(-1).message;
  assert.equal(largeMessage.length, oversizedLength + ending.length);
  assert.ok(largeMessage === 'x'.repeat(oversizedLength) + ending);
  assert.ok((await readLogFile(page, 'logs.txt')) === old);
  await page.reload();
  await call(page, 'reconnect');
  const history = (await call(page, 'history')).value;
  assert.ok(history.startsWith(old));
  assert.equal(history.split('第一条旧记录').length, 2);
  assert.equal(history.match(/event \d+\n/g).length, count);
  assert.ok(history.endsWith(largeMessage + '\n'));
  assert.deepEqual(JSON.parse(await readLogFile(page)).entries.map(e => e.id), archive.entries.map(e => e.id));
});

test('two tabs append overlapping bursts exactly once and preserve each tab’s order', async t => {
  const {page, newPage} = await fixture(t);
  const second = await newPage();
  await Promise.all([call(page, 'chooseDirectory'), call(second, 'chooseDirectory')]);
  const count = 18;
  await Promise.all([page, second].map((tab, index) => tab.evaluate(async ({tag, count}) => {
    const replies = await Promise.all(Array.from({length: count}, (_, i) =>
      window.uagentWalletBackup.recordLog(tag + i, tag, i + 1)));
    if (replies.some(reply => JSON.parse(reply).error)) throw new Error('log write failed');
  }, {tag: 'tab' + index + '/', count})));
  const {entries} = JSON.parse(await readLogFile(page));
  assert.equal(entries.length, count * 2);
  assert.equal(new Set(entries.map(entry => entry.id)).size, count * 2);
  for (const tag of ['tab0/', 'tab1/']) {
    assert.deepEqual(entries.filter(entry => entry.source === tag).map(entry => entry.message),
      Array.from({length: count}, (_, i) => tag + i));
  }
});

test('a log commit replaced immediately after close fails readback and retries the queued event exactly once', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  const before = await readLogFile(page);
  await page.evaluate(async before => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle(window.fixtureFolder);
    const handle = await picked.getFileHandle('logs.json');
    const close = FileSystemWritableFileStream.prototype.close;
    FileSystemWritableFileStream.prototype.close = async function () {
      FileSystemWritableFileStream.prototype.close = close;
      await close.call(this);
      const replacement = await handle.createWritable();
      await replacement.write(before);
      await replacement.close();
    };
  }, before);
  const attempt = await page.evaluate(async () =>
    JSON.parse(await window.uagentWalletBackup.recordLog('queued retry fixture', 'info', 11111)));
  assert.ok(attempt.error);
  assert.equal(await page.evaluate(() => window.uagentWalletBackup.hasPendingLogs), true);
  assert.equal(await readLogFile(page), before);
  assert.equal((await call(page, 'checkAccess')).value, true);
  assert.equal((await call(page, 'flushHistory')).error, undefined);
  const {entries} = JSON.parse(await readLogFile(page));
  assert.deepEqual(entries.map(entry => entry.message), ['queued retry fixture']);
  assert.equal(await page.evaluate(() => window.uagentWalletBackup.hasPendingLogs), false);
});

test('a malformed existing log never gets overwritten or reported as connected', async t => {
  const {page} = await fixture(t);
  const damaged = '{"version":1,"entries": [';
  await page.evaluate(async damaged => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle(window.fixtureFolder, {create: true});
    const handle = await picked.getFileHandle('logs.json', {create: true});
    const writer = await handle.createWritable();
    await writer.write(damaged);
    await writer.close();
  }, damaged);
  assert.ok((await call(page, 'chooseDirectory')).error);
  assert.equal((await call(page, 'checkAccess')).value, false);
  assert.ok((await call(page, 'chooseDirectory')).error);
  assert.equal(await readLogFile(page), damaged);
});

test('a committed log retries after a failed readback without duplicating the entry', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await page.evaluate(() => {
    const close = FileSystemWritableFileStream.prototype.close;
    FileSystemWritableFileStream.prototype.close = async function () {
      FileSystemWritableFileStream.prototype.close = close;
      await close.call(this);
      const getFile = FileSystemFileHandle.prototype.getFile;
      FileSystemFileHandle.prototype.getFile = function () {
        if (this.name === 'logs.json') {
          FileSystemFileHandle.prototype.getFile = getFile;
          throw new DOMException('fixture', 'NotReadableError');
        }
        return getFile.call(this);
      };
    };
  });
  const attempt = await page.evaluate(async () =>
    JSON.parse(await window.uagentWalletBackup.recordLog('committed before read error', 'info', 12345)));
  assert.ok(attempt.error);
  assert.equal(await page.evaluate(() => window.uagentWalletBackup.hasPendingLogs), true);
  const original = await readLogFile(page);
  const {entries} = JSON.parse(original);
  assert.deepEqual(entries.map(entry => entry.message), ['committed before read error']);
  assert.equal((await call(page, 'flushHistory')).error, undefined);
  assert.equal(await page.evaluate(() => window.uagentWalletBackup.hasPendingLogs), false);
  assert.equal(await readLogFile(page), original);
});

test('log readback rejects invalid UTF-8 even when permissive text decoding would match', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await corruptNextReplacementCharacter(page);
  const attempt = await page.evaluate(async () =>
    JSON.parse(await window.uagentWalletBackup.recordLog('Unicode fixture �', 'info', 45678)));
  assert.ok(attempt.error);
  assert.equal(await page.evaluate(() => window.fixtureDecodedSame), true);
  assert.equal(await page.evaluate(() => window.uagentWalletBackup.hasPendingLogs), true);
  assert.ok((await call(page, 'checkAccess')).error);
  assert.ok((await call(page, 'flushHistory')).error);
});

test('each wallet backup has a durable readback result without key or scope contents', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  const second = {...record, category: 'launch-dev', scope: 'fixture-scope-not-for-logs'};
  assert.equal((await call(page, 'save', [record, second])).error, undefined);
  const persisted = JSON.parse(await readLogFile(page)).entries.map(entry => entry.message).join('\n');
  assert.match(persisted, /钱包备份回查通过/);
  assert.ok(persisted.includes('新建 工具生成钱包/' + address));
  assert.ok(persisted.includes('新建 发币开发者/' + address));
  assert.ok(!persisted.includes(record.privateKey) && !persisted.includes(second.scope));
  assert.equal((await call(page, 'save', [record])).error, undefined);
  assert.match((await call(page, 'history')).value, /已有 工具生成钱包/);
});

test('backup audit does not report durable success for an unreadable log and recovers on retry', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await page.evaluate(() => {
    const write = FileSystemFileHandle.prototype.createWritable;
    window.allowAudit = false;
    FileSystemFileHandle.prototype.createWritable = function(options) {
      if (!window.allowAudit && this.name === 'logs.json') throw new DOMException('locked', 'NoModificationAllowedError');
      return write.call(this, options);
    };
  });
  assert.match((await call(page, 'save', [record])).error, /钱包文件已回查，核验日志尚未保存/);
  assert.equal((await inspectTestFolder(page)).length, 1);
  await page.evaluate(() => { window.allowAudit = true; });
  assert.equal((await call(page, 'save', [record])).error, undefined);
  await page.reload();
  await call(page, 'reconnect');
  const saved = (await call(page, 'history')).value;
  assert.match(saved, /新建 工具生成钱包/);
  assert.match(saved, /已有 工具生成钱包/);
});

test('revocation keeps the failed audit in its original directory until permission is restored', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await call(page, 'save', [record]);
  await page.evaluate(() => {
    const query = FileSystemHandle.prototype.queryPermission;
    window.denyAuditDirectory = true;
    FileSystemHandle.prototype.queryPermission = function (options) {
      return this.name === 'test-selection' && window.denyAuditDirectory
        ? Promise.resolve('denied') : query.call(this, options);
    };
  });
  assert.equal((await call(page, 'save', [record])).code, 'permission');
  await page.evaluate(() => { window.fixtureFolder = 'other-audit-directory'; });
  await call(page, 'chooseDirectory');
  await call(page, 'save', [record]);
  assert.doesNotMatch((await call(page, 'history')).value, /未通过/);
  await page.evaluate(() => {
    window.denyAuditDirectory = false;
    window.fixtureFolder = 'test-selection';
  });
  await call(page, 'chooseDirectory');
  await call(page, 'save', [record]);
  const recovered = (await call(page, 'history')).value;
  assert.match(recovered, /未通过写入与回查。备份目录授权已失效/);
  assert.ok(!recovered.includes(record.privateKey));
});

function renameGroup(page, ...args) {
  return page.evaluate(async args => JSON.parse(await window.uagentWalletBackup.renameGeneratedGroup(...args)), args);
}

test('generated groups append in order and restore only their own keys and names from the selected folder', async t => {
  const {page, newPage} = await fixture(t);
  assert.ok((await call(page, 'generatedGroups')).error);
  await call(page, 'chooseDirectory');
  assert.deepEqual((await call(page, 'generatedGroups')).value, []);
  const second = await newPage();
  await call(second, 'chooseDirectory');
  const one = {...dev, category: 'tool-generated', scope: dev.address};
  const two = {...one, address: '0x6813eb9362372eef6200f3b1dbc3f819671cba69', privateKey: '0x' + '3'.padStart(64,'0')};
  const three = {...record, address: '0x1eff47bc3a10a45d4b230b5d10e37751fe6aa718', privateKey: '0x' + '4'.padStart(64,'0')};
  three.scope = three.address;
  const unrelated = {...dev, address: '0xe1ab8145f7e55dc933d51a18c793f901a3a0b276', privateKey: '0x' + '5'.padStart(64,'0')};
  await call(page, 'save', [record, unrelated]);
  const legacyBytes = await readArchive(page);
  assert.deepEqual((await call(page, 'generatedGroups')).value.map(g => g.id), ['legacy']);
  assert.equal(await readArchive(page), legacyBytes);
  assert.equal((await call(page, 'saveGeneratedBatch', [one, two])).value, '第 2 组');
  assert.deepEqual(JSON.parse(await readArchive(page)).generatedGroupNames, {[dev.address]: '第 2 组'});
  const results = await Promise.all([
    renameGroup(second, dev.address, '第 2 组', '  备用钱包  '),
    call(page, 'save', [three, {...two, category: 'trade-group', scope: '01'}]),
  ]);
  assert.ok(results.every(r => !r.error));
  const conflict = await renameGroup(page, dev.address, '', '过期名称');
  assert.match(conflict.error, /其他窗口更改/);
  const renamed = await readArchive(page);
  assert.deepEqual(JSON.parse(renamed).generatedGroupNames, {[dev.address]: '备用钱包', [three.address]: '第 3 组'});
  assert.equal((await call(page, 'saveGeneratedBatch', [one, two])).value, '备用钱包');
  assert.ok(!(await renameGroup(page, dev.address, '', '备用钱包')).error);
  assert.equal(await readArchive(page), renamed);
  for (const name of ['   ', 'x'.repeat(65), 'A\nB', '\t名']) {
    assert.ok((await renameGroup(page, dev.address, '备用钱包', name)).error);
    assert.equal(await readArchive(page), renamed);
  }
  const results2 = await Promise.all([
    renameGroup(page, 'legacy', '', '旧版生成'),
    renameGroup(second, three.address, '第 3 组', '收款备用'),
  ]);
  assert.ok(results2.every(r => !r.error));
  await page.reload();
  assert.equal((await call(page, 'reconnect')).value, 'test-selection');
  const rows = await call(page, 'generatedGroups');
  const keys = wallets => wallets.map(({address, privateKey}) => ({address, privateKey}));
  assert.deepEqual(rows.value, [
    {id:'legacy',name:'旧版生成',wallets:keys([record])},
    {id:dev.address,name:'备用钱包',wallets:keys([one, two])},
    {id:three.address,name:'收款备用',wallets:keys([three])},
  ]);
  const history = (await call(page, 'history')).value;
  assert.match(history, /生成钱包组改名回查通过/);
  assert.match(history, /生成钱包组改名未通过/);
  for (const sensitive of ['收款备用', '备用钱包', '旧版生成', '过期名称', one.privateKey]) assert.ok(!history.includes(sensitive));
  await page.evaluate(() => { window.fixtureFolder = 'separate-folder'; });
  await call(page, 'chooseDirectory');
  assert.deepEqual((await call(page, 'generatedGroups')).value, []);
  assert.ok((await renameGroup(page, dev.address, '备用钱包', '另一组')).error);
  assert.equal(await readArchive(page, 'separate-folder'), null);
});

test('two concurrent first saves commit each default group name with its keys and return that name', async t => {
  const {page, newPage} = await fixture(t);
  await call(page, 'chooseDirectory');
  const second = await newPage();
  await call(second, 'chooseDirectory');
  const a = {...record, scope: record.address};
  const b = {...dev, category: 'tool-generated', scope: dev.address};
  for (const bad of [[], [record], [a, b], [dev]]) {
    assert.ok((await call(page, 'saveGeneratedBatch', bad)).error);
    assert.equal(await readArchive(page), null);
  }
  const [firstWindow, secondWindow] = await Promise.all([
    call(page, 'saveGeneratedBatch', [a]),
    call(second, 'saveGeneratedBatch', [b]),
  ]);
  assert.deepEqual([firstWindow.value, secondWindow.value].sort(), ['第 1 组', '第 2 组']);
  const before = await readArchive(page);
  const archive = JSON.parse(before);
  assert.deepEqual(archive.generatedGroupNames, {[a.address]: firstWindow.value, [b.address]: secondWindow.value});
  assert.deepEqual(archive.wallets.map(w => archive.generatedGroupNames[w.address]), ['第 1 组', '第 2 组']);
  assert.deepEqual((await call(page, 'generatedGroups')).value.map(g => g.name), ['第 1 组', '第 2 组']);
  assert.equal((await call(page, 'saveGeneratedBatch', [a])).value, firstWindow.value);
  assert.equal((await call(page, 'save', [b])).value, null);
  assert.equal(await readArchive(page), before);
});

async function replaceAfterNextCommit(page, original) {
  await page.evaluate(async original => {
    const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
    const base = await picked.getDirectoryHandle('UAgent-wallets');
    const file = await base.getFileHandle('wallets.json');
    const close = FileSystemWritableFileStream.prototype.close;
    FileSystemWritableFileStream.prototype.close = async function() {
      FileSystemWritableFileStream.prototype.close = close;
      await close.call(this);
      const other = await file.createWritable();
      await other.write(original);
      await other.close();
    };
  }, original);
}

test('rename verifies committed bytes and only acknowledges durable audit on retry', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await call(page, 'save', [record]);
  const original = await readArchive(page);
  await replaceAfterNextCommit(page, original);
  assert.match((await renameGroup(page, 'legacy', '', '重命名')).error, /校验失败/);
  assert.equal(await readArchive(page), original);
  await page.evaluate(() => {
    const create = FileSystemFileHandle.prototype.createWritable;
    FileSystemFileHandle.prototype.createWritable = function(options) {
      if (this.name === 'logs.json') throw new DOMException('fixture', 'NoModificationAllowedError');
      return create.call(this, options);
    };
  });
  assert.match((await renameGroup(page, 'legacy', '', '重命名')).error, /核验日志尚未保存/);
  assert.equal((await call(page, 'generatedGroups')).value[0].name, '重命名');
  await page.reload();
  await call(page, 'reconnect');
  assert.ok(!(await renameGroup(page, 'legacy', '', '重命名')).error);
  assert.match((await call(page, 'history')).value, /生成钱包组改名回查通过/);
});

test('deleting a group persists only a marker, survives retries, and never recycles its number', async t => {
  const {page, newPage} = await fixture(t);
  const second = await newPage();
  await call(page, 'chooseDirectory');
  await call(second, 'chooseDirectory');
  const a = {...record, scope: record.address};
  const b = {...dev, category:'tool-generated', scope:dev.address};
  const drop = (tab, ...args) => tab.evaluate(async args =>
    JSON.parse(await window.uagentWalletBackup.deleteGeneratedGroup(...args)), args);
  assert.equal((await call(page, 'saveGeneratedBatch', [a])).value, '第 1 组');
  assert.ok(!(await renameGroup(second, a.scope, '第 1 组', '备用')).error);
  const before = JSON.parse(await readArchive(page));
  assert.match((await drop(page, a.scope, '第 1 组')).error, /其他窗口更改/);
  assert.deepEqual(JSON.parse(await readArchive(page)), before);

  await replaceAfterNextCommit(page, await readArchive(page));
  assert.match((await drop(page, a.scope, '备用')).error, /校验失败/);
  assert.deepEqual(JSON.parse(await readArchive(page)), before);
  assert.deepEqual((await call(page, 'generatedGroups')).value.map(g => g.id), [a.scope]);

  assert.ok(!(await drop(second, a.scope, '备用')).error);
  const after = JSON.parse(await readArchive(page));
  assert.deepEqual(after, {...before, deletedGeneratedGroups: [a.scope]});
  assert.ok(!(await drop(page, a.scope, '备用')).error);
  assert.deepEqual(JSON.parse(await readArchive(page)), after);
  assert.ok((await renameGroup(page, a.scope, '备用', '新名')).error);
  assert.ok((await call(page, 'saveGeneratedBatch', [a])).error);
  assert.equal((await call(page, 'saveGeneratedBatch', [b])).value, '第 2 组');
  await page.reload();
  await call(page, 'reconnect');
  assert.deepEqual((await call(page, 'generatedGroups')).value.map(g => g.id), [b.scope]);
  assert.deepEqual(JSON.parse(await readArchive(page)).wallets[0], before.wallets[0]);
  const log = (await call(page, 'history')).value;
  assert.match(log, /生成钱包组删除标记回查通过/);
  assert.ok(!log.includes(a.privateKey));
});

test('malformed generated scopes, duplicate assignments and orphan names leave the archive intact', async t => {
  const {page} = await fixture(t);
  await call(page, 'chooseDirectory');
  await call(page, 'save', [record]);
  const original = await readArchive(page);
  for (const bad of [
    archive => {archive.wallets[0].usages[0].scope = 'wrong';},
    archive => {archive.wallets[0].usages[0].scope = dev.address;},
    archive => {archive.wallets[0].usages.push({...archive.wallets[0].usages[0], scope:address});},
    archive => {archive.generatedGroupNames = {[dev.address]: 'invalid orphan'};},
    archive => {archive.generatedGroupNames = [];},
    archive => {archive.deletedGeneratedGroups = 'legacy';},
    archive => {archive.deletedGeneratedGroups = ['legacy', 'legacy'];},
    archive => {archive.deletedGeneratedGroups = [dev.address];},
  ]) {
    const archive = JSON.parse(original);
    bad(archive);
    const before = JSON.stringify(archive);
    await page.evaluate(async before => {
      const picked = await (await navigator.storage.getDirectory()).getDirectoryHandle('test-selection');
      const base = await picked.getDirectoryHandle('UAgent-wallets');
      const writer = await (await base.getFileHandle('wallets.json')).createWritable();
      await writer.write(before);
      await writer.close();
    }, before);
    assert.ok((await call(page, 'generatedGroups')).error);
    assert.ok((await renameGroup(page, 'legacy', '', 'new')).error);
    assert.ok((await call(page, 'save', [dev])).error);
    assert.equal(await readArchive(page), before);
  }
});

#!/usr/bin/env node
/** Manual, anonymous, read-only upstream compatibility check. Never updates its baseline. */
import {chromium} from 'playwright';
import {createHash} from 'node:crypto';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const baselinePath = resolve(root, 'tests/fixtures/flap-compatibility-baseline.json');
const reportPath = resolve(root, 'test-results/flap-check-latest.json');
const launchUrl = 'https://flap.sh/launch?chain=bnb&lang=zh';
const rpcUrl = process.env.UXUY_BSC_RPC_URL;
if (!rpcUrl) throw Error('Set UXUY_BSC_RPC_URL to a BSC read node before checking Flap.');
const timeoutMs = 30_000;
const methods = new Set(['eth_call', 'eth_getCode', 'eth_chainId', 'eth_blockNumber', 'eth_getBalance', 'eth_getTransactionCount', 'eth_getBlockByNumber', 'eth_getLogs', 'eth_estimateGas', 'net_version']);
const functions = ['newTokenV6', 'newTokenV7', 'newTokenV6WithVault', 'newTokenV7WithVault'];
const sha = value => createHash('sha256').update(value).digest('hex');
const stable = value => JSON.stringify(canonical(value));
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return typeof value === 'string' && /^0x[0-9a-f]{40}$/i.test(value) ? value.toLowerCase() : value;
}
function safeUrl(url) { const u = new URL(url); return u.origin + u.pathname; }
function readOnlyRpc(body) {
  try {
    const parsed = JSON.parse(body ?? 'null');
    const rows = Array.isArray(parsed) ? parsed : [parsed];
    return rows.length > 0 && rows.length <= 256 && rows.every(row => row?.jsonrpc === '2.0' && methods.has(row.method) && Array.isArray(row.params));
  } catch { return false; }
}
function vaultShape(vaults) {
  if (!Array.isArray(vaults) || !vaults.length || vaults.length > 1000) throw Error('Vault list missing or invalid');
  const result = vaults.map(v => {
    if (!v || typeof v.name !== 'string' || !/^0x[0-9a-f]{40}$/i.test(v.factory) || typeof v.enabled !== 'boolean') throw Error('Invalid Vault entry');
    return canonical({name: v.name, factory: v.factory, enabled: v.enabled,
      showInCAStore: v.showInCAStore ?? null, constraints: v.constraints ?? {},
      launchConfig: v.launchConfig ?? null, exclusive: v.exclusive ?? [], extra: v.extra ?? {}});
  }).sort((a,b) => a.factory.localeCompare(b.factory));
  if (new Set(result.map(v => v.factory)).size !== result.length) throw Error('Duplicate Vault factory');
  return result;
}
function abiShape(abi) {
  if (abi.type !== 'function' || !functions.includes(abi.name) || !Array.isArray(abi.inputs) || !Array.isArray(abi.outputs)) throw Error('Invalid launch ABI');
  const param = (p, includeName) => ({...(includeName ? {name: p.name} : {}), type: p.type,
    ...(p.components ? {components: p.components.map(c => param(c, true))} : {})});
  return {name: abi.name, stateMutability: abi.stateMutability,
    inputs: abi.inputs.map(p => param(p, false)), outputs: abi.outputs.map(p => param(p, false))};
}
// Decode only a string literal, never evaluate downloaded JavaScript.
function readJsString(source, start) {
  const quote = source[start]; let out = '';
  for (let i = start + 1; i < source.length; i++) {
    const ch = source[i];
    if (ch === quote) return {value: out, end: i + 1};
    if (ch !== '\\') { out += ch; continue; }
    const escaped = source[++i];
    const simple = {'\\':'\\', "'":"'", '"':'"', n:'\n', r:'\r', t:'\t', b:'\b', f:'\f', v:'\v', '0':'\0'};
    if (Object.hasOwn(simple, escaped)) out += simple[escaped];
    else if (escaped === 'x' || escaped === 'u') {
      const size = escaped === 'x' ? 2 : 4, hex = source.slice(i + 1, i + 1 + size);
      if (!new RegExp(`^[0-9a-f]{${size}}$`, 'i').test(hex)) throw Error('Unsupported script string escape');
      out += String.fromCharCode(parseInt(hex,16)); i += size;
    } else if (escaped !== '\n') throw Error('Unsupported script string escape');
  }
  throw Error('Unterminated script string');
}
function launchAbis(scripts) {
  const found = new Map(), sources = {};
  for (const [url, source] of scripts) {
    const matches = source.matchAll(/JSON\.parse\(\s*(['"])/g);
    for (const match of matches) {
      const decoded = readJsString(source, match.index + match[0].length - 1);
      if (!functions.some(name => decoded.value.includes(`"name":"${name}"`))) continue;
      const entries = JSON.parse(decoded.value);
      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        if (entry.type !== 'function' || !functions.includes(entry.name)) continue;
        const value = abiShape(entry), previous = found.get(entry.name);
        if (previous && stable(previous) !== stable(value)) throw Error(`Conflicting ABI definitions: ${entry.name}`);
        found.set(entry.name, value); (sources[entry.name] ??= []).push(url);
      }
    }
  }
  for (const name of functions) if (!found.has(name)) throw Error(`Current page did not expose ${name} ABI; cannot verify`);
  return {abis: Object.fromEntries(functions.map(name => [name, found.get(name)])), sources};
}
function decodeString(hex) {
  if (typeof hex !== 'string' || !/^0x(?:[0-9a-f]{2})+$/i.test(hex)) throw Error('Invalid RPC string result');
  const data = Buffer.from(hex.slice(2), 'hex');
  if (data.length < 64) throw Error('Short RPC string result');
  const offset = Number(BigInt('0x' + data.subarray(0,32).toString('hex')));
  if (!Number.isSafeInteger(offset) || offset < 32 || offset + 32 > data.length) throw Error('Invalid RPC string offset');
  const size = Number(BigInt('0x' + data.subarray(offset, offset + 32).toString('hex')));
  if (!Number.isSafeInteger(size) || size < 1 || size > 128 || offset + 32 + size > data.length) throw Error('Invalid RPC version length');
  return data.subarray(offset + 32, offset + 32 + size).toString('utf8');
}
async function chainVersions(expected) {
  const rows = [{jsonrpc:'2.0', id:0, method:'eth_chainId', params:[]},
    ...Object.entries(expected).map(([name, entry], i) => ({jsonrpc:'2.0', id:i+1, method:'eth_call', params:[{to:entry.address, data:'0x54fd4d50'}, 'latest']}))];
  const body = JSON.stringify(rows);
  if (!readOnlyRpc(body)) throw Error('Read-only RPC guard rejected request');
  const response = await fetch(rpcUrl, {method:'POST', headers:{'content-type':'application/json'}, body, signal:AbortSignal.timeout(timeoutMs)});
  if (!response.ok) throw Error(`Version RPC HTTP ${response.status}`);
  const result = await response.json();
  if (!Array.isArray(result) || result.length !== rows.length) throw Error('Version RPC returned incomplete batch');
  const mapped = new Map(result.map(row => [row.id, row]));
  if (mapped.get(0)?.result !== '0x38') throw Error('Version RPC chain mismatch');
  return Object.fromEntries(Object.entries(expected).map(([name, entry], i) => {
    const row = mapped.get(i + 1); if (row?.error || !row?.result) throw Error(`${name} version read failed`);
    return [name, {address:entry.address, version:decodeString(row.result)}];
  }));
}

const report = {checkedAt:new Date().toISOString(), source:launchUrl, status:'unverifiable', ok:false,
  baseline:'tests/fixtures/flap-compatibility-baseline.json', changes:[], errors:[], blockedRequests:[], scripts:[], observations:{},
  scope:'Official launch UI Vault list/constraints, four launch ABI layouts, Portal/VaultPortal version. Does not certify every Vault or authorize transactions.'};
let browser;
try {
  const baseline = JSON.parse(await readFile(baselinePath, 'utf8'));
  browser = await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
  const context = await browser.newContext({viewport:{width:1440,height:1100}, serviceWorkers:'block'});
  context.setDefaultTimeout(timeoutMs); context.setDefaultNavigationTimeout(timeoutMs);
  const scripts = new Map(), scriptFailures = [], pending = new Set();
  let scriptBytes = 0;
  await context.route('**/*', async route => {
    const request = route.request(), url = request.url(), method = request.method();
    const isScript = request.resourceType() === 'script' && new URL(url).origin === 'https://flap.sh';
    if ((method === 'POST' && !readOnlyRpc(request.postData())) || !['GET','HEAD','OPTIONS','POST'].includes(method)) {
      report.blockedRequests.push({method,url:safeUrl(url)}); await route.abort('blockedbyclient'); return;
    }
    if (['image','font','media'].includes(request.resourceType())) { await route.abort('blockedbyclient'); return; }
    const work = (async () => {
      try {
        const response = await route.fetch({timeout:timeoutMs,maxRedirects:5});
        if (isScript) {
          if (!response.ok()) throw Error(`HTTP ${response.status()}`);
          const data = await response.body(); scriptBytes += data.length;
          if (data.length > 8_000_000 || scriptBytes > 40_000_000) throw Error('Script capture budget exceeded');
          scripts.set(url,data.toString('utf8'));
        }
        await route.fulfill({response});
      } catch (error) {
        if (isScript) scriptFailures.push({url,error:String(error).slice(0,500)});
        await route.abort().catch(()=>{});
      }
    })();
    pending.add(work); try { await work; } finally { pending.delete(work); }
  });
  const page = await context.newPage();
  page.on('pageerror', error => (report.observations.browserErrors ??= []).push(String(error).slice(0,500)));
  await page.goto(launchUrl,{waitUntil:'domcontentloaded'});
  // The server-rendered button is visible before React attaches its handlers.
  await page.waitForFunction(() => [...document.querySelectorAll('button')].some(button => {
    if (!/^(選擇|选择) Vault/.test(button.textContent.trim())) return false;
    const propsKey = Object.keys(button).find(key => key.startsWith('__reactProps$'));
    return typeof button[propsKey]?.onClick === 'function';
  }));
  await page.getByRole('button',{name:/^(選擇|选择) Vault/}).click();
  await page.getByRole('button',{name:/^(啟用|启用) Vault/}).click();
  await page.getByRole('button',{name:/^(浏览|瀏覽)$/}).click();
  await page.getByRole('dialog').waitFor();
  const vaults = await page.getByRole('dialog').evaluate(dialog => {
    const choices = [];
    for (const element of dialog.querySelectorAll('button')) {
      let fiber = element[Object.keys(element).find(key => key.startsWith('__reactFiber$'))];
      for (let depth = 0; fiber && depth < 80; depth++, fiber=fiber.return) {
        const values = fiber.memoizedProps?.vaults;
        if (Array.isArray(values) && values.length && values.every(v => v && typeof v.factory === 'string')) {
          const json = JSON.stringify(values); if (!choices.includes(json)) choices.push(json);
        }
      }
    }
    if (choices.length !== 1) throw Error(`Expected one complete Vault list; found ${choices.length}`);
    return JSON.parse(choices[0]);
  });
  const currentVaults = vaultShape(vaults);
  await Promise.allSettled([...pending]);
  if (scriptFailures.length) throw Error('Official script capture incomplete: ' + JSON.stringify(scriptFailures));
  const currentAbi = launchAbis(scripts);
  report.scripts = [...scripts].map(([url,body]) => ({url,sha256:sha(body)}));
  report.observations.vaults = currentVaults;
  report.observations.abis = currentAbi.abis;
  report.observations.abiSources = currentAbi.sources;
  report.observations.version = await chainVersions(baseline.versions);
  const previousVaults = new Map(baseline.vaults.map(v => [v.factory,v]));
  const nextVaults = new Map(currentVaults.map(v => [v.factory,v]));
  for (const [factory,value] of nextVaults) {
    if (!previousVaults.has(factory)) report.changes.push({area:'vault',factory,kind:'added',after:value});
    else if (stable(previousVaults.get(factory)) !== stable(value)) report.changes.push({area:'vault',factory,kind:'changed',before:previousVaults.get(factory),after:value});
  }
  for (const [factory,value] of previousVaults) if (!nextVaults.has(factory)) report.changes.push({area:'vault',factory,kind:'removed',before:value});
  for (const name of functions) if (stable(baseline.abis[name]) !== stable(currentAbi.abis[name])) report.changes.push({area:'abi',name,before:baseline.abis[name],after:currentAbi.abis[name]});
  for (const [name,value] of Object.entries(report.observations.version)) if (value.version !== baseline.versions[name].version) report.changes.push({area:'version',name,before:baseline.versions[name].version,after:value.version,action:'Manual compatibility review required; no production settings changed'});
  // Special factories encode data outside the generic schema. A new official
  // helper build therefore needs review even if the launch ABI stayed the same.
  for (const source of baseline.adapterSources ?? []) {
    const current = report.scripts.find(s => new URL(s.url).pathname.split('/').pop().startsWith(`${source.chunk}-`));
    if (!current || current.sha256 !== source.sha256) report.changes.push({
      area:'adapter-source', name:source.role, chunk:source.chunk,
      before:source.sha256, after:current?.sha256 ?? null,
      action:'Official helper changed or moved; review curated encoders. This alone does not prove incompatibility.',
    });
  }
  report.status = report.changes.length ? 'changed' : 'verified'; report.ok = report.status === 'verified';
  report.observations.buildAssetsNote = 'Reviewed Vault helper hashes trigger manual review; unrelated build hashes are informational. Hash changes alone do not prove incompatible behavior.';
} catch (error) {
  report.errors.push(String(error).slice(0,2000));
} finally {
  await browser?.close().catch(()=>{});
  await mkdir(dirname(reportPath), {recursive: true});
  await writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
}
console.log(JSON.stringify({status:report.status,ok:report.ok,vaults:report.observations.vaults?.length,abis:Object.keys(report.observations.abis??{}),versions:report.observations.version,changes:report.changes.length,errors:report.errors,report:reportPath},null,2));
process.exitCode = report.ok ? 0 : report.status === 'changed' ? 1 : 2;

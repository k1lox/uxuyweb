import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {after, before, test} from 'node:test';
import {chromium} from 'playwright';

const html = await readFile(new URL('../frontend/web/web/index.html', import.meta.url), 'utf8');
const origin = 'http://localhost:3190';
const base = '/workspace/';
const bootstrap = 'flutter_bootstrap-0123456789abcdef.js';
let chrome;

before(async () => {
  chrome = await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
});
after(async () => chrome?.close());

// Use the release packer's literal bootstrap-name substitution and Flutter's
// base href substitution. Stub both scripts so this fixture needs no backend.
async function visit(t, profile) {
  const context = await chrome.newContext({serviceWorkers: 'block'});
  t.after(() => context.close());
  if (profile) {
    await context.addInitScript(({brands, ua, brave}) => {
      Object.defineProperty(navigator, 'userAgentData', {value: brands
        ? {brands: brands.map(brand => ({brand, version: '150'}))}
        : undefined});
      if (ua) Object.defineProperty(navigator, 'userAgent', {value: ua});
      if (brave) Object.defineProperty(navigator, 'brave', {value: {isBrave: async () => true}});
    }, profile);
  }
  const page = await context.newPage();
  const requests = [];
  await context.route('**/*', route => {
    const url = new URL(route.request().url());
    requests.push(url.pathname);
    assert.equal(url.origin, origin);
    if (url.pathname === base) return route.fulfill({
      contentType: 'text/html',
      body: html.replace('$FLUTTER_BASE_HREF', base)
        .replace('src="flutter_bootstrap.js"', `src="${bootstrap}"`),
    });
    if (url.pathname === base + 'favicon.png') return route.fulfill({status: 204});
    if (url.pathname === base + 'wallet_backup.js') return route.fulfill({
      contentType: 'application/javascript', body: 'window.backupLoaded = true;',
    });
    if (url.pathname === base + bootstrap) return route.fulfill({
      contentType: 'application/javascript',
      body: "if (window.backupLoaded) window.dispatchEvent(new Event('flutter-first-frame'));",
    });
    return route.abort();
  });
  await page.goto(origin + base, {waitUntil: 'networkidle'});
  return {page, requests};
}

test('installed Google Chrome starts the backup bridge before the versioned app', async t => {
  const {page, requests} = await visit(t);
  await page.locator('#loading').waitFor({state: 'detached'});
  assert.deepEqual(requests.filter(path => path.endsWith('.js')),
    [base + 'wallet_backup.js', base + bootstrap]);
  assert.equal(await page.locator('#notice').isVisible(), false);
});

const chromeUA = 'Mozilla/5.0 AppleWebKit/537.36 Chrome/150.0.0.0 Safari/537.36';
const chromiumBrands = ['Not_A Brand', 'Chromium'];
const otherProfiles = {
  Edge: {brands: [...chromiumBrands, 'Microsoft Edge'], ua: chromeUA + ' Edg/150.0'},
  Opera: {brands: [...chromiumBrands, 'Opera'], ua: chromeUA + ' OPR/130.0'},
  Brave: {brands: [...chromiumBrands, 'Google Chrome'], ua: chromeUA, brave: true},
  Chromium: {brands: chromiumBrands, ua: chromeUA},
  WebView: {brands: ['Google Chrome'], ua: 'Mozilla/5.0 (Linux; Android 12; wv) ' + chromeUA},
  Firefox: {ua: 'Mozilla/5.0 Gecko/20100101 Firefox/136.0'},
  Safari: {ua: 'Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15'},
  'unidentified Chromium': {ua: chromeUA},
};
for (const [name, profile] of Object.entries(otherProfiles)) {
  test(`${name} gets the Chrome notice without requesting any application code`, async t => {
    const {page, requests} = await visit(t, profile);
    assert.equal(await page.locator('#notice').innerText(), '请用 Google Chrome 打开此网站。');
    assert.equal(await page.locator('#notice').isVisible(), true);
    assert.deepEqual(requests.filter(path => ![base, base + 'favicon.png'].includes(path)), []);
    assert.equal(await page.evaluate(() => window.backupLoaded), undefined);
  });
}

test('iOS Chrome is recognized through its CriOS identifier', async t => {
  const {page} = await visit(t, {ua: 'Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 CriOS/150.0.0.0 Mobile/15E148 Safari/604.1'});
  await page.locator('#loading').waitFor({state: 'detached'});
  assert.equal(await page.locator('#notice').isVisible(), false);
});

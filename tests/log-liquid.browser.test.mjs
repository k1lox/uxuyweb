import {test} from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright';
import {mkdir, rm, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';

const base = process.env.UXUY_PREVIEW_URL || 'http://127.0.0.1:3190/';
const origin = new URL(base).origin;
assert.ok(['127.0.0.1','localhost','[::1]'].includes(new URL(base).hostname), 'This test only opens a local preview');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const center = b => ({x: b.x + b.width / 2, y: b.y + b.height / 2});
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

for (const size of [{width:1440,height:900}, {width:390,height:844}]) {
  test(`liquid log ${size.width}x${size.height}: intermediate frames, reversal, drag, resize`, {timeout:90000}, async () => {
    const directory = `test-results/liquid-log/${size.width}x${size.height}`;
    await mkdir(directory, {recursive:true});
    const browser = await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
    const context = await browser.newContext({viewport:size, deviceScaleFactor:1, reducedMotion:'no-preference'});
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    const errors = [], requests = [], blocked = [], consoleErrors = [], phases = [];
    page.on('pageerror', error => errors.push(String(error)));
    page.on('console', message => {
      if (message.type() === 'error') consoleErrors.push(message.text());
    });
    // No request to a live backend or third-party service can escape this context.
    await context.route('**/*', async route => {
      const request = route.request(), url = new URL(request.url()), path = url.pathname;
      if (!path.startsWith('/api/')) {
        if (url.origin === origin) return route.continue();
        blocked.push(url.origin + path);
        return route.fulfill({status:204, body:''});
      }
      requests.push({method:request.method(), path});
      let body = {ok:false, code:'FIXTURE_ONLY', message:'Isolated log animation test'};
      if (path === '/api/v1/config') body = {ok:true, chainId:56, router:'0x00000000000000000000000000000000000c0de1', routeSource:'uxuy', routeEnabled:true, approvalSpender:'0x00000000000000000000000000000000000c0de2', maxPriceImpactPercent:7};
      if (path === '/api/fourmeme') body = {ok:true, payload:{code:0, data:[]}};
      if (path === '/api/flap') body = {ok:true, payload:{tokens:[]}};
      return route.fulfill({status:200, contentType:'application/json', body:JSON.stringify(body)});
    });
    const cdp = await context.newCDPSession(page);
    let active, captureStart = 0;
    cdp.on('Page.screencastFrame', event => {
      if (active) active.push({ms:Date.now() - captureStart, bytes:Buffer.from(event.data, 'base64')});
      void cdp.send('Page.screencastFrameAck', {sessionId:event.sessionId}).catch(() => {});
    });
    const ball = () => page.getByRole('button', {name:/^打开日志/});
    const toggle = () => page.getByRole('button', {name:/^收起日志/});
    const panel = () => page.getByLabel(/^日志面板/).first();
    async function capture(name, action, settle = 1150, keepPointer = false) {
      const frames = [];
      const before = await cdp.send('Page.captureScreenshot', {format:'jpeg', quality:85});
      frames.push({ms:0, bytes:Buffer.from(before.data, 'base64')});
      captureStart = Date.now(); active = frames;
      await action();
      // Also exercise the real reported case: repeated clicks without moving
      // the pointer off the toggle. Moving it away hides InkWell hover flashes.
      if (!keepPointer) await page.mouse.move(8, page.viewportSize().height / 2);
      await page.waitForTimeout(settle);
      active = undefined;
      const after = await cdp.send('Page.captureScreenshot', {format:'jpeg', quality:85});
      frames.push({ms:Date.now() - captureStart, bytes:Buffer.from(after.data, 'base64')});
      const folder = `${directory}/${name}`;
      await rm(folder, {recursive:true, force:true});
      await mkdir(folder, {recursive:true});
      await Promise.all(frames.map((f,i) => writeFile(`${folder}/frame-${String(i).padStart(3,'0')}.jpg`, f.bytes)));
      const metadata = frames.map((f,i) => ({file:`frame-${String(i).padStart(3,'0')}.jpg`, ms:f.ms, sha256:hash(f.bytes)}));
      await writeFile(`${folder}/frames.json`, JSON.stringify(metadata, null, 2));
      // At least one distinct interior frame must exist, not just before/after screenshots.
      const unique = new Set(metadata.map(f => f.sha256));
      assert.ok(frames.length >= 4 && unique.size >= 3, `${name}: capture actual intermediate animation frames`);
      const indexes = [...new Set(Array.from({length:8}, (_,i) => Math.round(i*(frames.length-1)/7)))];
      const crop = size.width > 800 && name !== '04-bottom-open' ? 'crop=min(iw\\,620):min(ih\\,430):iw-min(iw\\,620):0,' : '';
      const filter = `select='${indexes.map(i=>`eq(n,${i})`).join('+')}',${crop}scale=360:-1,tile=4x2`;
      const sheet = spawnSync('ffmpeg', ['-hide_banner','-loglevel','error','-y','-i',`${folder}/frame-%03d.jpg`,'-vf',filter,'-frames:v','1',`${folder}/contact-sheet.jpg`], {encoding:'utf8'});
      const timingSamples = [200,400].map(target => metadata.reduce((best,frame) => Math.abs(frame.ms-target)<Math.abs(best.ms-target) ? frame : best));
      phases.push({name, frameCount:frames.length, uniqueFrames:unique.size, timingSamples, contactSheet:sheet.status === 0, ffmpegError:sheet.status === 0 ? undefined : sheet.stderr || sheet.error?.message});
    }
    async function bounds() {
      await panel().waitFor({state:'visible'});
      const p = await panel().boundingBox(), t = await toggle().boundingBox(), viewport = page.viewportSize();
      assert.ok(p && t, 'expanded surface and toggle expose measurable bounds');
      assert.ok(p.x >= -1 && p.y >= -1 && p.x+p.width <= viewport.width+1 && p.y+p.height <= viewport.height+1, `panel in viewport: ${JSON.stringify({p,viewport})}`);
      assert.ok(Math.abs(t.x+t.width-(p.x+p.width)) < 3 && Math.abs(t.y-p.y) < 3, 'toggle remains at panel top-right');
      return {panel:p, toggle:t};
    }
    let initialRequests = 0, startedAt = 0;
    try {
      await page.goto(base, {waitUntil:'networkidle'});
      await page.waitForFunction(() => !document.querySelector('#loading'), null, {timeout:60000});
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      await ball().waitFor();
      await page.waitForTimeout(300);
      initialRequests = requests.length;
      startedAt = Date.now();
      await cdp.send('Page.startScreencast', {format:'jpeg', quality:85, everyNthFrame:1});
      const original = center(await ball().boundingBox());
      await capture('01-open', () => page.mouse.click(original.x, original.y), 700, true);
      const opened = await bounds();
      assert.ok(distance(original, center(opened.toggle)) < 2, 'opening at a fitting position preserves the toggle point');
      const screenshot = await page.screenshot();
      const colors = await page.evaluate(async ({data, p, t}) => {
        const img = new Image(); img.src = `data:image/png;base64,${data}`; await img.decode();
        const canvas = document.createElement('canvas'); canvas.width = img.width; canvas.height = img.height;
        const ctx = canvas.getContext('2d'); ctx.drawImage(img, 0, 0);
        const pixel = (x,y) => [...ctx.getImageData(Math.round(x), Math.round(y),1,1).data].slice(0,3);
        return {toggleInterior:pixel(t.x+9,t.y+24), border:pixel(p.x+40,p.y)};
      }, {data:screenshot.toString('base64'),p:opened.panel,t:opened.toggle});
      assert.ok(colors.toggleInterior.every(c=>c>=248), `hover keeps the toggle white: ${JSON.stringify(colors)}`);
      assert.ok(colors.border.every(c=>c<32), `expanded border retains the same black as the circle: ${JSON.stringify(colors)}`);
      await writeFile(`${directory}/held-hover-colors.json`, JSON.stringify(colors,null,2));
      await capture('02-close', () => page.mouse.click(original.x, original.y), 700, true);
      await ball().waitFor();
      assert.ok(distance(original, center(await ball().boundingBox())) < 2, 'closing preserves the same clickable point');
      await capture('03-rapid-reversal', async () => {
        await page.mouse.click(original.x, original.y);
        await page.waitForTimeout(90);
        await page.mouse.click(original.x, original.y);
        await page.waitForTimeout(70);
        await page.mouse.click(original.x, original.y);
      }, 700, true);
      await bounds();
      await page.mouse.click(original.x, original.y);
      await page.waitForTimeout(1000);
      const dragFrom = center(await ball().boundingBox());
      await page.mouse.move(dragFrom.x, dragFrom.y); await page.mouse.down();
      await page.mouse.move(36, size.height-28, {steps:24});
      const dragging = await ball().boundingBox();
      assert.ok(dragging.x < 65 && dragging.y > size.height-100, 'collapsed ball can reach the bottom-left while dragging');
      await page.screenshot({path:`${directory}/drag-held-bottom.jpg`});
      await page.mouse.up(); await page.waitForTimeout(100);
      const bottom = center(await ball().boundingBox());
      await capture('04-bottom-open', () => page.mouse.click(bottom.x, bottom.y), 1400);
      const fitted = await bounds();
      assert.ok(fitted.toggle.y < dragging.y-100, 'opening nudges the bottom ball upward to fit the panel');
      const fittedPoint = center(fitted.toggle);
      await page.mouse.click(fittedPoint.x, fittedPoint.y); await page.waitForTimeout(1000);
      assert.ok(distance(fittedPoint, center(await ball().boundingBox())) < 2, 'after repositioning, the same point still closes and reopens');
      await page.mouse.click(fittedPoint.x, fittedPoint.y); await page.waitForTimeout(1000);
      for (const viewport of [{width:390,height:844}, {width:1440,height:900}, size]) {
        await page.setViewportSize(viewport); await page.waitForTimeout(800);
        await bounds();
        await page.screenshot({path:`${directory}/resize-${viewport.width}x${viewport.height}.jpg`});
      }
      assert.deepEqual(errors, [], 'no JavaScript exceptions');
      assert.equal(consoleErrors.filter(x=>/Uncaught|Exception|RenderFlex|assertion/i.test(x)).length, 0, 'no Flutter or rendering exceptions');
      assert.deepEqual(blocked, [], 'no unexpected external resources');
      const later = requests.slice(initialRequests);
      assert.ok(later.every(r => r.method === 'GET' && r.path === '/api/v1/rpc-latency'),
        'only the independent node status indicator may poll while using the log');
      assert.ok(later.length <= 1 + Math.floor((Date.now() - startedAt) / 5000),
        'opening or dragging the log must not trigger extra node polls');
      assert.equal(requests.filter(r=>/transactions|bundles/.test(r.path)).length, 0, 'no broadcast endpoints');
      await rm(`${directory}/failure.jpg`, {force:true});
      await writeFile(`${directory}/results.json`, JSON.stringify({passed:true, size, phases, errors, consoleErrors, requests, initialRequests, blocked}, null, 2));
    } catch (error) {
      await page.screenshot({path:`${directory}/failure.jpg`}).catch(() => {});
      await writeFile(`${directory}/results.json`, JSON.stringify({passed:false, error:String(error), phases, errors, consoleErrors, requests, initialRequests, blocked}, null, 2));
      throw error;
    } finally {
      await cdp.send('Page.stopScreencast').catch(() => {});
      await context.close(); await browser.close();
      await writeFile(`${directory}/index.html`, `<!doctype html><meta charset="utf-8"><title>Liquid log ${size.width}×${size.height}</title><style>body{font:14px system-ui;background:#fff;margin:24px;color:#111}img{max-width:100%}section{margin:24px 0}a{color:#e64b00}</style><h1>日志形变 ${size.width}×${size.height}</h1><p>CDP 实时捕获：展开/收起中间帧、快速反向、底部让位。精确时间见各阶段 frames.json。</p>${phases.map(p=>`<section><h2>${p.name} · ${p.frameCount} 帧</h2>${p.contactSheet?`<a href="${p.name}/contact-sheet.jpg"><img src="${p.name}/contact-sheet.jpg"></a>`:''}<p><a href="${p.name}/frames.json">帧时间与 SHA-256</a></p></section>`).join('')}`);
    }
  });
}

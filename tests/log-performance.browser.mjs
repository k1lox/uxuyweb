import assert from 'node:assert/strict';
import {chromium} from 'playwright';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';

const tag = process.argv[2] || 'before';
assert.ok(['before','after','after-final'].includes(tag));
const base = 'http://127.0.0.1:3190/';
const output = {tag, recordedAt:new Date().toISOString(), methodology:'Headless Chromium; no video/screencast/screenshots. rAF measures main-thread frame-callback cadence, not guaranteed GPU presentation. CDP timeline and CPU sampling enabled identically before/after. Each case has a fresh browser context; cold means first log toggle after app readiness. Accessibility readiness is not counted as a frame. first450ms is a shared active-window comparison; full-observation DrawFrame gaps can include idle time after settling.', cases:[]};
const percentile = (values, p) => values.length ? [...values].sort((a,b)=>a-b)[Math.min(values.length-1, Math.floor(values.length*p))] : 0;
const rounded = v => Math.round(v*100)/100;
const sum = values => values.reduce((a,b)=>a+b,0);
await mkdir('test-results/log-performance', {recursive:true});
const build = await readFile('frontend/web/build/web/main.dart.js');
output.buildSha256 = createHash('sha256').update(build).digest('hex');

function summarize(action, longTasks) {
  const start = action.input ?? action.start;
  const frames = action.frames.filter(f=>f.now>=start);
  const gaps = frames.slice(1).map((f,i)=>f.now-frames[i].now);
  const tasks = longTasks.filter(t=>t.start<action.end && t.start+t.duration>start);
  const early=frames.filter(f=>f.now-start<=450), earlyGaps=early.slice(1).map((f,i)=>f.now-early[i].now);
  return {name:action.name, inputObserved:action.input!=null, observationMs:rounded(action.end-start), frameCallbacks:frames.length,
    rafMedianMs:rounded(percentile(gaps,.5)), rafP95Ms:rounded(percentile(gaps,.95)), rafMaxGapMs:rounded(Math.max(0,...gaps)),
    gapsOver33ms:gaps.filter(x=>x>33.4).length, gapsOver50ms:gaps.filter(x=>x>50).length,
    firstRafAfterInputMs:frames.length?rounded(frames[0].now-start):null,
    first450ms:{frameCallbacks:early.length,p95Ms:rounded(percentile(earlyGaps,.95)),maxGapMs:rounded(Math.max(0,...earlyGaps)),gapsOver33ms:earlyGaps.filter(x=>x>33.4).length,gapsOver50ms:earlyGaps.filter(x=>x>50).length},
    longTasks:tasks.map(t=>({startAfterInputMs:rounded(t.start-start),durationMs:rounded(t.duration)})),
    longTaskTotalMs:rounded(sum(tasks.map(t=>t.duration))), raf:frames.map(f=>[rounded(f.now-start),rounded(f.ts-start)])};
}
function traceSummary(trace) {
  const events=trace.traceEvents, threads=new Map();
  for (const e of events) if(e.ph==='M'&&e.name==='thread_name') threads.set(`${e.pid}:${e.tid}`, e.args.name);
  const marks=events.filter(e=>e.name?.startsWith('motion:')&&e.name.endsWith(':begin'));
  return marks.map(mark=>{
    const name=mark.name.slice(7,-6), end=events.find(e=>e.name===`motion:${name}:end`&&e.ts>=mark.ts)?.ts;
    const grouped=new Map(), long=[];
    for(const e of events) {
      if(!end||e.ts<mark.ts||e.ts>end) continue;
      if(e.ph==='X'&&e.dur>0) {
        const thread=threads.get(`${e.pid}:${e.tid}`)||`${e.pid}:${e.tid}`;
        const key=`${thread} | ${e.name}`, old=grouped.get(key)||{thread,name:e.name,count:0,inclusiveMs:0,maxMs:0};
        old.count++;old.inclusiveMs+=e.dur/1000;old.maxMs=Math.max(old.maxMs,e.dur/1000);grouped.set(key,old);
        if(e.dur>=50000) long.push({thread,name:e.name,ms:rounded(e.dur/1000),afterStartMs:rounded((e.ts-mark.ts)/1000),detail:e.args?.data});
      }
    }
    const draw=events.filter(e=>e.name==='DrawFrame'&&e.ts>=mark.ts&&e.ts<=end).map(e=>e.ts/1000);
    const activeDraw=draw.filter(t=>t<=mark.ts/1000+450);
    return {name, drawFramesFirst450ms:{count:activeDraw.length,maxGapMs:rounded(Math.max(0,...activeDraw.slice(1).map((t,i)=>t-activeDraw[i])))}, topInclusiveEvents:[...grouped.values()].sort((a,b)=>b.inclusiveMs-a.inclusiveMs).slice(0,12).map(e=>({...e,inclusiveMs:rounded(e.inclusiveMs),maxMs:rounded(e.maxMs)})),longEvents:long.sort((a,b)=>b.ms-a.ms).slice(0,12), compositorDrawFrameEvents:draw.length, compositorDrawFrameMaxGapMs:rounded(Math.max(0,...draw.slice(1).map((t,i)=>t-draw[i])))};
  });
}
function cpuSummary(profile) {
  const nodes=new Map(profile.nodes.map(n=>[n.id,n])), groups=new Map();
  for(let i=0;i<(profile.samples||[]).length;i++) {
    const frame=nodes.get(profile.samples[i])?.callFrame;if(!frame)continue;
    const key=`${frame.url||'<runtime>'} | ${frame.functionName||'<anonymous>'}`;
    groups.set(key,(groups.get(key)||0)+(profile.timeDeltas?.[i]||1000)/1000);
  }
  return [...groups].sort((a,b)=>b[1]-a[1]).slice(0,18).map(([functionName,sampledMs])=>({functionName,sampledMs:rounded(sampledMs)}));
}

for (const size of [{width:1440,height:900},{width:390,height:844}]) for (const semantics of [true,false]) {
  const name=`${tag}-${size.width}-${semantics?'semantics':'canvas'}`;
  const browser=await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
  const context=await browser.newContext({viewport:size,deviceScaleFactor:1,reducedMotion:'no-preference'});
  const page=await context.newPage(), requests=[], blocked=[], errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  await context.route('**/*',async route=>{
    const url=new URL(route.request().url()),path=url.pathname;
    if(!path.startsWith('/api/')) {
      if(url.origin===new URL(base).origin)return route.continue();
      blocked.push(url.href);return route.fulfill({status:204,body:''});
    }
    requests.push(path);let body={ok:false,code:'MOCK_ONLY',message:'performance fixture'};
    if(path==='/api/v1/config')body={ok:true,chainId:56,router:'0x00000000000000000000000000000000000c0de1',routeSource:'uxuy', routeEnabled:true, approvalSpender:'0x00000000000000000000000000000000000c0de2',maxPriceImpactPercent:7};
    if(path==='/api/fourmeme')body={ok:true,payload:{code:0,data:[]}};
    if(path==='/api/flap')body={ok:true,payload:{tokens:[]}};
    return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(body)});
  });
  const cdp=await context.newCDPSession(page);
  try {
    await page.goto(base,{waitUntil:'networkidle'});
    await page.waitForFunction(()=>!document.querySelector('#loading'),null,{timeout:60000});
    if(semantics) {
      await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
      await page.getByRole('button',{name:/^打开日志/}).waitFor();
    } else await page.locator('canvas').first().waitFor({state:'attached'});
    await page.waitForTimeout(250);
    const initialRequests=requests.length;
    await page.evaluate(()=>{
      const probe={actions:[],longTasks:[],current:null};
      const observer=new PerformanceObserver(list=>{for(const e of list.getEntries())probe.longTasks.push({start:e.startTime,duration:e.duration});});
      observer.observe({type:'longtask',buffered:false});
      const tick=ts=>{if(probe.current)probe.current.frames.push({ts,now:performance.now()});requestAnimationFrame(tick);};requestAnimationFrame(tick);
      addEventListener('pointerup',()=>{if(probe.current&&probe.current.name!=='idle'){probe.current.input=performance.now();performance.mark(`motion:${probe.current.name}:input`);}},{capture:true});
      probe.begin=name=>{probe.current={name,start:performance.now(),frames:[]};performance.mark(`motion:${name}:begin`);};
      probe.end=()=>{probe.current.end=performance.now();performance.mark(`motion:${probe.current.name}:end`);probe.actions.push(probe.current);probe.current=null;};
      window.__motionProbe=probe;
    });
    await cdp.send('Tracing.start',{categories:'devtools.timeline,blink.user_timing,v8,disabled-by-default-v8.gc,disabled-by-default-devtools.timeline.frame,cc',transferMode:'ReturnAsStream'});
    await cdp.send('Profiler.enable');await cdp.send('Profiler.setSamplingInterval',{interval:1000});await cdp.send('Profiler.start');
    await page.evaluate(()=>window.__motionProbe.begin('idle'));await page.waitForTimeout(500);await page.evaluate(()=>window.__motionProbe.end());
    const point={x:size.width-(size.width<584?12:20)-24,y:40};
    for(const action of ['cold-open','cold-close','warm1-open','warm1-close','warm2-open','warm2-close','warm3-open','warm3-close']) {
      await page.evaluate(name=>window.__motionProbe.begin(name),action);
      await page.mouse.click(point.x,point.y);await page.mouse.move(8,size.height/2);
      await page.waitForTimeout(1000);await page.evaluate(()=>window.__motionProbe.end());
    }
    const probe=await page.evaluate(()=>({actions:window.__motionProbe.actions,longTasks:window.__motionProbe.longTasks,semanticsNodes:document.querySelectorAll('flt-semantics').length}));
    const {profile}=await cdp.send('Profiler.stop');
    const completed=new Promise(resolve=>cdp.once('Tracing.tracingComplete',resolve));await cdp.send('Tracing.end');
    const {stream}=await completed;let raw='';
    while(true){const chunk=await cdp.send('IO.read',{handle:stream});raw+=chunk.data;if(chunk.eof)break;}
    await cdp.send('IO.close',{handle:stream});
    assert.deepEqual(errors,[]);assert.deepEqual(blocked,[]);assert.equal(requests.length,initialRequests);
    assert.equal(requests.filter(x=>/transactions|bundles/.test(x)).length,0);
    const trace=JSON.parse(raw);
    const result={name,size,semantics,semanticsNodes:probe.semanticsNodes,errors,blocked,requests,initialRequests,actions:probe.actions.map(a=>summarize(a,probe.longTasks)),trace:traceSummary(trace),topSampledFunctions:cpuSummary(profile),traceFile:`test-results/log-performance/${name}.trace.json.gz`,cpuProfileFile:`test-results/log-performance/${name}.cpuprofile.gz`};
    output.cases.push(result);
    await writeFile(result.traceFile,gzipSync(raw));await writeFile(result.cpuProfileFile,gzipSync(JSON.stringify(profile)));
    console.log(name, JSON.stringify(result.actions.map(a=>({action:a.name,p95:a.rafP95Ms,max:a.rafMaxGapMs,over50:a.gapsOver50ms,longMs:a.longTaskTotalMs}))));
  } finally {await context.close();await browser.close();}
  await writeFile(`test-results/log-motion-${tag}.json`,JSON.stringify(output,null,2));
}

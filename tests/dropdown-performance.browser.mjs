import {chromium} from 'playwright';
import {mkdir, writeFile} from 'node:fs/promises';
import {dirname} from 'node:path';

// Isolated fixture only. Run after a build; no RPC or live transaction request.
const browser = await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
const page=await browser.newPage({viewport:{width:1440,height:1000}});
const requests=[];
const fontRequests=[],externalRequests=[];
page.on('request',request=>{
  const url=new URL(request.url());
  if(!['http:','https:'].includes(url.protocol))return;
  const record={origin:url.origin,path:url.pathname};
  if(/\.(?:ttf|otf|woff2?)(?:$|\?)/i.test(url.pathname)||/fonts\.(?:gstatic|googleapis)\.com/.test(url.hostname))fontRequests.push(record);
  if(url.origin!=='http://127.0.0.1:3190')externalRequests.push(record);
});
// No external font or runtime fallback is permitted in this verification.
// The API-specific route registered below still supplies its local fixture.
await page.route('**/*',route=>{
  const url=new URL(route.request().url());
  return url.origin==='http://127.0.0.1:3190' ? route.continue() : route.abort('blockedbyclient');
});
await page.addInitScript(()=>{
  window.__longTasks=[];
  new PerformanceObserver(list=>{
    for(const e of list.getEntries())window.__longTasks.push({start:e.startTime,duration:e.duration});
  }).observe({type:'longtask',buffered:true});
});
await page.route('**/api/**',async route=>{
  const req=route.request(),path=new URL(req.url()).pathname;
  requests.push({path,time:Date.now()});
  let body={ok:false,code:'FIXTURE_ONLY',message:'Fixture only'};
  if(path==='/api/v1/config')body={ok:true,chainId:56,router:'0x00000000000000000000000000000000000c0de1',routeSource:'uxuy', routeEnabled:true, approvalSpender:'0x00000000000000000000000000000000000c0de2',maxPriceImpactPercent:7};
  if(path==='/api/fourmeme')body={ok:true,payload:{code:0,data:['BNB','BNCB','NVDAB','SPCXB','USDT','USD1','UUSD','QQQB','GMEB','FLNCB','DJTB','MRNAB','HOODB','PPOLY'].map((symbol,i)=>({status:'PUBLISH',symbol,nativeSymbol:symbol,symbolAddress:i===0?'0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c':'0x'+(i+100).toString(16).padStart(40,'0'),totalBAmount:'18',totalAmount:1000000000,saleRate:.8}))}};
  if(path==='/api/flap')body={ok:true,payload:{tokens:[]}};
  await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(body)});
});
try{
  await page.goto('http://127.0.0.1:3190/',{waitUntil:'networkidle'});
  await page.waitForFunction(()=>!document.querySelector('#loading'));
  await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
  const pool=page.getByRole('button',{name:/^底池代币/});
  await pool.waitFor();
  const startup=[...requests],samples=[];
  for(let i=0;i<3;i++){
    const n=requests.length;
    const before=await page.evaluate(()=>performance.now());
    const bb=await pool.boundingBox();
    await page.mouse.click(bb.x+20,bb.y+bb.height/2);
    await page.getByRole('textbox',{name:'搜索',exact:true}).waitFor();
    const semantics=await page.evaluate(()=>performance.now());
    await page.waitForTimeout(600);
    samples.push({semanticsReadyMs:semantics-before,newRequests:requests.slice(n),longTasks:await page.evaluate(s=>window.__longTasks.filter(e=>e.start>=s),before)});
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
  }
  const result={measurement:'Menu semantic availability, not painted-animation completion; cold first sample then two warm opens, API fully mocked',startup,samples,fontRequests,externalRequests};
  const output = process.argv[2] || 'test-results/dropdown.json';
  await mkdir(dirname(output), {recursive:true});
  await writeFile(output,JSON.stringify(result,null,2));
  console.log(JSON.stringify(result,null,2));
  if(samples.some(s=>s.newRequests.length))throw Error('Dropdown opening unexpectedly fetched data');
}finally{await browser.close();}

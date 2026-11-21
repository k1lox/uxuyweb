import {test} from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
const factory='0x889C64Ba9fe1A0E371EDe0579098E0bd71135232';
const zero='0x0000000000000000000000000000000000000000';
const fixture=JSON.parse(await readFile(new URL('./fixtures/flap-vault-rpc.json',import.meta.url),'utf8'));

test('Flap standard custom Vault: nine parameters, compact picker, desktop/mobile; no signing', {timeout:120000},async()=>{
 const browser=await chromium.launch({channel: 'chrome', executablePath: process.env.CHROME_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1440,height:1100},deviceScaleFactor:1});
 const errors=[],requests=[],rpcCalls=[];
 page.on('pageerror',error=>errors.push(String(error)));
 page.setDefaultTimeout(10000);
 const folder='test-results/flap-vault';
 await mkdir(folder,{recursive:true});
 await page.route('**/api/**',async route=>{
  const req=route.request(),path=new URL(req.url()).pathname; requests.push(path);
  let body={ok:false,code:'MOCK_ONLY',message:'模拟接口未实现'};
  if(path==='/api/v1/config') body={ok:true,chainId:56,router:'0x00000000000000000000000000000000000c0de1',routeSource:'uxuy', routeEnabled:true, approvalSpender:'0x00000000000000000000000000000000000c0de2',maxPriceImpactPercent:7};
  if(path==='/api/fourmeme') body={ok:true,payload:{code:0,data:[]}};
  if(path==='/api/flap') body={ok:true,payload:{tokens:[{address:zero,symbol:'BNB',name:'BNB',decimals:18,r:'10',k:'10',h:'0'}]}};
  if(path==='/api/v1/rpc/bsc') body=JSON.parse(req.postData()).map(call=>{
   rpcCalls.push(call.method);
   if(call.method==='eth_getCode') return {jsonrpc:'2.0',id:call.id,result:'0x6000'};
   if(call.method==='eth_call') {
    const key=`${call.params[0].to.toLowerCase()}:${call.params[0].data.toLowerCase()}`;
    return fixture[key] ? {jsonrpc:'2.0',id:call.id,result:fixture[key]} : {jsonrpc:'2.0',id:call.id,error:{code:-32000,message:'execution reverted'}};
   }
   return {jsonrpc:'2.0',id:call.id,error:{code:-32601,message:'Read-only mock'}};
  });
  await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(body)});
 });
 const screenshot=async(name)=>{await page.waitForTimeout(250); await page.screenshot({path:`${folder}/${name}.png`});};
 try {
  await page.goto(process.env.UXUY_TEST_URL || 'http://127.0.0.1:3190/',{waitUntil:'networkidle'});
  await page.waitForFunction(()=>!document.querySelector('#loading'),null,{timeout:60000});
  await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
  await page.getByRole('button',{name:'Flap',exact:true}).click();
  const enabled=page.getByRole('switch').first();
  await enabled.scrollIntoViewIfNeeded();await enabled.click();
  await page.getByRole('button',{name:'自定义 Factory',exact:true}).click();
  const address=page.getByRole('textbox',{name:'Factory 地址，非金库实例地址',exact:true});
  await address.click();await page.waitForTimeout(100);await page.keyboard.type(factory);
  await page.mouse.move(700,800);await page.mouse.wheel(0,650);await page.waitForTimeout(300);
  await page.getByRole('button',{name:'读取金库参数',exact:true}).click();
  await page.getByRole('button',{name:'刷新参数',exact:true}).waitFor();
  const details=page.getByRole('button',{name:'金库要求与说明',exact:true});
  const renderedFields=[];
  await page.mouse.move(700,800);
  for (let step=0;step<12;step++) {
   renderedFields.push(await page.locator('body').evaluate(e=>e.outerHTML));
   if (await details.count()) break;
   await page.mouse.wheel(0,280);
   await page.waitForTimeout(120);
  }
  await details.scrollIntoViewIfNeeded();
  const semantics=renderedFields.join('\n');
  for(const text of ['Creator share (bps)','Buyback-burn share (bps)','Third-party burn share (bps)','Fission share (bps)','Spend per round','Fission addresses per round']) assert.ok(semantics.includes(text),`missing standard field ${text}`);
  assert.ok(!semantics.includes('金库格式有误'));
  await page.mouse.click(936,805);await page.mouse.move(700,800);await page.mouse.wheel(0,430);await page.waitForTimeout(250);
  await screenshot('vault-custom-desktop');
  await page.setViewportSize({width:390,height:844});
  await page.waitForTimeout(250);
  await page.getByRole('button',{name:'自定义 Factory',exact:true}).scrollIntoViewIfNeeded();
  await screenshot('vault-custom-mobile');
  const fields=await page.getByRole('textbox').evaluateAll(es=>es.map(e=>e.getBoundingClientRect().toJSON()));
  assert.ok(fields.every(r=>r.width<=390),'fields must not overflow mobile width');
  await page.setViewportSize({width:1440,height:1100});
  await page.getByRole('button',{name:'精选金库',exact:true}).click();
  const picker=page.getByRole('button',{name:/^精选金库.*请选择/s});
  await picker.click();
  const search=page.getByRole('textbox',{name:'搜索',exact:true});
  await search.waitFor();
  const trigger=await picker.boundingBox(),menu=await search.boundingBox();
  assert.ok(menu.width<=360 && Math.abs(menu.x-trigger.x)<24,'Vault picker should be compact and anchored');
  await screenshot('vault-curated-picker');
  await page.keyboard.press('Escape');
  await page.setViewportSize({width:390,height:844});
  await page.reload({waitUntil:'networkidle'});
  await page.waitForFunction(()=>!document.querySelector('#loading'),null,{timeout:60000});
  if(await page.locator('flt-semantics-placeholder').count()) await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
  await page.getByRole('button',{name:'Flap',exact:true}).click();
  await page.mouse.move(220,650);await page.mouse.wheel(0,750);await page.waitForTimeout(250);
  await page.getByRole('switch').first().click();
  await page.getByRole('button',{name:'自定义 Factory',exact:true}).click();
  await page.mouse.wheel(0,250);await page.waitForTimeout(250);
  const mobileFactory=page.getByRole('textbox',{name:'Factory 地址，非金库实例地址',exact:true});
  await mobileFactory.click();await page.waitForTimeout(100);await page.keyboard.type(factory);
  await page.getByRole('button',{name:'读取金库参数',exact:true}).click();
  await page.getByRole('button',{name:'刷新参数',exact:true}).waitFor();
  await page.mouse.click(375,600);
  await screenshot('vault-custom-mobile-fresh');
  await writeFile(`${folder}/vault-mobile-inputs.json`,JSON.stringify(await page.getByRole('textbox').evaluateAll(es=>es.map(e=>({value:e.value,rect:e.getBoundingClientRect().toJSON()}))),null,2));
  assert.deepEqual(errors,[]);
  assert.ok(rpcCalls.every(method=>['eth_getCode','eth_call'].includes(method)));
  assert.equal(requests.filter(path=>/transactions|bundles/.test(path)).length,0);
  await writeFile(`${folder}/vault-browser-results.json`,JSON.stringify({passed:true,errors,requests,rpcCalls,broadcasts:0,screenshots:['vault-custom-desktop.png','vault-custom-mobile.png','vault-custom-mobile-fresh.png','vault-curated-picker.png']},null,2));
 }catch(error){await writeFile(`${folder}/vault-custom-browser-failure.json`,JSON.stringify({errors,requests,rpcCalls},null,2));await screenshot('vault-browser-failure');await writeFile(`${folder}/vault-browser-failure.html`,await page.locator('body').evaluate(e=>e.outerHTML));throw error;}
 finally{await browser.close();}
});

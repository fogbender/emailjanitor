import {chromium} from 'playwright-core';
import assert from 'node:assert/strict';
const base = `https://localhost:${process.env.JANITOR_BROWSER_PORT}`;
const artifacts = process.env.JANITOR_BROWSER_ARTIFACT_DIR;
const browser = await chromium.launch({headless:true, executablePath:process.env.JANITOR_BROWSER_EXECUTABLE,
  args:['--disable-background-networking','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1']});
let page;
try {
  const context=await browser.newContext({ignoreHTTPSErrors:true,timezoneId:'America/Los_Angeles',viewport:{width:1280,height:1000}});
  page=await context.newPage();
  const errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await context.route('**/*',async route=>{
    if(new URL(route.request().url()).origin===base) await route.continue();
    else {errors.push('Unexpected external request'); await route.abort('blockedbyclient');}
  });
  await page.route(`${base}/auth/google`,async route=>{
    const response=await route.fetch({maxRedirects:0});
    assert.equal(response.status(),302);
    assert.match(response.headers().location,/^https:\/\/accounts.google.com\//);
    await route.fulfill({response,status:303,headers:{...response.headers(),location:`${base}/auth/google/callback?code=valid&state=${'r'.repeat(32)}`}});
  });
  await page.goto(base);
  await page.getByRole('heading',{name:/Good email stays/}).waitFor();
  assert.equal(await page.locator('input[name=timezone]').inputValue(),'America/Los_Angeles');
  await page.screenshot({path:`${artifacts}/home-desktop.png`,fullPage:true});
  await page.getByRole('button',{name:'Sign in with Google',exact:true}).click();
  await page.waitForURL('**/accounts');
  await page.getByRole('button',{name:'Connect Google account',exact:true}).click();
  await page.waitForURL('**/accounts');
  await page.getByText('owner@acme.com',{exact:true}).waitFor();
  assert.match(await page.locator('main').innerText(),/America\/Los_Angeles/);
  assert.equal(await page.getByRole('link',{name:'Billing',exact:true}).count(),0);
  const cookie=(await context.cookies()).find(c=>c.name==='__Host-emailjanitor-selfhost');
  assert.ok(cookie.secure&&cookie.httpOnly);
  await page.getByRole('link',{name:'Chat',exact:true}).click();
  assert.equal(await page.getByLabel('Inbox').inputValue(),'browser-inbox');
  await page.getByLabel('Your message').fill('BROWSER_EMAIL_BODY_SENTINEL: Keep invoices.');
  await page.getByRole('button',{name:'Send to Janitor',exact:true}).click();
  await page.getByRole('status').waitFor();
  const originalId=await page.locator('form[action="/chat"] input[name="request_id"]').inputValue();
  const retryText='BROWSER_EMAIL_BODY_SENTINEL: retry <script>private & "text"</script>';
  await page.getByLabel('Your message').fill(retryText);
  await page.getByRole('button',{name:'Send to Janitor',exact:true}).click();
  await page.getByRole('button',{name:'Retry that message',exact:true}).waitFor();
  const retry=page.locator('form[action="/chat"]').filter({has:page.getByRole('button',{name:'Retry that message',exact:true})});
  const fresh=page.locator('form[action="/chat"]').filter({has:page.getByRole('button',{name:'Send to Janitor',exact:true})});
  assert.equal(await retry.locator('input[name=request_id]').inputValue(),originalId);
  assert.equal(await retry.locator('input[name=message]').inputValue(),retryText);
  assert.notEqual(await fresh.locator('input[name=request_id]').inputValue(),originalId);
  assert.equal(await page.getByLabel('Your message').inputValue(),'');
  assert.doesNotMatch(await page.locator('body').innerText(),/BROWSER_EMAIL_BODY_SENTINEL/);
  await page.getByRole('button',{name:'Retry that message',exact:true}).click();
  await page.getByRole('status').waitFor();
  const csrf=await page.locator('input[name=_csrf_token]').first().inputValue();
  const forged=await context.request.post(`${base}/chat`,{form:{_csrf_token:csrf,request_id:crypto.randomUUID(),inbox_id:'foreign-inbox',message:'BROWSER_EMAIL_BODY_SENTINEL: foreign'}});
  assert.equal(forged.status(),400);
  const noCsrf=await context.request.post(`${base}/logout`,{form:{}});
  assert.equal(noCsrf.status(),403);
  await page.setViewportSize({width:390,height:844});
  await page.getByRole('link',{name:'Accounts',exact:true}).click();
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true);
  await page.screenshot({path:`${artifacts}/accounts-mobile.png`,fullPage:true});
  const replay=await browser.newContext({ignoreHTTPSErrors:true});
  await replay.addCookies([cookie]);
  assert.equal((await replay.request.get(`${base}/accounts`,{maxRedirects:0})).status(),200);
  await page.getByRole('button',{name:'Disconnect',exact:true}).click();
  await page.waitForURL('**/accounts');
  await page.getByRole('button',{name:'Disconnect',exact:true}).waitFor({state:'detached'});
  await page.getByRole('button',{name:'Sign out',exact:true}).click();
  await page.waitForURL(`${base}/`);
  assert.equal((await replay.request.get(`${base}/accounts`,{maxRedirects:0})).status(),302);
  await replay.close();
  assert.deepEqual(errors,[]);
  console.log('PASS: HTTPS desktop/mobile, timezone, owner sign-in, account connection, secure sessions, transient chat, original retry/new UUIDs, forged inbox, CSRF, disconnect, logout/replay, no overflow or page errors.');
} catch(error) {
  await page?.screenshot({path:`${artifacts}/failure.png`,fullPage:true});
  throw error;
} finally {await browser.close();}

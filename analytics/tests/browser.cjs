// Optional browser checks. Runtime analytics has no Node dependencies.
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const {once} = require('node:events');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const fixture = `
import tempfile
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from http.server import HTTPServer
from analytics.data import Warehouse
from analytics.server import handler_for
from analytics.tests.test_analytics import t3_fixture
with tempfile.TemporaryDirectory() as directory:
    root=Path(directory)
    t3_fixture(root)
    with sqlite3.connect(root / 'statev2.sqlite') as db:
        db.execute('CREATE TABLE projection_projects(project_id,title,workspace_root)')
        db.execute("INSERT INTO projection_projects VALUES('project','Synthetic project','/example')")
    with sqlite3.connect(root / 'state_5.sqlite') as db:
        db.execute('CREATE TABLE threads(id,title,model,model_provider,created_at,updated_at,tokens_used,cwd)')
        db.executemany('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)',[
          ('native','Native copy','test-model','openai',1,datetime.now(timezone.utc).timestamp(),500,'/example'),
          ('independent','Independent conversation','second-model','other-provider',1,datetime.now(timezone.utc).timestamp(),900,'/other-project')])
    warehouse=Warehouse(paths={'t3':root,'codex':root})
    server=HTTPServer(('127.0.0.1',0),handler_for(warehouse))
    print(server.server_port,flush=True)
    server.serve_forever()
`;

(async () => {
  const server = spawn('python3',['-u','-c',fixture], {cwd:path.join(__dirname,'../..'),stdio:['ignore','pipe','inherit']});
  let browser;
  try {
    const [port] = await Promise.race([once(server.stdout,'data'), once(server,'exit').then(() => {throw new Error('Fixture server exited');})]);
    const origin = `http://127.0.0.1:${String(port).trim()}`;
    browser = await chromium.launch({headless:true});
    const page = await browser.newPage({viewport:{width:1440,height:1000}});
    const errors=[], violations=[], external=[];
    page.on('pageerror',(e) => errors.push(e.message));
    page.on('console',(m) => {if (m.text().includes('Content Security Policy')) violations.push(m.text());});
    page.on('request',(r) => {if (!r.url().startsWith(origin)) external.push(r.url());});
    const go = async (view) => {
      await page.locator(`.viewnav [data-view="${view}"]`).click();
      await page.waitForFunction((v) => document.body.dataset.view===v && !document.getElementById(v).hidden, view);
    };
    const shot = async (name) => {if (process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`${name}.png`)});};
    await page.goto(origin);
    await page.waitForFunction(() => document.querySelector('#source').options.length > 0);
    await go('overview');
    await page.selectOption('#range','0');
    await page.waitForFunction(() => document.querySelectorAll('#top-table tbody tr').length===3);
    assert.equal(await page.locator('#source').inputValue(),'all');
    assert.ok((await page.locator('#selection-summary').textContent()).includes('1 exact source copies grouped'));
    await page.locator('#merge-copies').uncheck();
    await page.waitForFunction(() => document.querySelectorAll('#top-table tbody tr').length===4);
    await page.locator('#merge-copies').check();
    await page.waitForFunction(() => document.querySelectorAll('#top-table tbody tr').length===3);
    assert.ok(await page.locator('.plot-column').count()>0);
    assert.ok(await page.locator('.bar-input').evaluateAll((bars) => bars.some((bar) => bar.getBoundingClientRect().height>0)));
    if (process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,'overview.png'),fullPage:true});
    await page.locator('tr[data-id="t3:main"]').first().click();
    await page.waitForSelector('#detail .detail-heading');
    assert.equal(await page.locator('#detail .message').count(),2);
    assert.equal(await page.locator('#detail script').count(),0);
    assert.ok((await page.locator('#detail-content').textContent()).includes('<script>unsafe()</script>'));
    assert.ok(!(await page.locator('#detail-content').textContent()).includes('private tool output'));
    await page.locator('#close-detail').click();
    await page.locator('#search').fill('testing');
    await page.waitForFunction(() => document.querySelectorAll('#top-table tbody tr').length===1);
    await page.locator('#search').fill('');
    await go('queries');
    await page.locator('#run-query').click();
    await page.waitForFunction(() => document.querySelector('#result-count').textContent.includes('rows'));
    assert.ok(await page.locator('#query-table tbody tr').count()>0);
    const download = page.waitForEvent('download');
    await page.locator('#export').click();
    assert.equal((await download).suggestedFilename(),'session-monitor-analytics.csv');
    await page.locator('#sql').fill('SELECT count(*) AS selected FROM chats');
    await page.locator('#run-query').click();
    await page.waitForFunction(() => document.querySelector('#query-table tbody td')?.textContent==='3');
    await page.selectOption('#model','second-model');
    await page.waitForFunction(() => document.querySelector('#query-table tbody td')?.textContent==='1');
    for (const view of ['overview','chats','connections','explorer','constellation']) {
      await go(view);
      assert.equal(await page.locator('#filters').isVisible(),true);
      assert.equal(await page.locator('.viewnav').isVisible(),true);
      assert.equal(await page.locator(`.viewnav [data-view="${view}"]`).getAttribute('aria-current'),'page');
      assert.equal(await page.locator('.viewnav [aria-current]').count(),1);
      assert.equal(new URL(page.url()).hash,`#/${view}`);
      assert.equal(await page.locator('#model').inputValue(),'second-model');
      assert.ok((await page.locator('#selection-summary').textContent()).includes('1 conversations'));
    }
    await page.waitForSelector('.constellation-directory');
    assert.equal(await page.locator('.constellation-chat').count(),1);
    await go('explorer');
    await page.waitForSelector('.ae-chart svg');
    assert.ok((await page.locator('.ae-caption').textContent()).includes('lifetime'));
    await page.selectOption('#provider','openai');
    await page.waitForFunction(() => document.querySelector('#selection-summary').textContent.startsWith('0 conversations'));
    assert.ok((await page.locator('#explorer-content').textContent()).includes('No conversations'));
    await page.selectOption('#provider','');
    await page.selectOption('#model','');
    await page.waitForFunction(() => document.querySelector('#selection-summary').textContent.startsWith('3 conversations'));
    await page.getByRole('button',{name:'Conversation map',exact:true}).click();
    assert.ok(await page.locator('.ae-chart circle').count()>0);
    await page.getByRole('button',{name:'Activity calendar',exact:true}).click();
    assert.ok(await page.locator('.ae-chart svg').count()>0);
    if (process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,'explorer.png'),fullPage:true});
    await go('constellation');
    await page.waitForSelector('.constellation-directory');
    assert.equal(await page.locator('.constellation-chat').count(),3);
    await page.locator('.constellation-directory summary').click();
    await page.locator('.constellation-chat').first().click();
    await page.waitForSelector('#detail .detail-heading');
    await page.locator('#close-detail').click();
    if (process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,'constellation.png'),fullPage:true});
    await go('queries');
    await page.locator('#sql').fill('DELETE FROM chats');
    await page.locator('#run-query').click();
    await page.waitForFunction(() => !document.querySelector('#error').hidden);
    assert.equal(await page.locator('#result-count').textContent(),'Query failed');
    await go('connections');
    assert.equal(await page.locator('.connection').count(),2);
    await page.selectOption('#source','codex');
    await page.waitForFunction(() => document.querySelectorAll('.connection').length===1);
    assert.equal(await page.locator('#filters').isVisible(),true);
    await page.selectOption('#source','all');
    await page.waitForFunction(() => document.querySelectorAll('.connection').length===2);
    await go('overview');
    await page.locator('#refresh').click();
    await page.waitForFunction(() => !document.querySelector('#refresh').disabled);
    assert.equal(await page.locator('#error').isVisible(),false);
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth>innerWidth),false);
    if (process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,'mobile.png'),fullPage:true});
    for (const view of ['explorer','constellation','queries']) {
      await go(view);
      if(view==='constellation') await page.waitForSelector('.constellation-directory');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth>innerWidth),false);
    }
    await page.setViewportSize({width:1440,height:1000});
    await go('atlas');
    await page.waitForSelector('.pa-graph-node');
    assert.equal(await page.locator('.viewnav').isVisible(),true);
    assert.equal(await page.locator('#filters').isVisible(),true);
    const canvasBox = await page.locator('#atlas-content').boundingBox();
    assert.ok(canvasBox.width>1300 && canvasBox.y+canvasBox.height<=1000+1,'Atlas fills the workspace without page scrolling');
    assert.ok(await page.locator('.pa-network-link').count()>0);
    await shot('desktop-atlas-network');
    await page.getByRole('button',{name:'Chord flows',exact:true}).click();
    assert.ok(await page.locator('.pa-chord-ribbon').count()>0);
    const arcPoint = await page.locator('.pa-chord-group path').first().evaluate((arc) => {
      const point=arc.getPointAtLength(arc.getTotalLength()*.25);
      const screen=new DOMPoint(point.x,point.y).matrixTransform(arc.getScreenCTM());
      return {x:screen.x,y:screen.y};
    });
    await page.mouse.click(arcPoint.x,arcPoint.y);
    await page.getByRole('button',{name:'Use project filter',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#project').value!=='');
    await go('queries');
    await page.locator('#sql').fill('SELECT count(*) AS selected FROM chats');
    await page.locator('#run-query').click();
    await page.waitForFunction(()=>document.querySelector('#result-count').textContent.includes('rows'));
    assert.ok(Number(await page.locator('#query-table tbody td').textContent())<3);
    await page.selectOption('#project','');
    await page.waitForFunction(()=>document.querySelector('#selection-summary').textContent.startsWith('3 conversations'));
    await go('lab');
    await page.waitForSelector('.cl-histogram-bar');
    assert.equal(await page.locator('.cl-metrics .cl-metric').count(),6);
    await page.getByRole('button',{name:'Prompt ↔ response',exact:true}).click();
    assert.ok(await page.locator('.cl-bubble').count()>0);
    await shot('desktop-lab-exchange');
    await page.locator('.cl-bubble').first().click();
    await page.waitForSelector('#detail .detail-heading');
    assert.ok((await page.locator('#detail-content').textContent()).includes('Recorded messages'));
    await page.locator('#close-detail').click();
    await page.getByRole('button',{name:'Compare projects',exact:true}).click();
    assert.ok(await page.locator('.cl-comparison-row').count()>0);
    await shot('desktop-lab-compare');
    // Collapsing filters is a presentation choice that survives view changes; the selection summary stays visible.
    await page.locator('#scope-toggle').click();
    assert.equal(await page.locator('#filters').isVisible(),false);
    assert.equal(await page.locator('#selection-summary').isVisible(),true);
    await go('overview');
    assert.equal(await page.locator('#filters').isVisible(),false);
    await go('lab');
    await page.locator('#scope-toggle').click();
    assert.equal(await page.locator('#filters').isVisible(),true);
    // Module presentation choices survive leaving and returning to a view.
    assert.equal(await page.locator('.cl-tabs button.active').textContent(),'Compare projects');
    await go('atlas');
    assert.equal(await page.locator('.pa-modes button.active').textContent(),'Chord flows');
    await shot('desktop-atlas-chord');
    await go('constellation');
    await page.waitForSelector('.constellation-heading select');
    await page.selectOption('.constellation-heading select','model');
    await go('overview');
    await go('constellation');
    await page.waitForSelector('.constellation-heading select');
    assert.equal(await page.locator('.constellation-heading select').inputValue(),'model');
    // Browser history and reload follow the view.
    await page.goBack();
    await page.waitForFunction(() => document.body.dataset.view==='overview');
    await page.goForward();
    await page.waitForFunction(() => document.body.dataset.view==='constellation');
    await page.keyboard.press('2');
    await page.waitForFunction(() => document.body.dataset.view==='lab');
    await page.reload();
    await page.waitForFunction(() => document.body.dataset.view==='lab' && document.querySelector('.cl-histogram-bar, .cl-comparison-row'));
    assert.equal(await page.locator('.viewnav [aria-current]').getAttribute('data-view'),'lab');
    await page.waitForFunction(() => document.querySelector('#selection-summary').textContent.startsWith('3 conversations'));
    for (const view of ['explorer','overview','chats','queries','connections']) {await go(view); await shot(`desktop-${view}`);}
    await go('constellation');
    await page.waitForSelector('.constellation-directory');
    await shot('desktop-constellation');
    await page.setViewportSize({width:390,height:844});
    for(const view of ['atlas','lab','constellation','overview']) {
      await go(view);
      if(view==='constellation') await page.waitForSelector('.constellation-directory');
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
      assert.equal(await page.locator('.viewnav').isVisible(),true);
      if (process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`mobile-${view}.png`),fullPage:true});
    }
    assert.deepEqual(errors,[]);
    assert.deepEqual(violations,[]);
    assert.deepEqual(external,[]);
    console.log('Browser checks passed: one navigation scheme with hash history and preserved presentation, full-window project atlas/chords, conversation laboratory, project/global filters, combined identities, scoped SQL, D3, Three.js/fallback, charts, detail, search, CSV, refresh, mobile, CSP, and local-only requests.');
  } finally {
    if (browser) await browser.close();
    server.kill('SIGTERM');
  }
})().catch((error) => {console.error(error);process.exitCode=1;});

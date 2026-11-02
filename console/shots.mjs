import { chromium } from '@playwright/test';
import { mkdirSync } from 'node:fs';
mkdirSync('/tmp/console-shots', { recursive: true });
const b = await chromium.launch();
const page = await (await b.newContext({ viewport: { width: 2048, height: 1152 } })).newPage();
await page.goto('http://127.0.0.1:7310/');
await page.locator('.gate').waitFor({ timeout: 10000 }).catch(() => {});
if (await page.locator('.gate').count()) {
  await page.locator('.gate-input').fill('visual-check');
  await page.getByRole('button', { name: '进入' }).click();
}
await page.locator('.page-head h2').first().waitFor({ timeout: 30000 });
await page.waitForTimeout(1500);
for (const [route, name] of [['/', '01-overview'], ['/agents', '02-agents'], ['/effective', '03-effective'], ['/instructions', '04-instructions'], ['/hooks', '05-hooks'], ['/services', '06-services'], ['/autopilots', '07-autopilots'], ['/migration', '08-migration'], ['/skills', '09-skills'], ['/projects', '10-projects'], ['/graph', '11-relation-graph']]) {
  await page.goto('http://127.0.0.1:7310' + route);
  await page.waitForTimeout(2500);
  await page.screenshot({ path: `/tmp/console-shots/${name}.png` });
  console.log('shot', name);
}
await b.close();

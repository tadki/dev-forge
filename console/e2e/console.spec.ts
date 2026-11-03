import { expect, test } from '@playwright/test';

const TOKEN = 'e2e-token-123';

async function login(page: import('@playwright/test').Page): Promise<void> {
  await page.goto('/');
  // 竞等：门（未认证）或数据页（token 已在 localStorage）——首轮 fetch 未完成前两者都可能出现
  await Promise.race([
    page.locator('.gate').waitFor({ timeout: 15_000 }),
    page.locator('.page-head h2').first().waitFor({ timeout: 15_000 }),
  ]);
  if (await page.locator('.gate').count()) {
    await page.locator('.gate-input').fill(TOKEN);
    await page.getByRole('button', { name: '进入' }).click();
    await page.locator('.page-head h2').first().waitFor({ timeout: 15_000 });
  }
}

test.beforeEach(async ({ page }) => {
  await login(page);
});

test('token gate: wrong token rejected, right token enters', async ({ page }) => {
  await page.context().clearCookies();
  await page.evaluate(() => localStorage.removeItem('forge_token'));
  await page.goto('/');
  await page.locator('.gate').waitFor({ timeout: 15_000 });
  await page.locator('.gate-input').fill('wrong-token');
  await page.getByRole('button', { name: '进入' }).click();
  await expect(page.getByText('令牌无效')).toBeVisible();
  await page.locator('.gate-input').fill(TOKEN);
  await page.getByRole('button', { name: '进入' }).click();
  await page.locator('.page-head h2').first().waitFor({ timeout: 15_000 });
  await expect(page.locator('.topbar')).toBeVisible();
});

test('overview: health banner, stats, activity, drift', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.banner-title').first()).toContainText('GREEN');
  await expect(page.locator('.stat').first()).toBeVisible();
  await expect(page.getByText('最近活动', { exact: false })).toBeVisible();
  await expect(page.getByText('deny', { exact: false }).first()).toBeVisible();
  await expect(page.getByText('漂移告警', { exact: false }).first()).toBeVisible();
  await expect(page.getByText('kol / CLAUDE.md')).toBeVisible();
});

test('nav: all 11 pages render with header', async ({ page }) => {
  const routes: Array<[string, string]> = [
    ['/projects', '项目'],
    ['/instructions', '指令库'],
    ['/skills', '技能'],
    ['/hooks', '钩子'],
    ['/agents', '智能体'],
    ['/services', '服务'],
    ['/autopilots', '巡逻'],
    ['/migration', '迁移'],
    ['/graph', '关系图'],
    ['/custom', '通用资产'],
    ['/effective', '有效 HARNESS'],
  ];
  for (const [route, head] of routes) {
    await page.goto(route);
    await expect(page.locator('.page-head h2'), `route ${route}`).toContainText(head, { timeout: 10_000 });
  }
});

test('agents: anatomy with instructions, gates, mcp', async ({ page }) => {
  await page.goto('/agents');
  await expect(page.getByText('AGENT 构成')).toBeVisible();
  await expect(page.locator('.card', { hasText: 'Fronti' })).toBeVisible();
  await page.locator('.card', { hasText: 'Fronti' }).click();
  await expect(page.getByText('agent-fronti[1m]').first()).toBeVisible();
  await expect(page.getByText('你是 KOL 的前端实现 agent', { exact: false })).toBeVisible();
  await expect(page.getByText('/code-review')).toBeVisible();
  await expect(page.getByText('hindsight').first()).toBeVisible();
  // 规则门控：Fronti 无 include 命中 → 0 条
  await expect(page.getByText('规则门控')).toBeVisible();
});

test('agents: revy shows gated rule', async ({ page }) => {
  await page.goto('/agents');
  await page.locator('.card', { hasText: 'Revy' }).click();
  await expect(page.getByText('revy-testing-skill-check')).toBeVisible();
});

test('instructions: tree, render, drift diff', async ({ page }) => {
  await page.goto('/instructions');
  await expect(page.getByText('作用域树').first()).toBeVisible();
  await expect(page.getByText('king-of-likes/CLAUDE.md').first()).toBeVisible();
  await expect(page.getByText('EffectManager').first()).toBeVisible(); // markdown 渲染
  await page.getByRole('button', { name: '源码' }).click();
  await expect(page.locator('pre.code').first()).toContainText('# 基础规范');
  // 漂移面板
  await expect(page.getByText('漂移对比').first()).toBeVisible();
  await expect(page.getByText('2 变体 / 2 副本', { exact: false })).toBeVisible();
});

test('hooks: pipeline, rules table, firelog', async ({ page }) => {
  await page.goto('/hooks');
  await expect(page.locator('.pipe-node').first()).toContainText('CC 9 挂载点');
  await expect(page.getByText('revy-testing-skill-check')).toBeVisible();
  await expect(page.getByText('DENY').first()).toBeVisible();
  await expect(page.getByText('FIRE LOG', { exact: false })).toBeVisible();
});

test('services: tree and detail', async ({ page }) => {
  await page.goto('/services');
  await expect(page.getByText('toolchain-start-all').first()).toBeVisible();
  await page.locator('tr', { hasText: 'toolchain-start-all' }).first().click();
  await expect(page.getByText('/bin/bash -l /home/jerry/tools/dev-forge/launch/toolchain-start.sh')).toBeVisible();
  await expect(page.getByText('#333').first()).toBeVisible();
});

test('autopilots: table with cron + triggers detail', async ({ page }) => {
  await page.goto('/autopilots');
  await expect(page.getByText('*/10 * * * *').first()).toBeVisible();
  await expect(page.getByText('Refacty').first()).toBeVisible();
  await expect(page.getByText('Asia/Hong_Kong').first()).toBeVisible();
});

test('skills: first-party vs dependencies tabs', async ({ page }) => {
  await page.goto('/skills');
  await expect(page.getByText('/recall').first()).toBeVisible();
  await expect(page.getByText('deep-research').first()).not.toBeVisible();
  await page.getByRole('button', { name: '依赖架 DEPENDENCIES' }).click();
  await expect(page.getByText('deep-research').first()).toBeVisible();
});

test('projects: matrix rows, harness badge, workspace grouping', async ({ page }) => {
  await page.goto('/projects');
  await expect(page.getByText('king-of-likes').first()).toBeVisible();
  await expect(page.getByText('CLAUDE', { exact: true }).first()).toBeVisible();
  await expect(page.getByText('King of Likes').first()).toBeVisible();
});

test('migration: coverage, gaps, export script', async ({ page }) => {
  await page.goto('/migration');
  await expect(page.locator('.num').first()).toBeVisible();
  await expect(page.getByText('可映').first()).toBeVisible();
  await expect(page.getByText('缺口与策略')).toBeVisible();
  await expect(page.getByText('#!/bin/bash')).toBeVisible();
  await expect(page.getByText('Fronti').first()).toBeVisible(); // instructions dry-run diff 区
});

test('graph: nodes render and inspector works', async ({ page }) => {
  await page.goto('/graph');
  await expect(page.locator('svg')).toBeVisible();
  await page.locator('svg g', { hasText: 'Fronti' }).first().click();
  await expect(page.getByText('关联边')).toBeVisible();
});

test('effective: resolve project + agent', async ({ page }) => {
  await page.goto('/effective');
  await page.locator('.page-actions select').first().waitFor({ state: 'visible', timeout: 10_000 });
  await page.locator('.page-actions select option[value="king-of-likes"]').first().waitFor({ state: 'attached', timeout: 10_000 });
  await page.locator('.page-actions select').first().selectOption('king-of-likes');
  await page.locator('.page-actions select option[value="Fronti"]').first().waitFor({ state: 'attached', timeout: 10_000 });
  await page.locator('.page-actions select').nth(1).selectOption('Fronti');
  await expect(page.locator('.sect').first()).toBeVisible();
  await expect(page.getByText('项目 CLAUDE.md').first()).toBeVisible();
  await expect(page.getByText('解析上下文').first()).toBeVisible();
});

test('custom: REST push accepted and appears', async ({ page }) => {
  await page.goto('/custom');
  await page.locator('textarea').fill(
    JSON.stringify({
      collectedAt: new Date().toISOString(),
      assets: [
        {
          id: 'custom:e2e-pushed',
          kind: 'custom',
          name: 'e2e-pushed',
          attach: { level: 'user' },
          enforcement: 'advisory',
          provenance: 'first-party',
          source: { collector: 'push', path: '/e2e/push' },
          payload: { hello: 'world' },
        },
      ],
    })
  );
  await page.getByRole('button', { name: '提交' }).click();
  await expect(page.getByText('接受 1 个资产')).toBeVisible();
});

test('services: OWN badge on first-party name', async ({ page }) => {
  await page.goto('/services');
  const grepaiRow = page.locator('tr', { hasText: 'grepai-watch' }).first();
  await expect(grepaiRow.getByText('OWN', { exact: true }).first()).toBeVisible();
});

test('registry: mgmt section shows declared/undeclared/unmatched', async ({ page }) => {
  await page.goto('/registry');
  await expect(page.getByText('注册管理').first()).toBeVisible();
  await expect(page.getByText('未登记的自建资产').first()).toBeVisible();
  await expect(page.getByText('未匹配声明').first()).toBeVisible();
  await expect(page.getByText('未登记清单', { exact: false }).first()).toBeVisible(); // fixture 自建未声明 → 有清单
});

test('registry: stats table + first-party inventory', async ({ page }) => {
  await page.goto('/registry');
  await expect(page.getByText('统计表').first()).toBeVisible();
  await expect(page.getByText('自建资产清单').first()).toBeVisible();
  await expect(page.locator('.table').getByText('hook-rule').first()).toBeVisible();
  await expect(page.locator('.table').getByText('revy-testing-skill-check').first()).toBeVisible(); // 自建清单含规则
  await expect(page.locator('.table').getByText('EXT', { exact: false }).first()).toBeVisible(); // 统计表有外部列
});

test('services: EXT badge on third-party, toggle only on first-party user units', async ({ page }) => {
  await page.goto('/services');
  await expect(page.getByText('EXT', { exact: true }).first()).toBeVisible();
  const extRow = page.locator('tr', { hasText: 'external-agent' });
  await expect(extRow.locator('.badge-off', { hasText: '开关' })).toBeVisible();
  const grepaiRow = page.locator('tr', { hasText: 'grepai-watch' });
  await expect(grepaiRow.locator('button', { hasText: '■ 停止' })).toBeVisible();
  // system 级禁用
  const sysRow = page.locator('tr', { hasText: 'toolchain-start-all' });
  await expect(sysRow.getByText('system 级需 root')).toBeVisible();
});

test('services: dry-run stop returns ok message', async ({ page }) => {
  await page.goto('/services');
  page.on('dialog', (d) => d.accept());
  const grepaiRow = page.locator('tr', { hasText: 'grepai-watch' });
  await grepaiRow.locator('button', { hasText: '■ 停止' }).click();
  await expect(grepaiRow.getByText('stop ✓').first()).toBeVisible({ timeout: 10_000 });
});

test('sse indicator eventually connected', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('SSE ●')).toBeVisible({ timeout: 15_000 });
});

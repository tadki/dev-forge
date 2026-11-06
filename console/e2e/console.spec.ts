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

test('overview: health banner, stats, activity', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.banner-title').first()).toContainText('GREEN');
  await expect(page.locator('.stat').first()).toBeVisible();
  await expect(page.getByText('最近活动', { exact: false })).toBeVisible();
  await expect(page.getByText('deny', { exact: false }).first()).toBeVisible();
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
    ['/graph', '关系图'],
    ['/custom', '通用资产'],
    ['/effective', '有效 HARNESS'],
    ['/platforms', '平台'],
  ];
  for (const [route, head] of routes) {
    await page.goto(route);
    await expect(page.locator('.page-head h2'), `route ${route}`).toContainText(head, { timeout: 10_000 });
  }
});

test('agents: anatomy with instructions, gates, mcp', async ({ page }) => {
  await page.goto('/agents');
  await expect(page.getByText('自建 AGENTS')).toBeVisible();
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

test('instructions: tree, render, source', async ({ page }) => {
  await page.goto('/instructions');
  await expect(page.getByText('作用域树').first()).toBeVisible();
  await page.locator('.tree-node', { hasText: 'king-of-likes/CLAUDE.md' }).first().click();
  await expect(page.getByText('EffectManager').first()).toBeVisible(); // markdown 渲染
  await page.getByRole('button', { name: '源码' }).click();
  await expect(page.locator('pre.code').first()).toContainText('# 基础规范');
});

test('hooks: pipeline, rules table, firelog', async ({ page }) => {
  await page.goto('/hooks');
  await expect(page.locator('.pipe-node').first()).toContainText('CC 9 挂载点');
  await expect(page.getByText('revy-testing-skill-check')).toBeVisible();
  await expect(page.getByText('REPO 门控')).toBeVisible();
  await expect(page.locator('tr', { hasText: 'revy-testing-skill-check' }).getByText('kol', { exact: true })).toBeVisible();
  await expect(page.getByText('DENY').first()).toBeVisible();
  await expect(page.getByText('FIRE LOG', { exact: false })).toBeVisible();
});

test('services: tree and detail', async ({ page }) => {
  await page.goto('/services');
  await expect(page.getByText('toolchain-start-all').first()).toBeVisible();
  await page.locator('tr').filter({ has: page.getByText('toolchain-start-all', { exact: true }) }).first().click();
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
  await page.getByRole('button', { name: '第三方 THIRD-PARTY' }).click();
  await expect(page.getByText('deep-research').first()).toBeVisible();
});

test('projects: single project card, git identity, harness badge, workspace grouping', async ({ page }) => {
  await page.goto('/projects');
  await expect(page.locator('tr', { hasText: 'king-of-likes' }).first()).toBeVisible();
  await expect(page.getByText('king-of-likes').first()).toBeVisible();
  await expect(page.getByText('godot_mcp').first()).toBeVisible();
  await expect(page.getByText('tadki/KingOfLikes-Godot').first()).toBeVisible();
  await expect(page.getByText('tadki/godot-mcp').first()).toBeVisible();
  await expect(page.getByText('CLAUDE', { exact: true }).first()).toBeVisible();
  await expect(page.getByText("Jerry's Forge").first()).toBeVisible();
});

test('platforms: platform rail + kind list, detail pane on the right', async ({ page }) => {
  await page.goto('/platforms');
  await expect(page.locator('.page-head h2')).toContainText('平台');
  // 左栏：所有已适配平台
  await expect(page.locator('.platform-item').filter({ hasText: 'Claude Code（本地文件系统）' })).toBeVisible();
  const multicaItem = page.locator('.platform-item').filter({ hasText: 'multica 平台' });
  await expect(multicaItem).toBeVisible();
  // 默认平台（claude-code）：契约列表全 15 kind，默认详情在右侧（agent）
  await expect(page.locator('.kind-item')).toHaveCount(15);
  await expect(page.getByText('CC subagent 定义文件').first()).toBeVisible();
  // deployment 契约声明不适用（平台无此对象），显示「不适用」而非「未适配」
  const depRow = page.locator('.kind-item').filter({ hasText: 'deployment' }).first();
  await expect(depRow).toContainText('不适用');
  await depRow.click();
  await expect(page.getByText('Claude Code 无部署实例对象').first()).toBeVisible();
  // 切到 multica：列表单行 + 右侧详情（默认 agent：读/写命令 + 资产）
  await multicaItem.click();
  await expect(page.getByText('multica agent list').first()).toBeVisible();
  await expect(page.getByText('multica agent update {platformId} --instructions {content}').first()).toBeVisible();
  await expect(page.getByText('发现命令').first()).toBeVisible();
  await expect(page.getByText('详情命令').first()).toBeVisible();
  await expect(page.getByText('Fronti').first()).toBeVisible(); // agent 详情含资产清单
  // 点选 skill 契约 → 右侧详情切换（detailCmd + platformId 来源）
  await page.locator('.kind-item').filter({ hasText: 'skill' }).first().click();
  await expect(page.getByText('multica skill get {id} --with-content').first()).toBeVisible();
  await expect(page.getByText('multica skill update {platformId} --content {content}').first()).toBeVisible();
  await expect(page.getByText('platformId ← self').first()).toBeVisible();
  // 未声明 kind 也占一行且标未适配（multica 未声明 hook-registration）
  await expect(page.locator('.kind-item').filter({ hasText: 'hook-registration' }).first()).toBeVisible();
  // 未适配桶：systemd:// 3 个 service
  await expect(page.locator('.sect', { hasText: '未适配' })).toBeVisible();
  await expect(page.getByText('systemd://user/grepai-watch.service').first()).toBeVisible();
});

test('graph: nodes render and inspector works', async ({ page }) => {
  await page.goto('/graph');
  await expect(page.getByRole('img')).toBeVisible(); // 关系图 svg（顶栏 logo 也是 svg，不能用裸 locator('svg')）
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

test('registry: reconcile section lists drift and executes dry-run after confirm', async ({ page }) => {
  await page.goto('/registry');
  await expect(page.getByText('平台对账', { exact: false })).toBeVisible();
  // fixture：Fronti instructions 与物化 CLAUDE.md 分叉 → drift 项 + 双向动作
  await expect(page.getByText('multica · drift:multica:fronti', { exact: false }).first()).toBeVisible();
  await expect(page.locator('.diff-plus').first()).toBeVisible(); // 漂移内容逐行 diff（+ 绿 / - 红着色）
  await expect(page.getByRole('button', { name: /以 agent instructions 为准/ })).toBeVisible();
  await expect(page.getByRole('button', { name: /以物化 CLAUDE.md 为准/ })).toBeVisible();

  // 写操作必须先过页内确认卡；dry-run 服务端只回显计划
  await page.getByRole('button', { name: /以物化 CLAUDE.md 为准/ }).click();
  const card = page.locator('.confirm-card');
  await expect(card).toBeVisible();
  await expect(card.getByText('执行命令', { exact: false }).first()).toBeVisible(); // 卡内列出将执行步骤
  await card.getByRole('button', { name: '确认执行', exact: true }).click();
  await expect(page.getByText('[dry-run]', { exact: false }).first()).toBeVisible();
  await expect(page.getByText('已执行', { exact: false })).toBeVisible();

  // 取消确认 → 卡片关闭，不发请求
  await page.getByRole('button', { name: /以 agent instructions 为准/ }).click();
  const cancelCard = page.locator('.confirm-card');
  await expect(cancelCard).toBeVisible();
  await cancelCard.getByRole('button', { name: '取消', exact: true }).click();
  await expect(cancelCard).not.toBeVisible();
});

test('registry: store drift（库 vs 生产）adopt/push 双向 dry-run', async ({ page }) => {
  await page.goto('/registry');
  // start.mjs 预置了 agent:fronti 的 v2 库内副本（hash 与 fixture 生产指纹不符）→ store-drift
  const panel = page.locator('.panel', { hasText: 'store:agent:fronti' });
  await expect(panel.getByText('库与生产分叉', { exact: false })).toBeVisible();
  await expect(panel.getByText('关联差异', { exact: false })).toBeVisible(); // relatedKeys → drift:multica:fronti
  await expect(panel.getByRole('button', { name: /以生产为准/ })).toBeVisible();
  await expect(panel.getByRole('button', { name: /以库为准/ })).toBeVisible();

  // adopt（以生产为准）→ 页内确认卡 → dry-run 只回显重写库副本，不落盘
  await panel.getByRole('button', { name: /以生产为准/ }).click();
  const adoptCard = page.locator('.confirm-card');
  await expect(adoptCard).toBeVisible();
  await adoptCard.getByRole('button', { name: '确认执行', exact: true }).click();
  await expect(page.getByText('[dry-run]', { exact: false }).first()).toBeVisible();
  await expect(page.getByText('重写库内副本', { exact: false })).toBeVisible();
  await expect(page.getByText('已执行', { exact: false })).toBeVisible();

  // push（以库为准）→ dry-run 回显 multica 命令，platformId 从 deployment 解析
  await panel.getByRole('button', { name: /以库为准/ }).click();
  const pushCard = page.locator('.confirm-card');
  await expect(pushCard).toBeVisible();
  await pushCard.getByRole('button', { name: '确认执行', exact: true }).click();
  await expect(page.getByText('multica agent update fronti-1 --instructions', { exact: false })).toBeVisible();
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

test('services: disabled repo-sync is neutral and has no start/restart', async ({ page }) => {
  await page.goto('/services');
  const disabled = page.locator('tr', { hasText: 'repo-sync · devforge' }).first();
  await expect(disabled.getByText('disabled', { exact: true })).toBeVisible();
  await expect(disabled.getByText('false', { exact: true })).toBeVisible();
  await expect(disabled.getByText('已手动停用（enabled=false）')).toBeVisible();
  await expect(disabled.locator('.badge-off').first()).toBeVisible();
  await expect(disabled.locator('button')).toHaveCount(0);

  const dead = page.locator('tr', { hasText: 'repo-sync · gqt' }).first();
  await expect(dead.getByText('dead', { exact: true })).toBeVisible();
  await expect(dead.getByRole('button', { name: '▶ 启动' })).toBeVisible();
  await expect(dead.getByRole('button', { name: '↻' })).toBeVisible();
  await dead.getByRole('button', { name: '▶ 启动' }).click();
  const startCard = page.locator('.confirm-card');
  await expect(startCard).toBeVisible();
  await startCard.getByRole('button', { name: '确认执行', exact: true }).click();
  await expect(dead.getByText('start ✓')).toBeVisible({ timeout: 10_000 });

  const active = page.locator('tr', { hasText: 'repo-sync · kol' }).first();
  await expect(active.getByText('active', { exact: true })).toBeVisible();
  await expect(active.getByRole('button', { name: '■ 停止' })).toBeVisible();
  await expect(active.getByRole('button', { name: '↻' })).toBeVisible();
});

test('services: dry-run stop returns ok message', async ({ page }) => {
  await page.goto('/services');
  const grepaiRow = page.locator('tr', { hasText: 'grepai-watch' });
  await grepaiRow.locator('button', { hasText: '■ 停止' }).click();
  const stopCard = page.locator('.confirm-card');
  await expect(stopCard).toBeVisible();
  await stopCard.getByRole('button', { name: '确认执行', exact: true }).click();
  await expect(grepaiRow.getByText('stop ✓').first()).toBeVisible({ timeout: 10_000 });
});

test('sse indicator eventually connected', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('SSE ●')).toBeVisible({ timeout: 15_000 });
});

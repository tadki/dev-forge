import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import type { Asset } from '@forge/schema';
import { createHandler } from './app.js';
import { SSEBus } from './sse.js';
import type { RegistryState } from '@forge/collectors';
import { DEFAULT_PLATFORMS } from '@forge/collectors';

function mk(id: string, kind: Asset['kind'], over: Partial<Asset> = {}): Asset {
  return {
    id,
    kind,
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path: `/tmp/${id}` },
    payload: {},
    ...over,
  };
}

const state: RegistryState = {
  assets: [
    mk('project:king-of-likes', 'project', {
      attach: { level: 'project', ref: '/mnt/d/GodotProjects/king-of-likes' },
      payload: { path: '/mnt/d/GodotProjects/king-of-likes', workspace: 'kol' },
    }),
    mk('agent:fronti', 'agent', {
      name: 'Fronti',
      payload: { model: 'agent-fronti[1m]', instructions: 'You are Fronti' },
    }),
    mk('deployment:multica:fronti', 'deployment', {
      name: 'Fronti @ multica',
      attach: { level: 'platform', ref: 'multica' },
      platforms: ['multica'],
      payload: { platform: 'multica', agent: 'Fronti', platformId: 'f1', status: 'idle' },
    }),
    mk('instruction:king-of-likes/CLAUDE.md', 'instruction', {
      attach: { level: 'project', ref: '/mnt/d/GodotProjects/king-of-likes' },
      payload: { basename: 'CLAUDE.md', lines: 144, content: '# KOL\nlong content...', contentHash: 'aaaa1111' },
    }),
    mk('hook-rule:push-guard-master-gate', 'hook-rule', {
      payload: { whenHuman: '工具 Bash 且 命令(当前) ~git push', actions: [{ op: 'deny' }] },
    }),
    mk('report:toolchain-latest', 'report', { payload: { health: 'GREEN', generatedAt: '2026-11-03T04:00:00+08:00', redlineCount: 0 } }),
    mk('skill:ecc-deep-research', 'skill', { provenance: 'third-party' }),
    mk('skill:user-editable', 'skill', {
      name: 'editable',
      payload: { content: 'original body' },
    }),
    mk('service:systemd-grepai-watch.service', 'service', {
      name: 'grepai-watch',
      source: { collector: 'test', path: 'systemd://user/grepai-watch.service' },
      payload: { scope: 'user', active: 'active' },
    }),
    mk('service:systemd-external-thing.service', 'service', {
      name: 'external-thing',
      provenance: 'third-party',
      source: { collector: 'test', path: 'systemd://user/external-thing.service' },
      payload: { scope: 'user', active: 'active' },
    }),
    mk('service:systemd-toolchain-start-all.service', 'service', {
      name: 'toolchain-start-all',
      source: { collector: 'test', path: 'systemd://system/toolchain-start-all.service' },
      payload: { scope: 'system', active: 'active' },
    }),
    mk('service:repo-sync-gqt', 'service', {
      name: 'repo-sync · gqt',
      source: { collector: 'test', path: '/tmp/repo-sync/repos.d/gqt.json' },
      payload: { active: 'dead', config: { enabled: true } },
    }),
    mk('service:repo-sync-devforge', 'service', {
      name: 'repo-sync · devforge',
      source: { collector: 'test', path: '/tmp/repo-sync/repos.d/devforge.json' },
      payload: { active: 'disabled', config: { enabled: false } },
    }),
  ],
  relations: [{ from: 'hook-rule:push-guard-master-gate', to: 'hook-script:x.sh', type: 'mounts' }],
  diagnostics: [],
  collectorStatus: [{ name: 'test', mode: 'watch', ok: true, ms: 5, assets: 6 }],
  lastCollectedAt: '2026-11-03T00:00:00Z',
};

const TOKEN = 'test-token-abc';
const actionLog: Array<{ unit: string; action: string }> = [];
let server: Server;
let base = '';

beforeAll(async () => {
  const sse = new SSEBus();
  const pushed: Asset[] = [];
  const handler = createHandler({
    getState: () => state,
    token: TOKEN,
    sse,
    workspaces: () => [
      { id: 'kol', name: 'King of Likes', projects: [{ path: '/mnt/d/GodotProjects/king-of-likes', harnesses: ['claude'] }], residents: ['Fronti'] },
      { id: 'devforge', name: 'dev-forge 工具链', projects: [] },
    ],
    pushAssets: (a) => pushed.push(...a),
    platforms: () => DEFAULT_PLATFORMS,
    serviceAction: async (unit, action) => {
      actionLog.push({ unit, action });
      if (unit === 'repo-sync-devforge' && action !== 'stop') {
        const detail = 'launcher stderr '.repeat(40);
        return { ok: false, output: `repo-sync-devforge 已手动停用（enabled=false），拒绝 ${action}；${detail}请检查 journalctl --user --since '-5 min'` };
      }
      return { ok: true, output: `fake ${action} ${unit}` };
    },
    getReconcileReport: () => ({
      generatedAt: '2026-11-05T00:00:00Z',
      items: [
        {
          key: 'undeclared:demo:multica',
          type: 'undeclared-platform' as const,
          severity: 'warn' as const,
          platform: 'multica',
          entryId: 'demo',
          name: 'demo',
          detail: '资产实际出现在 multica，但声明未包含该平台',
          copies: [],
          actions: [{ id: 'adopt', direction: 'platform-to-local' as const, label: '采纳现状', executable: true, steps: [{ type: 'registry-edit', file: '/tmp/owned.yaml', entryId: 'demo', op: 'add-platform', platform: 'multica' }] }],
        },
      ],
      summary: { missing: 0, undeclared: 1, drift: 0, uncovered: 0, total: 1 },
    }),
    reconcileAction: async (key, actionId) => {
      actionLog.push({ unit: `reconcile:${key}:${actionId}`, action: 'run' });
      if (key === 'vanished') return { status: 'gone' as const, ok: false, output: '' };
      if (actionId === 'nope') return { status: 'invalid' as const, ok: false, output: `动作不存在：${actionId}` };
      return { status: 'ok' as const, ok: true, output: `已更新 /tmp/owned.yaml：demo.platforms = [claude-code, multica]` };
    },
    saveAssetContent: async (assetId, content) => {
      actionLog.push({ unit: `save:${assetId}`, action: `${content.length}` });
      if (assetId === 'skill:ghost') return { status: 'invalid' as const, ok: false, output: `资产不在当前采集中：${assetId}` };
      return { status: 'ok' as const, ok: true, output: `已写入（${content.length} 字符）` };
    },
  });
  server = createServer((req, res) => void handler(req, res));
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});

afterAll(() => server.close());

async function get(path: string, token?: string): Promise<{ status: number; body: any }> {
  const res = await fetch(base + path, { headers: token ? { authorization: `Bearer ${token}` } : {} });
  return { status: res.status, body: await res.json() };
}

describe('auth', () => {
  it('healthz is public', async () => {
    const r = await get('/healthz');
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);
  });
  it('api requires token', async () => {
    const r = await get('/api/overview');
    expect(r.status).toBe(401);
  });
  it('token via query param works', async () => {
    const r = await get('/api/overview?token=' + TOKEN);
    expect(r.status).toBe(200);
  });
  it('wrong token rejected', async () => {
    const r = await get('/api/overview', 'wrong');
    expect(r.status).toBe(401);
  });
});

describe('api endpoints', () => {
  it('workspaces returns the registration registry with defaults for optional fields', async () => {
    const { status, body } = await get('/api/workspaces', TOKEN);
    expect(status).toBe(200);
    expect(body.workspaces).toHaveLength(2);
    expect(body.workspaces[0]).toEqual({
      id: 'kol',
      name: 'King of Likes',
      projects: [{ path: '/mnt/d/GodotProjects/king-of-likes', harnesses: ['claude'] }],
      residents: ['Fronti'],
    });
    expect(body.workspaces[1].residents).toEqual([]);
  });

  it('overview aggregates counts, health', async () => {
    const r = await get('/api/overview', TOKEN);
    expect(r.body.total).toBe(13);
    expect(r.body.counts['hook-rule']).toBe(1);
    expect(r.body.counts['deployment']).toBe(1);
    expect(r.body.health.status).toBe('GREEN');
  });

  it('assets list filters by kind and strips heavy payload fields', async () => {
    const r = await get('/api/assets?kind=instruction', TOKEN);
    expect(r.body.assets).toHaveLength(1);
    expect(r.body.assets[0].payload.content).toBeUndefined();
    const full = await get('/api/assets/' + encodeURIComponent('instruction:king-of-likes/CLAUDE.md'), TOKEN);
    expect(full.body.asset.payload.content).toContain('# KOL');
    expect(full.body.relations).toBeDefined();
  });

  it('assets search by q', async () => {
    const r = await get('/api/assets?q=push-guard', TOKEN);
    expect(r.body.assets.some((a: Asset) => a.id.includes('push-guard'))).toBe(true);
  });

  it('provenance filter separates dependency shelf', async () => {
    const r = await get('/api/assets?provenance=third-party', TOKEN);
    expect(r.body.assets.every((a: Asset) => a.provenance === 'third-party')).toBe(true);
    expect(r.body.assets.length).toBeGreaterThan(0);
  });

  it('graph returns nodes and cross-referenced edges only', async () => {
    const r = await get('/api/graph?kind=hook-rule', TOKEN);
    expect(r.body.nodes).toHaveLength(1);
    expect(r.body.edges).toHaveLength(0); // hook-script:x.sh 被过滤后不再连边
  });

  it('effective resolves project + agent', async () => {
    const r = await get('/api/effective?project=king-of-likes&agent=Fronti', TOKEN);
    expect(r.body.project.workspace).toBe('kol');
    expect(r.body.agent.name).toBe('Fronti');
    expect(r.body.sections).toHaveLength(5);
  });

  it('platforms returns contract × live assets with unadapted bucket', async () => {
    const r = await get('/api/platforms', TOKEN);
    const ids = r.body.platforms.map((p: { id: string }) => p.id);
    expect(ids).toContain('claude-code');
    expect(ids).toContain('multica');
    const multica = r.body.platforms.find((p: { id: string }) => p.id === 'multica');
    const agentRow = multica.kinds.find((k: { kind: string }) => k.kind === 'agent');
    expect(agentRow.read.cmd).toEqual(['multica', 'agent', 'list']);
    expect(agentRow.write.type).toBe('command');
    const cc = r.body.platforms.find((p: { id: string }) => p.id === 'claude-code');
    expect(cc.totalAssets).toBe(10); // 13 资产 - 3 个 systemd:// 未适配
    expect(cc.kinds.find((k: { kind: string }) => k.kind === 'instruction').read.paths).toContain('<project>/CLAUDE.md');
    expect(r.body.unadapted.assetCount).toBe(3);
    expect(r.body.unadapted.kinds[0].kind).toBe('service');
    expect(Array.isArray(r.body.diagnostics)).toBe(true);
    expect(typeof r.body.generatedAt).toBe('string');
    for (const p of r.body.platforms as { kinds: { assets: Record<string, unknown>[] }[] }[]) {
      for (const k of p.kinds) {
        for (const a of k.assets) {
          expect(a).not.toHaveProperty('payload');
          expect(a).not.toHaveProperty('instructions');
          expect(a).not.toHaveProperty('content');
        }
      }
    }
  });

  it('custom push validates schema', async () => {
    const bad = await fetch(base + '/api/custom/assets', {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({ assets: [{ id: 'x', kind: 'nope' }] }),
    });
    expect(bad.status).toBe(422);

    const good = await fetch(base + '/api/custom/assets', {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        collectedAt: new Date().toISOString(),
        assets: [
          {
            id: 'custom:my-thing',
            kind: 'custom',
            name: 'my-thing',
            attach: { level: 'user' },
            enforcement: 'advisory',
            provenance: 'first-party',
            source: { collector: 'push', path: '/tmp/x' },
          },
        ],
      }),
    });
    expect(good.status).toBe(201);
    expect((await good.json()).accepted).toBe(1);
  });

  it('service actions: only first-party user units', async () => {
    const post = (body: unknown) =>
      fetch(base + '/api/services/actions', {
        method: 'POST',
        headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
    expect((await post({ unit: 'no-such.service', action: 'stop' })).status).toBe(404);
    expect((await post({ unit: 'external-thing.service', action: 'stop' })).status).toBe(403); // 外部
    expect((await post({ unit: 'toolchain-start-all.service', action: 'stop' })).status).toBe(403); // system 级
    expect((await post({ unit: 'grepai-watch.service', action: 'zzz' })).status).toBe(400); // 非法动作
    const ok = await post({ unit: 'grepai-watch.service', action: 'stop' });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toMatchObject({ ok: true, unit: 'grepai-watch.service', action: 'stop' });
    expect(actionLog.at(-1)).toEqual({ unit: 'grepai-watch.service', action: 'stop' });

    const repoSync = await post({ unit: 'repo-sync-gqt', action: 'start' });
    expect(repoSync.status).toBe(200);
    expect(await repoSync.json()).toMatchObject({ ok: true, unit: 'repo-sync-gqt', action: 'start' });
    expect(actionLog.at(-1)).toEqual({ unit: 'repo-sync-gqt', action: 'start' });

    const denied = await post({ unit: 'repo-sync-devforge', action: 'start' });
    expect(denied.status).toBe(200);
    const deniedBody = await denied.json();
    expect(deniedBody).toMatchObject({ ok: false, unit: 'repo-sync-devforge', action: 'start' });
    expect(deniedBody.output).toContain('enabled=false');
    expect(deniedBody.output).toContain("journalctl --user --since '-5 min'");
    expect(deniedBody.output.length).toBeLessThanOrEqual(400);
  });

  it('reconcile: 报告可读、写操作必须 confirm、gone 409、invalid 400', async () => {
    const report = await get('/api/reconcile', TOKEN);
    expect(report.status).toBe(200);
    expect(report.body.summary.total).toBe(1);
    expect(report.body.items[0].actions[0].steps[0].type).toBe('registry-edit');

    const post = (body: unknown) =>
      fetch(base + '/api/reconcile/actions', {
        method: 'POST',
        headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });

    expect((await post({ key: 'undeclared:demo:multica', actionId: 'adopt' })).status).toBe(400); // 缺 confirm
    expect((await post({ key: 'undeclared:demo:multica', actionId: 'nope', confirm: true })).status).toBe(400); // 动作不存在
    expect((await post({ key: 'vanished', actionId: 'adopt', confirm: true })).status).toBe(409); // 对账项已变化
    const ok = await post({ key: 'undeclared:demo:multica', actionId: 'adopt', confirm: true });
    expect(ok.status).toBe(200);
    const okBody = await ok.json();
    expect(okBody.ok).toBe(true);
    expect(okBody.output).toContain('platforms');
    expect(actionLog.at(-1)).toEqual({ unit: 'reconcile:undeclared:demo:multica:adopt', action: 'run' });
  });

  it('skill content save: confirm/content 校验、invalid 400、成功 200', async () => {
    const post = (body: unknown, assetId = 'skill:user-editable') =>
      fetch(base + `/api/assets/${assetId}/content`, {
        method: 'POST',
        headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });

    expect((await post({ content: 'x' })).status).toBe(400); // 缺 confirm
    expect((await post({ confirm: true })).status).toBe(400); // 缺 content
    expect((await post({ confirm: true, content: '' })).status).toBe(400); // 空 content
    expect((await post({ confirm: true, content: 'x'.repeat(200_001) })).status).toBe(400); // 超上限
    expect((await post({ confirm: true, content: 'x' }, 'skill:ghost')).status).toBe(400); // invalid（资产不在采集中）

    const ok = await post({ confirm: true, content: 'edited body' });
    expect(ok.status).toBe(200);
    const okBody = await ok.json();
    expect(okBody).toMatchObject({ ok: true, assetId: 'skill:user-editable' });
    expect(okBody.output).toContain('edited body'.length.toString());
    expect(actionLog.at(-1)).toEqual({ unit: 'save:skill:user-editable', action: `${'edited body'.length}` });

    // GET 详情路由不受 /content 路由影响
    const detail = await get(`/api/assets/${encodeURIComponent('skill:user-editable')}`, TOKEN);
    expect(detail.status).toBe(200);
    expect(detail.body.asset.payload.content).toBe('original body');

    // 非法 URI 编码 → 400（客户端错误），不是 500
    expect((await post({ confirm: true, content: 'x' }, '%')).status).toBe(400);
    expect((await get('/api/assets/%', TOKEN)).status).toBe(400);
  });

  it('unknown path 404s as json', async () => {
    const r = await get('/api/nope', TOKEN);
    expect(r.status).toBe(404);
  });
});

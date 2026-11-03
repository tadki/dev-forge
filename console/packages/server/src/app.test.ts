import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import type { Asset } from '@forge/schema';
import { createHandler } from './app.js';
import { SSEBus } from './sse.js';
import type { RegistryState } from '@forge/collectors';

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
  ],
  relations: [{ from: 'hook-rule:push-guard-master-gate', to: 'hook-script:x.sh', type: 'mounts' }],
  diagnostics: [],
  driftGroups: [
    { key: 'kol:CLAUDE.md', workspace: 'kol', basename: 'CLAUDE.md', copies: 3, variants: [{ id: 'instruction:king-of-likes/CLAUDE.md', path: '/a', hash8: 'aaaa1111', lines: 144 }] },
  ],
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
    serviceAction: async (unit, action) => {
      actionLog.push({ unit, action });
      return { ok: true, output: `fake ${action} ${unit}` };
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

  it('overview aggregates counts, health, drift', async () => {
    const r = await get('/api/overview', TOKEN);
    expect(r.body.total).toBe(10);
    expect(r.body.counts['hook-rule']).toBe(1);
    expect(r.body.counts['deployment']).toBe(1);
    expect(r.body.health.status).toBe('GREEN');
    expect(r.body.driftGroups[0].workspace).toBe('kol');
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

  it('migration returns matrix + commands', async () => {
    const r = await get('/api/migration', TOKEN);
    expect(r.body.commands[0]).toContain('#!/bin/bash');
    expect(r.body.rows.length).toBeGreaterThan(0);
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
  });

  it('unknown path 404s as json', async () => {
    const r = await get('/api/nope', TOKEN);
    expect(r.status).toBe(404);
  });
});

import { describe, expect, it } from 'vitest';
import type { Asset } from '@forge/schema';
import { buildReconcileReport, reconcileDiagnostics } from './reconcile.js';
import { contentFingerprint } from './store-content.js';
import type { RegistryEntry } from './overlay.js';

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

function entry(over: Partial<RegistryEntry> & { id: string }): RegistryEntry {
  return { match: {}, file: '/tmp/registry.d/owned.yaml', ...over };
}

describe('平台归属对账', () => {
  it('声明的平台没有实际实例 → missing-on-platform，撤销声明可执行、应用需手动', () => {
    const assets = [mk('skill:local-only', 'skill', { platforms: [] })];
    const report = buildReconcileReport(
      { assets },
      [entry({ id: 'local-skills', match: { idPrefix: 'skill:local' }, platforms: ['multica'] })]
    );
    const item = report.items.find((i) => i.key === 'missing:local-skills:multica');
    expect(item?.type).toBe('missing-on-platform');
    expect(item?.actions.find((a) => a.id === 'apply')?.executable).toBe(false);
    const retract = item?.actions.find((a) => a.id === 'retract');
    expect(retract?.executable).toBe(true);
    expect(retract?.steps[0]).toMatchObject({ type: 'registry-edit', op: 'remove-platform', platform: 'multica' });
  });

  it('实际平台未在声明中 → undeclared-platform，采纳动作回写声明', () => {
    const assets = [mk('skill:deployed', 'skill', { platforms: ['multica'] })];
    const report = buildReconcileReport(
      { assets },
      [entry({ id: 'deployed-skills', match: { idPrefix: 'skill:deployed' }, platforms: ['claude-code'] })]
    );
    const item = report.items.find((i) => i.key === 'undeclared:deployed-skills:multica');
    expect(item?.type).toBe('undeclared-platform');
    expect(item?.copies).toHaveLength(1);
    const adopt = item?.actions.find((a) => a.id === 'adopt');
    expect(adopt?.executable).toBe(true);
    expect(adopt?.steps[0]).toMatchObject({ type: 'registry-edit', op: 'add-platform', platform: 'multica' });
  });

  it('声明与实际一致 → 无归属差异', () => {
    const assets = [mk('skill:ok', 'skill', { platforms: ['claude-code', 'multica'] })];
    const report = buildReconcileReport(
      { assets },
      [entry({ id: 'ok-skills', match: { idPrefix: 'skill:ok' }, platforms: ['claude-code', 'multica'] })]
    );
    expect(report.summary.total).toBe(0);
  });

  it('entry 不写 platforms → 不参与归属对账，但资产进入未覆盖兜底', () => {
    const assets = [mk('skill:unchecked', 'skill', { platforms: ['multica'] })];
    const report = buildReconcileReport({ assets }, [entry({ id: 'unchecked', match: { idPrefix: 'skill:unchecked' } })]);
    const uncovered = report.items.find((i) => i.key === 'uncovered:skill:multica');
    expect(uncovered?.type).toBe('uncovered-assets');
    expect(uncovered?.copies).toHaveLength(1);
    expect(uncovered?.actions[0].executable).toBe(false);
    expect(report.summary.uncovered).toBe(1);
  });

  it('诊断输出带 reconcile 前缀且截断', () => {
    const assets = [mk('skill:unchecked', 'skill', { platforms: ['multica'] })];
    const report = buildReconcileReport(
      { assets },
      [entry({ id: 'e1', match: { idPrefix: 'skill:unchecked' }, platforms: ['claude-code'] })]
    );
    const diags = reconcileDiagnostics(report);
    expect(diags.length).toBeGreaterThan(0);
    expect(diags[0].message.startsWith('[reconcile]')).toBe(true);
  });

  it('被 platforms 声明覆盖的资产不进未覆盖兜底', () => {
    const assets = [mk('skill:ok', 'skill', { platforms: ['claude-code'] })];
    const report = buildReconcileReport(
      { assets },
      [entry({ id: 'ok', match: { idPrefix: 'skill:ok' }, platforms: ['claude-code'] })]
    );
    expect(report.items).toHaveLength(0);
    expect(report.summary.total).toBe(0);
  });

  it('custom 派生观测视图（活动流/健康报告）不进未覆盖兜底', () => {
    const assets = [mk('custom:activity', 'custom', { platforms: ['claude-code'] }), mk('custom:toolchain-latest', 'custom', { platforms: [] })];
    const report = buildReconcileReport({ assets }, []);
    expect(report.items.filter((i) => i.type === 'uncovered-assets')).toHaveLength(0);
  });
});

describe('跨平台技能内容对账', () => {
  const pair = () => [
    mk('skill:user-taskassign', 'skill', {
      name: 'taskassign',
      platforms: ['claude-code'],
      source: { collector: 'test', path: '/home/jerry/.claude/skills/taskassign/SKILL.md' },
      payload: { content: 'local version' },
    }),
    mk('skill:multica-task-assign', 'skill', {
      name: 'task-assign',
      platforms: ['multica'],
      source: { collector: 'multica', path: 'multica://skills/s1' },
      payload: { content: 'remote version', platformId: 's1' },
    }),
  ];
  const decl = entry({ id: 'skill-taskassign', match: { pathPrefix: '/home/jerry/.claude/skills/taskassign/' }, platforms: ['claude-code'] });

  it('名称归一化配对（taskassign ↔ task-assign），内容分叉 → drift + 双向可执行', () => {
    const report = buildReconcileReport({ assets: pair() }, [decl]);
    const item = report.items.find((i) => i.key === 'drift:skill:skill:user-taskassign');
    expect(item?.type).toBe('content-drift');
    expect(item?.diff?.length).toBeGreaterThan(0);
    const writeLocal = item?.actions.find((a) => a.id === 'write-local');
    expect(writeLocal?.executable).toBe(true);
    expect(writeLocal?.steps[0]).toMatchObject({ type: 'file-write', path: '/home/jerry/.claude/skills/taskassign/SKILL.md' });
    const updatePlatform = item?.actions.find((a) => a.id === 'update-platform');
    expect(updatePlatform?.executable).toBe(true);
    expect(updatePlatform?.steps[0]).toMatchObject({ type: 'command', cmd: ['multica', 'skill', 'update', 's1', '--content', '{content}'] });
  });

  it('内容一致 → 无 drift；未声明本地技能不配对', () => {
    const assets = pair();
    (assets[1].payload as { content: string }).content = 'local version';
    expect(buildReconcileReport({ assets }, [decl]).items.filter((i) => i.type === 'content-drift')).toHaveLength(0);
    const different = pair();
    (different[1].payload as { content: string }).content = 'other';
    const report = buildReconcileReport({ assets: different }, []);
    expect(report.items.filter((i) => i.key.startsWith('drift:skill:'))).toHaveLength(0);
  });
});

describe('内容漂移', () => {
  it('multica agent instructions 与物化 workdir 不一致 → 双向动作齐备', () => {
    const assets = [
      mk('agent:fronti', 'agent', {
        name: 'Fronti',
        platforms: [],
        payload: { instructions: 'You are Fronti v2', instructionsHash: 'abc' },
        source: { collector: 'multica', path: 'multica://agents/f1' },
      }),
      mk('deployment:multica:fronti', 'deployment', {
        name: 'Fronti @ multica',
        platforms: ['multica'],
        attach: { level: 'platform', ref: 'multica' },
        payload: { platformId: 'f1', agent: 'Fronti' },
        source: { collector: 'multica', path: 'multica://agents/f1' },
      }),
      mk('custom:multica-materialized-instructions', 'custom', {
        platforms: ['multica'],
        payload: { samples: [{ agent: 'Fronti', path: '/tmp/workdir-a/CLAUDE.md', hash: 'deadbeef', body: 'You are Fronti v1' }] },
      }),
    ];
    const report = buildReconcileReport({ assets }, []);
    const item = report.items.find((i) => i.key === 'drift:multica:fronti');
    expect(item?.type).toBe('content-drift');
    expect(item?.diff?.length).toBeGreaterThan(0);
    expect(item?.detail).toContain('abc'); // 优先展示 instructionsHash 而非内容前缀
    const writeWorkdir = item?.actions.find((a) => a.id === 'write-workdir');
    expect(writeWorkdir?.executable).toBe(true);
    expect(writeWorkdir?.steps[0]).toMatchObject({
      type: 'file-write',
      path: '/tmp/workdir-a/CLAUDE.md',
      preserveMulticaPrefix: true,
      contentFrom: { assetId: 'agent:fronti', field: 'instructions' },
    });
    const updateAgent = item?.actions.find((a) => a.id === 'update-agent');
    expect(updateAgent?.executable).toBe(true);
    expect(updateAgent?.steps[0]).toMatchObject({
      type: 'command',
      cmd: ['multica', 'agent', 'update', 'f1', '--instructions', '{content}'],
      contentFrom: { assetId: 'custom:multica-materialized-instructions', field: 'materialized-body', agent: 'Fronti' },
    });
  });

  it('物化样本与 instructions 一致 → 无漂移项', () => {
    const assets = [
      mk('agent:fronti', 'agent', { name: 'Fronti', platforms: [], payload: { instructions: 'same text' } }),
      mk('custom:multica-materialized-instructions', 'custom', {
        payload: { samples: [{ agent: 'Fronti', path: '/tmp/workdir-a/CLAUDE.md', hash: 'x', body: 'same text' }] },
      }),
    ];
    const report = buildReconcileReport({ assets }, []);
    expect(report.items.filter((i) => i.type === 'content-drift')).toHaveLength(0);
  });

  it('同 entry 同名副本 sha 分叉 → drift；不同名不算', () => {
    const assets = [
      mk('instruction:a/CLAUDE.md', 'instruction', {
        name: 'shared.md',
        source: { collector: 'test', path: '/tmp/a/shared.md', sha256: 'sha-a' },
        payload: { content: 'aaa' },
      }),
      mk('instruction:b/CLAUDE.md', 'instruction', {
        name: 'shared.md',
        source: { collector: 'test', path: '/tmp/b/shared.md', sha256: 'sha-b' },
        payload: { content: 'bbb' },
      }),
      mk('instruction:c/other.md', 'instruction', {
        name: 'other.md',
        source: { collector: 'test', path: '/tmp/c/other.md', sha256: 'sha-c' },
      }),
    ];
    const report = buildReconcileReport(
      { assets },
      [entry({ id: 'copies', match: { pathPrefix: '/tmp/' } })]
    );
    const items = report.items.filter((i) => i.type === 'content-drift');
    expect(items).toHaveLength(1);
    expect(items[0].copies).toHaveLength(2);
    expect(items[0].actions.some((a) => a.executable && a.steps[0]?.type === 'file-write')).toBe(true);
  });
});

describe('store-drift（库 vs 生产）', () => {
  const declared = (a: Asset): Asset => ({ ...a, payload: { ...a.payload, registry: { declared: true, declaredBy: 'e' } } });

  function v2Record(asset: Asset, content: string): import('./first-party-store.js').StoreRecord {
    return {
      id: asset.id,
      kind: asset.kind,
      name: asset.name,
      savedAt: '2026-11-06T00:00:00Z',
      updatedAt: '2026-11-06T00:00:00Z',
      hashVersion: 3,
      hash: 'irrelevant-will-be-set',
      asset: { ...asset, payload: { ...asset.payload, content } },
    };
  }

  it('指纹一致 → 无 store-drift；分叉 → adopt/store-write + push(file-write, 库内容)', () => {
    const prod = declared(mk('instruction:x/CLAUDE.md', 'instruction', { payload: { content: '生产新版' } }));
    const same = declared(mk('instruction:same/CLAUDE.md', 'instruction', { payload: { content: '一致' } }));
    const store = new Map();
    for (const [a, lib] of [
      [prod, v2Record(prod, '库内旧版')],
      [same, { ...v2Record(same, '一致'), hash: contentFingerprint(same) }],
    ] as const) {
      store.set(a.id, lib as import('./first-party-store.js').StoreRecord);
    }
    const report = buildReconcileReport({ assets: [prod, same] }, [], new Date(), { store });
    expect(report.summary.store).toBe(1);
    const item = report.items.find((i) => i.key === `store:${prod.id}`);
    expect(item?.type).toBe('store-drift');
    expect(item?.diff?.some((l) => l.includes('库内旧版') || l.includes('生产新版'))).toBe(true);
    const adopt = item?.actions.find((a) => a.id === 'adopt');
    expect(adopt?.executable).toBe(true);
    expect(adopt?.steps[0]).toMatchObject({ type: 'store-write', assetId: prod.id });
    const push = item?.actions.find((a) => a.id === 'push');
    expect(push?.direction).toBe('local-to-platform');
    expect(push?.steps[0]).toMatchObject({
      type: 'file-write',
      path: prod.source.path,
      contentFrom: { assetId: prod.id, field: 'content', from: 'store' },
    });
  });

  it('multica skill 分叉 → push 走 command 通道并代入 platformId', () => {
    const prod = declared(
      mk('skill:multica-demo', 'skill', {
        platforms: ['multica'],
        source: { collector: 'multica', path: 'multica://skills/abc' },
        payload: { content: '生产', platformId: 'abc-123' },
      })
    );
    const store = new Map([[prod.id, { ...v2Record(prod, '库'), hash: 'not-matching' }]] as const);
    const report = buildReconcileReport({ assets: [prod] }, [], new Date(), { store });
    const push = report.items.find((i) => i.key === `store:${prod.id}`)?.actions.find((a) => a.id === 'push');
    expect(push?.executable).toBe(true);
    expect(push?.steps[0]).toMatchObject({
      type: 'command',
      cmd: ['multica', 'skill', 'update', 'abc-123', '--content', '{content}'],
      contentFrom: { from: 'store', field: 'content' },
    });
  });

  it('multica agent 分叉 → platformId 从 deployment 解析 + relatedKeys 关联 drift:multica', () => {
    const prod = declared(
      mk('agent:fronti', 'agent', {
        platforms: ['multica'],
        source: { collector: 'multica', path: 'multica://agents/f1' },
        payload: { instructions: '新' },
      })
    );
    const dep = mk('deployment:multica:fronti', 'deployment', {
      platforms: ['multica'],
      source: { collector: 'multica', path: 'multica://agents/f1' },
      payload: { agent: 'Fronti', platformId: 'agent-uuid-9' },
    });
    const store = new Map([[prod.id, { ...v2Record(prod, '旧'), hash: 'x' }]] as const);
    const report = buildReconcileReport({ assets: [prod, dep] }, [], new Date(), { store });
    const item = report.items.find((i) => i.key === 'store:agent:fronti');
    expect(item?.relatedKeys).toEqual(['drift:multica:fronti']);
    const push = item?.actions.find((a) => a.id === 'push');
    expect(push?.steps[0]).toMatchObject({
      type: 'command',
      cmd: ['multica', 'agent', 'update', 'agent-uuid-9', '--instructions', '{content}'],
    });
  });

  it('无写通道 kind（multica autopilot）→ push 不可执行且带建议', () => {
    const prod = declared(
      mk('autopilot-registration:multica-zzz', 'autopilot-registration', {
        platforms: ['multica'],
        source: { collector: 'multica', path: 'multica://autopilots/z' },
        payload: { description: 'd' },
      })
    );
    const store = new Map([[prod.id, { ...v2Record(prod, 'x'), hash: 'x' }]] as const);
    const report = buildReconcileReport({ assets: [prod] }, [], new Date(), { store });
    const push = report.items.find((i) => i.key === `store:${prod.id}`)?.actions.find((a) => a.id === 'push');
    expect(push?.executable).toBe(false);
    expect(push?.note).toBeTruthy();
  });

  it('非内容型 kind 与未声明资产不进 store-drift；无 store 时不检测', () => {
    const svc = declared(mk('service:sysd-x', 'service', { payload: { active: 'active' } }));
    const undec = mk('skill:undeclared-x', 'skill', { payload: { content: 'x' } });
    const store = new Map([
      [svc.id, { ...v2Record(svc, 'x'), hash: 'x' }],
      [undec.id, { ...v2Record(undec, 'x'), hash: 'x' }],
    ] as const);
    const r1 = buildReconcileReport({ assets: [svc, undec] }, [], new Date(), { store });
    expect(r1.summary.store).toBe(0);
    const r2 = buildReconcileReport({ assets: [svc, undec] }, []);
    expect(r2.summary.store).toBe(0);
  });

  it('脚本型 autopilot（无文本字段）分叉 → 内容视图逐字段 diff 仍可展示', () => {
    const prod = declared(
      mk('autopilot-script:script-sweep', 'autopilot-script', {
        platforms: ['multica'],
        source: { collector: 'devforge-autopilots', path: '/x/autopilots/sweep.py', sha256: 'prod-sha-aaa' },
        payload: { script: true, lines: 12, purpose: '新用途' },
      })
    );
    const stored = { ...prod, source: { ...prod.source, sha256: 'store-sha-bbb' }, payload: { script: true, lines: 9, purpose: '旧用途' } };
    const store = new Map([[prod.id, { ...v2Record(prod, ''), asset: stored, hash: 'not-matching' }]] as const);
    const report = buildReconcileReport({ assets: [prod] }, [], new Date(), { store });
    const item = report.items.find((i) => i.key === `store:${prod.id}`);
    expect(item?.diff?.some((l) => l.includes('旧用途') || l.includes('新用途'))).toBe(true);
    expect(item?.diff?.some((l) => l.includes('sha256'))).toBe(true);
    expect(item?.splitRows?.some((r) => r.kind !== 'same')).toBe(true);
  });

  it('正文一致而指纹漂移（agent 元数据变更）→ 回退内容视图对照', () => {
    const prod = declared(mk('agent:meta', 'agent', { payload: { instructions: '同文', model: 'new-model' } }));
    const stored = { ...prod, payload: { instructions: '同文', model: 'old-model' } };
    const store = new Map([[prod.id, { ...v2Record(prod, ''), asset: stored, hash: 'not-matching' }]] as const);
    const report = buildReconcileReport({ assets: [prod] }, [], new Date(), { store });
    const item = report.items.find((i) => i.key === `store:${prod.id}`);
    expect(item?.diff?.some((l) => l.includes('old-model') || l.includes('new-model'))).toBe(true);
    expect(item?.splitRows?.some((r) => r.kind !== 'same')).toBe(true);
  });

  it('脚本型 autopilot 两侧有正文 → 全文 diff 能看出删掉的代码，push 可恢复库内旧脚本', () => {
    const oldBody = '#!/usr/bin/env python3\n# Architecture sweep\n\ndef run_ok(cmd):\n    return True\n\ndef main():\n    print("sweep")\n';
    const newBody = '#!/usr/bin/env python3\n# Architecture sweep\n\ndef main():\n    print("sweep")\n';
    const prod = declared(
      mk('autopilot-script:script-sweep', 'autopilot-script', {
        platforms: ['multica'],
        source: { collector: 'devforge-autopilots', path: '/x/autopilots/sweep.py', sha256: 'prod-sha-aaa' },
        payload: { script: true, lines: newBody.split('\n').length, purpose: 'sweep', content: newBody },
      })
    );
    const stored = {
      ...prod,
      source: { ...prod.source, sha256: 'store-sha-bbb' },
      payload: { script: true, lines: oldBody.split('\n').length, purpose: 'sweep', content: oldBody },
    };
    const store = new Map([[prod.id, { ...v2Record(prod, ''), asset: stored, hash: 'not-matching' }]] as const);
    const report = buildReconcileReport({ assets: [prod] }, [], new Date(), { store });
    const item = report.items.find((i) => i.key === `store:${prod.id}`);
    // 全文对照：被删掉的 run_ok 在库内旧文中、生产侧没有（del 行），而不是只剩 sha 字段差异
    expect(item?.splitRows?.some((r) => r.kind === 'del' && r.left?.includes('run_ok'))).toBe(true);
    expect(item?.diff?.some((l) => l.startsWith('- ') && l.includes('run_ok'))).toBe(true);
    const push = item?.actions.find((a) => a.id === 'push');
    expect(push?.executable).toBe(true);
    expect(push?.steps[0]).toMatchObject({
      type: 'file-write',
      path: '/x/autopilots/sweep.py',
      contentFrom: { assetId: prod.id, field: 'content', from: 'store' },
    });
  });
});

describe('审核回归：未注册平台与截断保护', () => {
  it('undeclared-platform 遇未注册平台 id → adopt 不可执行（防 registry 枚举污染）', () => {
    const a = mk('skill:deployed', 'skill', { platforms: ['codex'] });
    const r = buildReconcileReport(
      { assets: [a] },
      [entry({ id: 'e1', match: { idPrefix: 'skill:deployed' }, platforms: ['claude-code'] })]
    );
    const item = r.items.find((i) => i.key === 'undeclared:e1:codex');
    expect(item?.actions.find((x) => x.id === 'adopt')?.executable).toBe(false);
    expect(item?.actions.find((x) => x.id === 'adopt')?.note).toContain('未注册');
  });
});

import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import { defaultConfig, writeStoreRecord, type Collector } from '@forge/collectors';
import { Engine } from './engine.js';
import { SSEBus } from './sse.js';

const root = join(tmpdir(), `forge-engine-${Date.now()}`);

function mk(id: string, kind: Asset['kind'], payload: Record<string, unknown>): Asset {
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
    payload,
  };
}

describe('Engine.refreshReconcileAfterAction', () => {
  it('adopt 写库后立即重建报告：store-drift 项即时消失，不等整轮重采', async () => {
    const devforge = join(root, 'devforge');
    const storeDir = join(root, 'store');
    await mkdir(join(devforge, 'console', 'registry.d'), { recursive: true });
    await mkdir(storeDir, { recursive: true });
    await writeFile(
      join(devforge, 'console', 'registry.d', 'owned.yaml'),
      `entries:\n  - id: t\n    match:\n      idPrefix: "instruction:test"\n    platforms: [claude-code]\n`
    );
    const prod = mk('instruction:test/CLAUDE.md', 'instruction', { content: '生产新版' });
    const collector: Collector = {
      name: 'fake',
      mode: 'poll',
      collect: async () => ({ assets: [prod], relations: [], diagnostics: [] }),
    };
    const config = { ...defaultConfig({ home: root, devforge }), firstPartyStoreDir: storeDir };
    const engine = new Engine({ config, sse: new SSEBus(), watchEnabled: false, collectorsOverride: [collector] });

    // 库内预置旧副本（等价于生产已分叉、重采后报告应含 store-drift）
    await writeStoreRecord(storeDir, { ...prod, payload: { content: '库内旧版' } });
    await engine.start();
    try {
      const key = `store:${prod.id}`;
      expect(engine.state.reconcile?.items.some((i) => i.key === key)).toBe(true);
      // 模拟「以生产为准」：以生产内容重写库副本（与 runStoreWrite 相同），然后即时刷新
      await writeStoreRecord(storeDir, prod);
      await engine.refreshReconcileAfterAction();
      expect(engine.state.reconcile?.items.some((i) => i.key === key)).toBe(false);
      expect(engine.state.reconcile?.summary.store).toBe(0);
    } finally {
      engine.stop();
    }
  });
});

afterAll(async () => {
  await rm(root, { recursive: true, force: true });
});

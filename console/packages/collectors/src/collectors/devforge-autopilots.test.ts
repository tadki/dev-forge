import { describe, expect, it } from 'vitest';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import { makeContext, defaultConfig } from '../index.js';
import { devforgeAutopilotsCollector } from './devforge-autopilots.js';
import { contentFingerprint } from '../store-content.js';

describe('devforge-autopilots collector 正文归档', () => {
  const root = join(tmpdir(), `forge-autopilots-test-${Date.now()}`);

  it('脚本与配置资产的 payload.content 归档正文，且正文不参与内容指纹', async () => {
    await mkdir(join(root, 'autopilots', 'configs'), { recursive: true });
    const body = '#!/usr/bin/env python3\n"""Architecture sweep"""\nprint("sweep")\n';
    await writeFile(join(root, 'autopilots', 'sweep.py'), body);
    await writeFile(join(root, 'autopilots', 'configs', 'kol.json'), JSON.stringify({ target: 'kol', depth: 2 }));

    const r = await devforgeAutopilotsCollector.collect(makeContext(defaultConfig({ devforge: root })));
    const script = r.assets.find((x) => x.id === 'autopilot-script:sweep');
    const cfg = r.assets.find((x) => x.id === 'autopilot-script:config-kol');
    expect((script!.payload as { content?: string }).content).toBe(body);
    expect((cfg!.payload as { content?: string }).content).toContain('"target"');

    // 正文归档不得改变内容指纹（否则每次采集都会凭空出现 store-drift）
    const withoutContent = (a: Asset): Asset => {
      const { content: _c, ...rest } = a.payload as Record<string, unknown>;
      return { ...a, payload: rest };
    };
    for (const a of [script!, cfg!]) {
      expect(contentFingerprint(a)).toBe(contentFingerprint(withoutContent(a)));
    }
    await rm(root, { recursive: true, force: true });
  });
});

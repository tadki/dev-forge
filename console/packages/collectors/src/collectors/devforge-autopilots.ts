import type { Asset } from '@forge/schema';
import { join } from 'node:path';
import { exists, listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type Collector } from '../types.js';

export const devforgeAutopilotsCollector: Collector = {
  name: 'devforge-autopilots',
  mode: 'watch',
  watchPaths: (ctx) => [join(ctx.paths.devforge, 'autopilots')],
  async collect(ctx) {
    const assets: Asset[] = [];
    const dir = join(ctx.paths.devforge, 'autopilots');

    for (const f of (await listDir(dir))) {
      if (!/\.(py|sh)$/.test(f)) continue;
      const p = join(dir, f);
      const md = (await readText(p)) ?? '';
      const docstring = md.match(/"""([\s\S]*?)"""/)?.[1]?.trim().split('\n')[0] ?? '';
      const header = md.split('\n').find((l) => l.startsWith('# '))?.replace(/^#\s*/, '') ?? '';
      const stem = f.replace(/\.(py|sh)$/, '');
      assets.push(
        asset({
          id: `autopilot-script:${stem}`,
          kind: 'autopilot-script',
          name: stem,
          summary: (docstring || header).slice(0, 120),
          attach: { level: 'user' },
          enforcement: 'derived',
          // dev-forge 工具链内部文件：扫描路径证明不了平台归属（Owner 2026-11-11），
          // 归属由 registry.d 声明（owned.yaml devforge-autopilots → multica）经 overlay 盖上
          platforms: [],
          source: { collector: 'devforge-autopilots', path: p, sha256: sha256(md) },
          // 正文随 payload 归档（不进内容指纹）：库内真源可全文对照 / 回滚，避免只存哈希看不出改了什么
          payload: { script: true, lines: md.split('\n').length, purpose: docstring || header, content: md },
          tags: ['autopilot', 'devforge', 'scripted'],
        })
      );
    }

    const kolPath = join(dir, 'configs', 'kol.json');
    const kolCfg = await readJson<Record<string, unknown>>(kolPath);
    if (kolCfg) {
      const kolRaw = (await readText(kolPath)) ?? '';
      assets.push(
        asset({
          id: 'autopilot-script:config-kol',
          kind: 'autopilot-script',
          name: 'architecture_sweep 配置（kol.json）',
          summary: `target ${String(kolCfg.target ?? kolCfg.repo_name ?? '')}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: [],
          source: { collector: 'devforge-autopilots', path: kolPath },
          payload: { ...kolCfg, content: kolRaw },
          tags: ['autopilot', 'config'],
        })
      );
    }

    // agent 评审型（无脚本）：从 autopilots/review-prompts 子树识别（评审 prompt 只服务 autopilot，目录随之归集）
    const reviewDir = join(dir, 'review-prompts');
    if (await exists(reviewDir)) {
      for (const kind of (await listDir(reviewDir)).filter((d) => !d.includes('.'))) {
        const promptsDir = join(reviewDir, kind, 'prompts');
        if (!(await exists(promptsDir))) continue;
        const templates = (await listDir(promptsDir)).filter((f) => f.endsWith('.md'));
        if (templates.length === 0) continue;
        assets.push(
          asset({
            id: `autopilot-script:review-${kind}`,
            kind: 'autopilot-script',
            name: `${kind} 评审巡逻（无脚本）`,
            summary: `agent 评审型 · 模板 ${templates.length} 份 · 台账 ledger/`,
            attach: { level: 'user' },
            enforcement: 'advisory',
            platforms: [],
            source: { collector: 'devforge-autopilots', path: join(reviewDir, kind) },
            payload: { reviewKind: kind, templates },
            tags: ['autopilot', 'agent-review'],
          })
        );
      }
    }

    return { assets, relations: [], diagnostics: ctx.diagnostics };
  },
};

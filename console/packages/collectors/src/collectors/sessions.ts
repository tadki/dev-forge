import { join } from 'node:path';
import { listDir, readJson } from '../util.js';
import type { Asset } from '@forge/schema';
import { asset, type Collector } from '../types.js';

export const sessionsCollector: Collector = {
  name: 'sessions',
  mode: 'on-request',
  async collect(ctx) {
    const assets: Asset[] = [];
    const projectDirs = await listDir(join(ctx.paths.claude, 'projects'));
    const taskRoots = (await readJson<Record<string, { task_id?: string }>>(join(ctx.paths.multicaWorkspaces, '.task_roots')).catch(() => null)) ?? null;
    let seeds = 0;
    let tasks = 0;
    if (taskRoots) {
      tasks = Object.keys(taskRoots).length;
      seeds = new Set(Object.keys(taskRoots).map((k) => k.split('/')[0])).size;
    } else {
      const wsRoot = await listDir(ctx.paths.multicaWorkspaces);
      seeds = wsRoot.filter((d) => d.startsWith('seed-')).length;
      for (const seed of wsRoot.filter((d) => d.startsWith('seed-'))) {
        tasks += (await listDir(join(ctx.paths.multicaWorkspaces, seed))).filter((d) => d.startsWith('see-')).length;
      }
    }
    assets.push(
      asset({
        id: 'custom:sessions-summary',
        kind: 'custom',
        name: '会话与任务总览',
        summary: `CC 会话目录 ${projectDirs.length} · multica seeds ${seeds} / tasks ${tasks}`,
        attach: { level: 'user' },
        enforcement: 'derived',
        // 跨平台本地聚合（CC 会话目录 + multica workspaces），不隶属单一平台 → 未适配桶
        platforms: [],
        source: { collector: 'sessions', path: join(ctx.paths.claude, 'projects'), platform: 'none' },
        payload: { claudeProjects: projectDirs.length, multicaSeeds: seeds, multicaTasks: tasks },
        tags: ['sessions'],
      })
    );
    return { assets, relations: [], diagnostics: ctx.diagnostics };
  },
};

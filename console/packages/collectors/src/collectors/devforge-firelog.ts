import { join } from 'node:path';
import { readFile, stat } from 'node:fs/promises';
import { exists } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';

export interface FireEvent {
  ts: string;
  event: string;
  agent?: string;
  rules?: string;
  fired?: string;
  action?: string;
  raw: string;
}

export function parseFirelogLine(line: string): FireEvent | null {
  const m = line.match(/^\[([^\]]+)\]\s*\[([^\]]+)\]\s*(.*)$/);
  if (!m) return null;
  const rest = m[3];
  const pick = (key: string) => rest.match(new RegExp(`\\b${key}=([^ ]+)`))?.[1];
  return {
    ts: m[1],
    event: pick('event') ?? m[2],
    agent: pick('agent'),
    rules: pick('rules'),
    fired: pick('fired'),
    action: pick('action'),
    raw: line.slice(0, 400),
  };
}

async function tail(path: string, maxBytes: number, maxLines: number): Promise<string[]> {
  try {
    const st = await stat(path);
    const fh = await import('node:fs/promises').then((m) => m.open(path, 'r'));
    try {
      const start = Math.max(0, st.size - maxBytes);
      const buf = Buffer.alloc(st.size - start);
      await fh.read(buf, 0, buf.length, start);
      return buf.toString('utf8').split('\n').filter(Boolean).slice(-maxLines);
    } finally {
      await fh.close();
    }
  } catch {
    return [];
  }
}

export const devforgeFirelogCollector: Collector = {
  name: 'devforge-firelog',
  mode: 'interval',
  intervalMs: 5000,
  async collect(ctx: CollectContext) {
    const logs: Array<{ repo: string; path: string }> = [
      { repo: '(global)', path: join(ctx.paths.claude, 'hook-fire.log') },
      { repo: 'dev-forge', path: join(ctx.paths.devforge, '.claude', 'hook-fire.log') },
    ];
    // 已知项目的 firelog（复用 workspace 注册表 + 常见 worktree）
    for (const ws of ctx.config.workspaces) {
      for (const p of ws.projects ?? []) logs.push({ repo: p.path.split('/').pop() ?? p.path, path: join(p.path, '.claude', 'hook-fire.log') });
    }

    const events: FireEvent[] = [];
    for (const { repo, path } of logs) {
      if (!(await exists(path))) continue;
      for (const line of await tail(path, 512 * 1024, 120)) {
        const ev = parseFirelogLine(line);
        if (ev) {
          events.push({ ...ev, raw: `[${repo}] ${ev.raw}` });
        }
      }
    }
    events.sort((a, b) => (a.ts < b.ts ? 1 : -1));
    const top = events.slice(0, 200);

    const denyCount = top.filter((e) => e.action === 'deny').length;
    const globalSize = await stat(logs[0].path).then((s) => s.size).catch(() => 0);

    const a = asset({
      id: 'custom:activity-feed',
      kind: 'custom',
      name: '最近活动（hook firelog）',
      summary: `${top.length} 条 · deny ${denyCount}`,
      attach: { level: 'user' },
      enforcement: 'derived',
      // 活动流是 hook 运行时日志聚合（dev-forge 工具链产物），不隶属单一平台
      platforms: [],
      source: { collector: 'devforge-firelog', path: logs[0].path, platform: 'none' },
      payload: { events: top, denyCount, globalLogBytes: globalSize },
      tags: ['activity', 'firelog'],
    });
    void readFile;
    return { assets: [a], relations: [], diagnostics: ctx.diagnostics };
  },
};

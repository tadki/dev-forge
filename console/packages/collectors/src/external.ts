import { join } from 'node:path';
import { stat, access, constants } from 'node:fs/promises';
import { validateCollection, type Collection } from '@forge/schema';
import type { Collector } from './types.js';

async function isExecutable(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** 扫描目录里的可执行文件，每个包装成一个 Collector（stdout = 契约 JSON；非 0 退出=失败；30s 超时） */
export async function loadExternalCollectors(dir: string): Promise<Collector[]> {
  const st = await stat(dir).catch(() => null);
  if (!st?.isDirectory()) return [];
  const { readdir } = await import('node:fs/promises');
  const files = (await readdir(dir)).filter((f) => !f.startsWith('.') && f !== 'README.md');
  const out: Collector[] = [];
  for (const f of files) {
    const p = join(dir, f);
    if (!(await isExecutable(p))) continue;
    const name = `external:${f}`;
    out.push({
      name,
      mode: 'interval',
      intervalMs: 120_000,
      async collect(ctx) {
        const r = await ctx.exec(p, [], 30_000);
        if (!r.ok) throw new Error(`external collector exited non-zero: ${r.stderr.slice(0, 200)}`);
        const parsed = JSON.parse(r.stdout) as Collection;
        const validated = validateCollection(parsed);
        return { assets: validated.assets, relations: validated.relations, diagnostics: validated.diagnostics };
      },
    });
  }
  return out;
}

import { join } from 'node:path';
import { listDir, readJson } from '../util.js';
import { validateCollection, type Collection } from '@forge/schema';
import type { Collector } from '../types.js';

/** E2E/测试用：从目录读取 *.json（每份一个契约 Collection）原样吐出 */
export function fixtureCollector(dir: string): Collector {
  return {
    name: 'fixture',
    mode: 'on-request',
    async collect() {
      const collections: Collection[] = [];
      for (const f of (await listDir(dir)).filter((x) => x.endsWith('.json'))) {
        const raw = await readJson<unknown>(join(dir, f));
        if (raw === null) continue;
        collections.push(validateCollection(raw));
      }
      const assets = collections.flatMap((c) => c.assets);
      const relations = collections.flatMap((c) => c.relations);
      const diagnostics = collections.flatMap((c) => c.diagnostics);
      return { assets, relations, diagnostics };
    },
  };
}

import type { Asset } from '@forge/schema';
import { join } from 'node:path';
import { listDir, readText, sha256 } from '../util.js';
import { asset, type Collector } from '../types.js';

const ENV_NAME = /\b([A-Z][A-Z0-9_]{4,})\b/g;

export const devforgeAdaptersCollector: Collector = {
  name: 'devforge-adapters',
  mode: 'watch',
  watchPaths: (ctx) => [join(ctx.paths.devforge, 'adapters')],
  async collect(ctx) {
    const assets: Asset[] = [];
    const dir = join(ctx.paths.devforge, 'adapters');
    for (const f of (await listDir(dir)).filter((x) => /\.(sh|py|js)$/.test(x))) {
      const p = join(dir, f);
      const md = (await readText(p)) ?? '';
      const purpose = md.match(/^(#\|\/\/).*/m)?.[0]?.replace(/^(#|\/\/)+\s*/, '') ?? '';
      const envNames = [...new Set((md.match(ENV_NAME) ?? []).filter((n) => !['UTF-8', 'PATH', 'SHELL'].includes(n)))].slice(0, 12);
      assets.push(
        asset({
          id: `adapter:${f}`,
          kind: 'adapter',
          name: f,
          summary: purpose.slice(0, 120),
          attach: { level: 'user' },
          enforcement: 'derived',
          platforms: ['claude-code'],
          source: { collector: 'devforge-adapters', path: p, sha256: sha256(md) },
          payload: { envContract: envNames, lines: md.split('\n').length },
          tags: ['adapter', 'devforge'],
        })
      );
    }
    return { assets, relations: [], diagnostics: ctx.diagnostics };
  },
};

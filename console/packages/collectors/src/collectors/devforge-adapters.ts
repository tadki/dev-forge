import type { Asset } from '@forge/schema';
import { join } from 'node:path';
import { listDir, readText, sha256 } from '../util.js';
import { asset, exemptSource, type Collector } from '../types.js';

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
          // 跨平台胶水脚本，无平台归属语义：显式豁免（详见 exemptSource）；个别脚本要归平台/换 kind
          // 时在 registry.d 声明（kind 覆盖 + platforms 声明自动解除豁免 + sha256 指纹核对，Owner 2026-11-18）
          platforms: [],
          source: exemptSource('devforge-adapters', p, { sha256: sha256(md) }),
          payload: { envContract: envNames, lines: md.split('\n').length, content: md },
          tags: ['adapter', 'devforge'],
        })
      );
    }
    return { assets, relations: [], diagnostics: ctx.diagnostics };
  },
};

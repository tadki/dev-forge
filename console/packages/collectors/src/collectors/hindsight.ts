import type { Asset } from '@forge/schema';
import { readJson } from '../util.js';
import { asset, type Collector } from '../types.js';
import { redactObject } from '../redact.js';

export const hindsightCollector: Collector = {
  name: 'hindsight',
  mode: 'interval',
  intervalMs: 120_000,
  async collect(ctx) {
    const assets: Asset[] = [];
    const diagnostics = ctx.diagnostics;
    const cfg = await readJson<Record<string, unknown>>(ctx.config.hindsight.configPath);
    let apiOk: boolean | null = null;
    let apiStatus = '';
    if (ctx.config.hindsight.probe) {
      try {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 3000);
        const res = await fetch(`${ctx.config.hindsight.apiBase}/health`, { signal: ctrl.signal }).catch(() => null);
        clearTimeout(timer);
        apiOk = res !== null && res.ok;
        apiStatus = res ? `${res.status}` : 'unreachable';
      } catch {
        apiOk = false;
        apiStatus = 'error';
      }
    }
    assets.push(
      asset({
        id: 'custom:hindsight',
        kind: 'custom',
        name: 'Hindsight 记忆服务',
        summary: `API ${apiOk === null ? '未探测' : apiOk ? 'OK' : `异常(${apiStatus})`} · config ${cfg ? '有' : '无'}`,
        attach: { level: 'user' },
        enforcement: 'derived',
        platforms: ['claude-code'],
        source: { collector: 'hindsight', path: ctx.config.hindsight.configPath },
        payload: {
          config: cfg ? redactObject(cfg) : null,
          apiBase: ctx.config.hindsight.apiBase,
          apiOk,
          apiStatus,
        },
        tags: ['hindsight', 'memory', ...(apiOk === false ? ['alert'] : [])],
      })
    );
    if (apiOk === false) diagnostics.push({ level: 'warn', message: `hindsight API 不可达：${apiStatus}` });
    return { assets, relations: [], diagnostics };
  },
};

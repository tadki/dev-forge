import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { exists, listDir, readJson, readText } from '../util.js';
import { asset, type Collector } from '../types.js';

export const devforgeLaunchCollector: Collector = {
  name: 'devforge-launch',
  mode: 'watch',
  watchPaths: (ctx) => [join(ctx.paths.devforge, 'repo-sync'), join(ctx.paths.devforge, 'launch')],
  async collect(ctx) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];

    const reposD = join(ctx.paths.devforge, 'repo-sync', 'repos.d');
    for (const f of (await listDir(reposD)).filter((x) => x.endsWith('.json'))) {
      const cfg = await readJson<Record<string, unknown>>(join(reposD, f));
      if (!cfg) continue;
      const name = String(cfg.name ?? f.replace(/\.json$/, ''));
      const disabled = cfg.enabled === false;
      // 停用优先于 pid：Owner 主动关闭是中性状态，残留进程也不得把它改回 active/dead。
      let active = disabled ? 'disabled' : 'unknown';
      const pidFile = String(cfg.pid_file ?? '');
      if (!disabled && pidFile) {
        // pid 文件缺失 = 守护未运行（退出时自清理）→ dead；字段缺失才算 unknown
        active = 'dead';
        const pidText = await readText(pidFile);
        const pid = Number((pidText ?? '').trim());
        if (pid > 0 && (await exists(`/proc/${pid}`))) active = 'active';
      }
      const trigger = disabled ? '已手动停用（enabled=false）' : '随 toolchain-start-all 启动';
      assets.push(
        asset({
          id: `service:repo-sync-${name}`,
          kind: 'service',
          name: `repo-sync · ${name}`,
          summary: `${String(cfg.repo_path ?? '')} @ ${String(cfg.branch ?? '')}`,
          attach: { level: 'project', ref: String(cfg.repo_path ?? '') },
          enforcement: 'enforced',
          payload: { daemon: 'repo_sync_daemon.py', config: cfg, logDir: cfg.log_dir, active, trigger },
          source: { collector: 'devforge-launch', path: join(reposD, f) },
          tags: ['repo-sync', 'devforge'],
        })
      );
      relations.push({ from: `project:${name}`, to: `service:repo-sync-${name}`, type: 'references' });
    }

    const envFile = join(ctx.paths.home, '.config', 'dev-forge', 'toolchain.env');
    const env = await readText(envFile);
    if (env !== null) {
      assets.push(
        asset({
          id: 'env:toolchain-env',
          kind: 'env',
          name: '启动链 env（toolchain.env）',
          summary: env.split('\n').filter((l) => l.includes('=')).map((l) => l.split('=')[0]).join(' · '),
          attach: { level: 'user' },
          enforcement: 'enforced',
          payload: { values: Object.fromEntries(env.split('\n').filter((l) => l.includes('=')).map((l) => [l.split('=')[0], l.split('=').slice(1).join('=')])) },
          source: { collector: 'devforge-launch', path: envFile },
          tags: ['launch', 'devforge'],
        })
      );
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};

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
      let active = 'unknown';
      const pidFile = String(cfg.pid_file ?? '');
      if (pidFile) {
        const pidText = await readText(pidFile);
        const pid = Number((pidText ?? '').trim());
        if (pid > 0) {
          const alive = await exists(`/proc/${pid}`);
          active = alive ? 'active' : 'dead';
        }
      }
      assets.push(
        asset({
          id: `service:repo-sync-${name}`,
          kind: 'service',
          name: `repo-sync · ${name}`,
          summary: `${String(cfg.repo_path ?? '')} @ ${String(cfg.branch ?? '')}`,
          attach: { level: 'project', ref: String(cfg.repo_path ?? '') },
          enforcement: 'enforced',
          payload: { daemon: 'repo_sync_daemon.py', config: cfg, logDir: cfg.log_dir, active, trigger: '随 toolchain-start-all 启动' },
          source: { collector: 'devforge-launch', path: join(reposD, f) },
          tags: ['repo-sync', 'devforge'],
        })
      );
      relations.push({ from: `project:${name}`, to: `service:repo-sync-${name}`, type: 'references' });
    }

    const unitPath = join(ctx.paths.devforge, 'launch', 'systemd', 'toolchain-start-all.service');
    if (await exists(unitPath)) {
      const unit = (await readText(unitPath)) ?? '';
      assets.push(
        asset({
          id: 'service:toolchain-start-all',
          kind: 'service',
          name: 'toolchain-start-all（启动链根）',
          summary: 'repo-sync ×N → multica daemon 前台 exec',
          attach: { level: 'user' },
          enforcement: 'enforced',
          payload: {
            unit: unit.slice(0, 3000),
            envFile: unit.match(/EnvironmentFile=(.+)/)?.[1]?.trim(),
            execStart: unit.match(/ExecStart=(.+)/)?.[1]?.trim(),
          },
          source: { collector: 'devforge-launch', path: unitPath },
          tags: ['systemd', 'launch', 'devforge'],
        })
      );
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

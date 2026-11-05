import { createServer } from 'node:http';
import { buildReconcileReport, execCapture } from '@forge/collectors';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { watch } from 'chokidar';
import { loadConfig } from './engine.js';
import { Engine } from './engine.js';
import { createHandler } from './app.js';
import { createRepoSyncAction, DEFAULT_START_TIMEOUT_MS, DEFAULT_STOP_TIMEOUT_MS } from './repo-sync-action.js';
import { executeReconcileAction } from './reconcile-action.js';
import { SSEBus } from './sse.js';

const consoleRoot = join(import.meta.dirname, '..', '..', '..');
const configPath = process.env.FORGE_CONSOLE_CONFIG ?? join(consoleRoot, 'console.config.yaml');
const config = await loadConfig(configPath);
const configRef = { current: config };

const token = process.env.FORGE_CONSOLE_TOKEN ?? null;
const port = Number(process.env.FORGE_CONSOLE_PORT ?? 7310);
const bind = process.env.FORGE_CONSOLE_BIND ?? '0.0.0.0';
const staticDir = join(consoleRoot, 'apps', 'web', 'dist');
const hasStatic = existsSync(join(staticDir, 'index.html'));

const sse = new SSEBus();
const engine = new Engine({ config, sse, watchEnabled: process.env.FORGE_CONSOLE_WATCH !== 'off' });
const dryActions = process.env.FORGE_CONSOLE_DRY_ACTIONS === '1';

function timeoutFromEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

const repoSyncAction = createRepoSyncAction({
  devforge: config.devforge,
  exec: execCapture,
  startTimeoutMs: timeoutFromEnv('FORGE_REPO_SYNC_START_TIMEOUT_MS', DEFAULT_START_TIMEOUT_MS),
  stopTimeoutMs: timeoutFromEnv('FORGE_REPO_SYNC_STOP_TIMEOUT_MS', DEFAULT_STOP_TIMEOUT_MS),
});
const handler = createHandler({
  getState: () => engine.state,
  token,
  sse,
  workspaces: () => configRef.current.workspaces,
  staticDir: hasStatic ? staticDir : undefined,
  pushAssets: (assets, collector) => engine.pushAssets(assets, collector),
  serviceAction: dryActions
    ? async (unit, action) => ({ ok: true, output: `[dry-run] ${action} ${unit}` })
    : async (unit, action) => {
        // repo-sync：enabled 门控；自动命名 oneshot 越沙箱后由 nohup/pid_file 管理生命周期。
        const rs = unit.match(/^repo-sync-(.+)$/);
        if (rs) {
          return repoSyncAction(rs[1], action);
        }
        const r = await execCapture('systemctl', ['--user', action, unit], 20_000);
        return { ok: r.ok && (!r.stdout || !/failed/i.test(r.stdout)), output: `${r.stdout}${r.stderr}`.slice(0, 400) };
      },
  onAfterAction: () => void engine.collectNow(),
  getReconcileReport: () =>
    engine.state.reconcile ??
    buildReconcileReport(engine.state, engine.getRegistryEntries(), new Date(), {
      store: engine.getStoreRecords(),
      platforms: engine.getPlatforms(),
    }),
  reconcileAction: async (key, actionId) => {
    // 对账项按当前 state 重算，步骤完全由服务端生成；客户端只提交 key + actionId + confirm
    const item = engine.findReconcileItem(key);
    if (!item) return { status: 'gone' as const, ok: false, output: '' };
    const result = await executeReconcileAction(item, actionId, engine.state, {
      exec: execCapture,
      dryRun: dryActions,
      storeDir: engine.getStoreDir() || undefined,
      storeRecords: engine.getStoreRecords(),
    });
    return { status: result.status, ok: result.ok, output: result.output };
  },
});

await engine.start();

// console.config.yaml 热重载：注册表变更无需重启进程（编辑器原子写会产生连续事件，debounce 800ms）
let cfgTimer: ReturnType<typeof setTimeout> | null = null;
const cfgWatch = watch(configPath, { ignoreInitial: true, awaitWriteFinish: { stabilityThreshold: 300, pollInterval: 100 } });
cfgWatch.on('all', () => {
  if (cfgTimer) clearTimeout(cfgTimer);
  cfgTimer = setTimeout(() => {
    void (async () => {
      try {
        const fresh = await loadConfig(configPath);
        configRef.current = fresh;
        await engine.updateConfig(fresh);
        console.error(`[config] 热重载完成：${configPath}`);
      } catch (e) {
        console.error(`[config] 热重载失败（保留旧配置）：${String(e).slice(0, 300)}`);
      }
    })();
  }, 800);
});

const server = createServer((req, res) => void handler(req, res));
server.listen(port, bind, () => {
  console.error(`forge-console listening on http://${bind}:${port} (static: ${hasStatic ? 'on' : 'off'}, token: ${token ? 'required' : 'OFF — local mode'}, actions: ${dryActions ? 'DRY-RUN' : 'live systemctl --user'})`);
});

const shutdown = () => {
  engine.stop();
  void cfgWatch.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

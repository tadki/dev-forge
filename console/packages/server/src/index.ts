import { createServer } from 'node:http';
import { execCapture } from '@forge/collectors';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { loadConfig } from './engine.js';
import { Engine } from './engine.js';
import { createHandler } from './app.js';
import { SSEBus } from './sse.js';

const consoleRoot = join(import.meta.dirname, '..', '..', '..');
const configPath = process.env.FORGE_CONSOLE_CONFIG ?? join(consoleRoot, 'console.config.yaml');
const config = await loadConfig(configPath);

const token = process.env.FORGE_CONSOLE_TOKEN ?? null;
const port = Number(process.env.FORGE_CONSOLE_PORT ?? 7310);
const bind = process.env.FORGE_CONSOLE_BIND ?? '0.0.0.0';
const staticDir = join(consoleRoot, 'apps', 'web', 'dist');
const hasStatic = existsSync(join(staticDir, 'index.html'));

const sse = new SSEBus();
const engine = new Engine({ config, sse, watchEnabled: process.env.FORGE_CONSOLE_WATCH !== 'off' });
const dryActions = process.env.FORGE_CONSOLE_DRY_ACTIONS === '1';

async function repoSyncAction(name: string, action: 'start' | 'stop' | 'restart'): Promise<{ ok: boolean; output: string }> {
  const devforge = config.devforge;
  const cfgPath = `${devforge}/repo-sync/repos.d/${name}.json`;
  const readPid = async (): Promise<number> => {
    const txt = (await execCapture('cat', [cfgPath.replace('repos.d/' + name + '.json', 'repos.d/' + name + '.json')], 1000), null);
    void txt;
    const cfgTxt = await execCapture('python3', ['-c', `import json;print(json.load(open('${cfgPath}')).get('pid_file',''))`], 5000);
    const pidFile = cfgTxt.stdout.trim();
    if (!pidFile) return 0;
    const pidTxt = await execCapture('cat', [pidFile], 3000);
    const pid = Number(pidTxt.stdout.trim());
    return Number.isFinite(pid) && pid > 0 ? pid : 0;
  };
  const stopOne = async (): Promise<{ ok: boolean; output: string }> => {
    const unitName = `repo-sync-${name}`;
    const sysStop = await execCapture('systemctl', ['--user', 'stop', unitName], 10_000);
    if (sysStop.ok) return { ok: true, output: `systemctl --user stop ${unitName}` };
    const pid = await readPid();
    if (pid > 0) {
      const k = await execCapture('kill', [String(pid)], 5000);
      if (k.ok) return { ok: true, output: `kill TERM ${pid}` };
    }
    // 兜底：ps 匹配
    const ps = await execCapture('bash', ['-lc', `pgrep -f "repo_sync_daemon.py --config .*repos.d/${name}.json"`], 5000);
    const pids = ps.stdout.split('\n').map((x) => Number(x.trim())).filter((x) => x > 0);
    for (const pid of pids) await execCapture('kill', [String(pid)], 5000);
    return { ok: true, output: `killed by pgrep: ${pids.join(',') || 'none'}` };
  };
  if (action === 'stop') return stopOne();
  if (action === 'restart') {
    const s = await stopOne();
    await execCapture('sleep', ['1'], 3000);
    const st = await repoSyncAction(name, 'start');
    return { ok: s.ok && st.ok, output: `${s.output}; ${st.output}` };
  }
  // start：临时单元不存在且进程不在时 systemd-run 拉起
  const unitName = `repo-sync-${name}`;
  const status = await execCapture('systemctl', ['--user', 'is-active', unitName], 5000);
  const pid = await readPid();
  const aliveByPid = pid > 0 && (await execCapture('test', ['-d', `/proc/${pid}`], 3000)).ok;
  if (status.stdout.trim() === 'active' || aliveByPid) {
    return { ok: true, output: `${unitName} 已在运行` };
  }
  const run = await execCapture(
    'systemd-run',
    ['--user', '--unit', unitName, '--collect', '--working-directory', `${devforge}/repo-sync`, '/usr/bin/python3', `${devforge}/repo-sync/repo_sync_daemon.py`, '--config', cfgPath],
    15_000
  );
  return { ok: run.ok, output: `${run.stdout}${run.stderr}`.slice(0, 400) };
}
const handler = createHandler({
  getState: () => engine.state,
  token,
  sse,
  workspaces: config.workspaces,
  staticDir: hasStatic ? staticDir : undefined,
  pushAssets: (assets, collector) => engine.pushAssets(assets, collector),
  serviceAction: dryActions
    ? async (unit, action) => ({ ok: true, output: `[dry-run] ${action} ${unit}` })
    : async (unit, action) => {
        // repo-sync-<name>：进程型守护（systemd-run --user 拉起为受管临时单元；stop 优先停单元否则按 pid）
        const rs = unit.match(/^repo-sync-(.+)$/);
        if (rs) {
          return repoSyncAction(rs[1], action);
        }
        const r = await execCapture('systemctl', ['--user', action, unit], 20_000);
        return { ok: r.ok && (!r.stdout || !/failed/i.test(r.stdout)), output: `${r.stdout}${r.stderr}`.slice(0, 400) };
      },
  onAfterAction: () => void engine.collectNow(),
});

await engine.start();
const server = createServer((req, res) => void handler(req, res));
server.listen(port, bind, () => {
  console.error(`forge-console listening on http://${bind}:${port} (static: ${hasStatic ? 'on' : 'off'}, token: ${token ? 'required' : 'OFF — local mode'}, actions: ${dryActions ? 'DRY-RUN' : 'live systemctl --user'})`);
});

const shutdown = () => {
  engine.stop();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

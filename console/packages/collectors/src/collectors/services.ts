import type { Asset, Relation } from '@forge/schema';
import { readText } from '../util.js';
import { asset, type Collector } from '../types.js';

interface UnitInfo {
  unit: string;
  active: string;
  sub: string;
  description: string;
}

const INTERESTING = /toolchain|grepai|multica|forge-console|repo-sync|hindsight/i;

export const servicesCollector: Collector = {
  name: 'services',
  mode: 'interval',
  intervalMs: 30_000,
  async collect(ctx) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    const diagnostics = ctx.diagnostics;

    const parseList = (out: string): UnitInfo[] =>
      out
        .split('\n')
        .map((l) => l.trim())
        .filter((l) => l.endsWith('.service') && !l.startsWith('unit'))
        .map((l) => {
          const [unit, load, active, sub, ...desc] = l.split(/\s+/);
          return { unit, active, sub, load, description: desc.join(' ') } as unknown as UnitInfo;
        });

    const userUnits = parseList((await ctx.exec('systemctl', ['--user', 'list-units', '--type=service', '--all', '--no-legend', '--no-pager'], 10_000)).stdout);
    const sysUnits = parseList((await ctx.exec('systemctl', ['list-units', '--type=service', '--all', '--no-legend', '--no-pager'], 10_000)).stdout);

    const all = [
      ...userUnits.filter((u) => INTERESTING.test(u.unit)).map((u) => ({ ...u, scope: 'user' })),
      ...sysUnits.filter((u) => INTERESTING.test(u.unit)).map((u) => ({ ...u, scope: 'system' })),
    ];

    // 进程树：systemctl 域内 ps
    const ps = (await ctx.exec('ps', ['-eo', 'pid,ppid,etime,args', '--no-headers'], 10_000)).stdout.split('\n').map((l: string) => l.trim()).filter(Boolean);
    const procs = ps.map((l: string) => {
      const m = l.match(/^(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
      return m ? { pid: Number(m[1]), ppid: Number(m[2]), up: m[3], args: m[4].slice(0, 200) } : null;
    }).filter(Boolean) as Array<{ pid: number; ppid: number; up: string; args: string }>;
    const childrenOf = (pid: number, depth = 3): Array<{ pid: number; up: string; args: string }> => {
      if (depth <= 0) return [];
      const kids = procs.filter((p) => p.ppid === pid).map((p) => ({ pid: p.pid, up: p.up, args: p.args }));
      for (const k of kids) kids.push(...childrenOf(k.pid, depth - 1));
      return kids.slice(0, 40);
    };

    for (const u of all) {
      const isUser = u.scope === 'user';
      const showArgs = [isUser ? '--user' : '', 'show', u.unit, '-p', 'ExecStart', '-p', 'EnvironmentFile', '-p', 'ExecMainPID', '-p', 'ActiveEnterTimestamp', '-p', 'Description', '--no-pager'].filter(Boolean);
      const show = (await ctx.exec('systemctl', showArgs, 10_000)).stdout;
      const prop = (k: string) => show.match(new RegExp(`^${k}=(.*)$`, 'm'))?.[1]?.trim();
      const enabled = (await ctx.exec('systemctl', [isUser ? '--user' : '', 'is-enabled', u.unit].filter(Boolean), 5000)).stdout.trim();
      const mainPid = Number(prop('ExecMainPID') ?? 0);
      const children = mainPid > 1 ? childrenOf(mainPid) : [];
      assets.push(
        asset({
          id: `service:systemd-${u.unit}`,
          kind: 'service',
          name: u.unit.replace(/\.service$/, ''),
          summary: `${u.active}/${u.sub} · ${enabled} · 子进程 ${children.length}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          enabled: enabled !== 'disabled',
          source: { collector: 'services', path: `systemd://${u.scope}/${u.unit}` },
          payload: {
            scope: u.scope,
            active: u.active,
            sub: u.sub,
            enabled,
            execStart: prop('ExecStart'),
            envFile: prop('EnvironmentFile'),
            mainPid: mainPid > 0 ? mainPid : undefined,
            since: prop('ActiveEnterTimestamp'),
            description: prop('Description') ?? u.description,
            children,
            trigger: u.scope === 'system' ? 'boot' : 'boot(user)',
          },
          tags: ['systemd', u.scope],
        })
      );
    }

    // grepai watch 用户单元若未列出（inactive）也登记
    if (!all.some((u) => u.unit.startsWith('grepai-watch'))) {
      assets.push(
        asset({
          id: 'service:systemd-grepai-watch.service',
          kind: 'service',
          name: 'grepai-watch（未发现运行单元）',
          summary: 'systemctl 列表中无活跃单元',
          attach: { level: 'user' },
          enforcement: 'enforced',
          enabled: false,
          source: { collector: 'services', path: 'systemd://user/grepai-watch.service' },
          payload: { note: 'not listed' },
          tags: ['systemd'],
        })
      );
    }

    // Windows 登录桥
    const bridges: Array<[string, string]> = [
      ['multica-daemon', '/mnt/c/Users/Jerry/multica-daemon.bat'],
      ['wsl-keepalive', '/mnt/c/Users/Jerry/wsl-keepalive.ps1'],
    ];
    for (const [name, p] of bridges) {
      const script = (await readText(p)) ?? (await readText(p.replace(/\.bat$/, '.ps1')));
      assets.push(
        asset({
          id: `service:winbridge-${name}`,
          kind: 'service',
          name: `${name}（Windows 登录桥）`,
          summary: script ? script.split('\n').join(' ').slice(0, 120) : '脚本不存在',
          attach: { level: 'user' },
          enforcement: 'advisory',
          enabled: script !== null,
          platforms: ['claude-code'],
          source: { collector: 'services', path: p },
          payload: { trigger: 'windows-logon', script: script?.slice(0, 500), stale: name === 'multica-daemon' },
          tags: ['windows-bridge'],
        })
      );
    }
    return { assets, relations, diagnostics };
  },
};

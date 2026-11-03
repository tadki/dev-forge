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

    // systemctl list-units 每行 = UNIT LOAD ACTIVE SUB DESCRIPTION（描述在行尾，
    // 不能对整行 endsWith 单元后缀——历史 bug：永远解析不到任何单元）
    const parseList = (out: string): UnitInfo[] =>
      out
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => {
          const parts = l.split(/\s+/);
          return { unit: parts[0] ?? '', load: parts[1] ?? '', active: parts[2] ?? '', sub: parts[3] ?? '', description: parts.slice(4).join(' ') } as unknown as UnitInfo;
        })
        .filter((u) => u.unit.endsWith('.service'));

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
      const seen = new Set<number>();
      const children = (mainPid > 1 ? childrenOf(mainPid) : []).filter((c) => (seen.has(c.pid) ? false : (seen.add(c.pid), true)));
      const triggerHuman = enabled === 'enabled'
        ? (isUser ? '用户级开机自启' : '系统开机自启')
        : enabled === 'static' ? 'static（被依赖时启动）'
        : enabled === 'disabled' ? '手动启动'
        : `enabled=${enabled || '?'}`;
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
            trigger: triggerHuman,
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

    // multica daemon 进程行（third-party 软件进程；toolchain-start-all 的前台子进程）
    {
      const psAll = await ctx.exec('ps', ['-eo', 'args', '--no-headers'], 10_000);
      const daemonAlive = /multica daemon start/.test(psAll.stdout);
      assets.push(
        asset({
          id: 'service:proc-multica-daemon',
          kind: 'service',
          name: 'multica daemon',
          summary: daemonAlive ? '进程在运行（toolchain-start-all 前台子进程）' : '进程未运行',
          attach: { level: 'user' },
          provenance: 'third-party',
          enforcement: 'enforced',
          enabled: true,
          payload: { active: daemonAlive ? 'active' : 'dead', trigger: '随 toolchain-start-all（前台 exec）', process: 'multica daemon start' },
          source: { collector: 'services', path: 'proc://multica-daemon' },
          tags: ['multica', 'process'],
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
          name: `${name} 桥（legacy）`,
          summary: script ? script.split('\n').join(' ').slice(0, 120) : '脚本不存在',
          attach: { level: 'user' },
          provenance: 'third-party',
          enforcement: 'advisory',
          enabled: script !== null,
          platforms: ['claude-code'],
          source: { collector: 'services', path: p },
          payload: { trigger: 'windows-logon', script: script?.slice(0, 500), active: 'legacy', stale: true },
          tags: ['windows-bridge'],
        })
      );
    }
    return { assets, relations, diagnostics };
  },
};

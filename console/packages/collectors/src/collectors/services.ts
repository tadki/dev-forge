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
          // 本机 systemd 运行时探针（伪协议源），不隶属任何 agent 平台 → 未适配桶
          platforms: [],
          enabled: enabled !== 'disabled',
          source: { collector: 'services', path: `systemd://${u.scope}/${u.unit}`, platform: 'none' },
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
          platforms: [],
          enabled: false,
          source: { collector: 'services', path: 'systemd://user/grepai-watch.service', platform: 'none' },
          payload: { note: 'not listed' },
          tags: ['systemd'],
        })
      );
    }

    // multica daemon 独立进程；toolchain 负责缺失补拉与驻留监督。
    {
      const psAll = await ctx.exec('ps', ['-eo', 'args', '--no-headers'], 10_000);
      const daemonAlive = /multica daemon start/.test(psAll.stdout);
      const lifecycle = '独立 daemon；toolchain 缺失补拉并驻留监督';
      assets.push(
        asset({
          id: 'service:proc-multica-daemon',
          kind: 'service',
          name: 'multica daemon',
          summary: daemonAlive ? `进程在运行（${lifecycle}）` : `进程未运行（${lifecycle}）`,
          attach: { level: 'user' },
          provenance: 'third-party',
          enforcement: 'enforced',
          platforms: [],
          enabled: true,
          payload: { active: daemonAlive ? 'active' : 'dead', trigger: 'toolchain-start-all 驻留监督，daemon 缺失时补拉', process: 'multica daemon start' },
          source: { collector: 'services', path: 'proc://multica-daemon', platform: 'none' },
          tags: ['multica', 'process'],
        })
      );
    }

    // Windows 登录桥：状态机制化——实时查计划任务（schtasks），非手工标注
    // Running→active / Ready→enabled(待触发) / Disabled→legacy / 任务与脚本均不存在→不发行
    const SCHED = '/mnt/c/Windows/System32/schtasks.exe';
    const bridges: Array<{ task: string; script: string; label: string }> = [
      { task: 'multica-daemon', script: '/mnt/c/Users/Jerry/multica-daemon.bat', label: 'multica-daemon' },
      { task: 'wsl-keepalive', script: '/mnt/c/Users/Jerry/wsl-keepalive.ps1', label: 'wsl-keepalive' },
    ];
    for (const b of bridges) {
      const q = await ctx.exec(SCHED, ['/query', '/tn', b.task], 8000);
      const taskExists = q.ok || !/cannot find|does not exist/i.test(q.stderr);
      if (!q.ok && !taskExists) {
        // 任务不存在：脚本也删了才彻底消失，否则发 dead 行提醒残留
        const scriptOnly = await readText(b.script);
        if (scriptOnly === null) continue;
        assets.push(asset({
          id: `service:winbridge-${b.label}`,
          kind: 'service',
          name: `${b.label} 桥（残留脚本）`,
          summary: '计划任务已删除，脚本残留',
          attach: { level: 'user' },
          provenance: 'third-party',
          enforcement: 'advisory',
          platforms: [],
          enabled: false,
          payload: { trigger: 'windows-logon', active: 'dead', stale: true },
          source: { collector: 'services', path: b.script, platform: 'none' },
          tags: ['windows-bridge'],
        }));
        continue;
      }
      const statusWord = (q.stdout.match(/\b(Running|Ready|Disabled)\b/) ?? [])[1] ?? 'unknown';
      const activeMap: Record<string, string> = { Running: 'active', Ready: 'enabled', Disabled: 'legacy' };
      const script = await readText(b.script);
      assets.push(
        asset({
          id: `service:winbridge-${b.label}`,
          kind: 'service',
          name: `${b.label} 桥（windows 登录任务 · ${statusWord}）`,
          summary: script ? script.split('\n').join(' ').slice(0, 120) : '脚本不存在（任务仍在）',
          attach: { level: 'user' },
          provenance: 'third-party',
          enforcement: 'advisory',
          platforms: [],
          enabled: statusWord !== 'Disabled',
          payload: { trigger: 'windows-logon', script: script?.slice(0, 500), active: activeMap[statusWord] ?? 'unknown', taskStatus: statusWord, stale: statusWord === 'Disabled' },
          source: { collector: 'services', path: `schtasks://${b.task}`, platform: 'none' },
          tags: ['windows-bridge'],
        })
      );
    }

    return { assets, relations, diagnostics };
  },
};

import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parse } from 'yaml';

export interface WorkspaceDef {
  id: string;
  name: string;
  projects: string[];
  residents?: string[];
  services?: string[];
}

export interface MulticaConfig {
  cli: string;
  timeoutMs: number;
  maxTasksPerAgent: number;
  enabled: boolean;
}

export interface HindsightConfig {
  configPath: string;
  apiBase: string;
  probe: boolean;
}

export interface ReportsConfig {
  toolchainLatest: string;
  archPatrol: string;
}

export interface ConsoleConfig {
  home: string;
  devforge: string;
  workspaces: WorkspaceDef[];
  multica: MulticaConfig;
  hindsight: HindsightConfig;
  reports: ReportsConfig;
  enabledCollectors?: string[];
  snapshotPath?: string;
  /** E2E/演示：只跑 fixture 采集器（目录内 *.json = 契约 Collection） */
  fixturesDir?: string;
  /** 自建资产声明目录（registry.d/*.yaml，声明即归属 + meta 盖戳）；默认 <devforge>/console/registry.d */
  registryDir?: string;
}

export function defaultConfig(root?: { home?: string; devforge?: string }): ConsoleConfig {
  const home = root?.home ?? homedir();
  const devforge = root?.devforge ?? join(home, 'tools', 'dev-forge');
  return {
    home,
    devforge,
    workspaces: [],
    multica: { cli: 'multica', timeoutMs: 15000, maxTasksPerAgent: 5, enabled: true },
    hindsight: {
      configPath: join(home, '.hindsight', 'coding-agent.json'),
      apiBase: 'http://192.168.1.210:13581',
      probe: true,
    },
    reports: {
      toolchainLatest: join(home, '.multica', 'toolchain-reports', 'latest.json'),
      archPatrol: join(home, '.multica', 'arch-patrol', 'last_report.json'),
    },
  };
}

export function resolveTilde(p: string, home: string): string {
  if (p === '~') return home;
  if (p.startsWith('~/')) return join(home, p.slice(2));
  return p;
}

export async function loadConfig(path: string, overrides?: { home?: string; devforge?: string }): Promise<ConsoleConfig> {
  const base = defaultConfig(overrides);
  let text: string | null = null;
  try {
    text = await readFile(path, 'utf8');
  } catch {
    return base;
  }
  let raw: Record<string, unknown>;
  try {
    raw = parse(text) as Record<string, unknown>;
  } catch (e) {
    throw new Error(`console config parse error at ${path}: ${String(e)}`);
  }
  const home = typeof raw.home === 'string' ? resolveTilde(raw.home, base.home) : base.home;
  const cfg: ConsoleConfig = { ...base, ...raw, home } as ConsoleConfig;
  cfg.multica = { ...base.multica, ...((raw.multica as object) ?? {}) };
  cfg.hindsight = {
    ...base.hindsight,
    ...((raw.hindsight as object) ?? {}),
    configPath: resolveTilde(
      (raw.hindsight as { configPath?: string } | undefined)?.configPath ?? base.hindsight.configPath,
      home
    ),
  };
  cfg.reports = {
    ...base.reports,
    ...((raw.reports as object) ?? {}),
    toolchainLatest: resolveTilde(
      (raw.reports as { toolchainLatest?: string } | undefined)?.toolchainLatest ?? base.reports.toolchainLatest,
      home
    ),
    archPatrol: resolveTilde(
      (raw.reports as { archPatrol?: string } | undefined)?.archPatrol ?? base.reports.archPatrol,
      home
    ),
  };
  for (const ws of cfg.workspaces) {
    ws.projects = (ws.projects ?? []).map((p) => resolveTilde(p, home));
  }
  return cfg;
}

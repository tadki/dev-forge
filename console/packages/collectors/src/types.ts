import type { Asset, Collection, Diagnostic } from '@forge/schema';
import type { ConsoleConfig } from './config.js';

export type CollectorMode = 'watch' | 'interval' | 'on-request';

export interface CollectContext {
  config: ConsoleConfig;
  paths: {
    home: string;
    devforge: string;
    claude: string;
    multicaWorkspaces: string;
  };
  now: Date;
  /** 只读探测外部命令（multica CLI 等）— 测试时可注入假实现 */
  exec: (cmd: string, args: string[], timeoutMs: number) => Promise<{ ok: boolean; stdout: string; stderr: string }>;
  diagnostics: Diagnostic[];
}

export interface Collector {
  name: string;
  mode: CollectorMode;
  /** interval 模式的刷新间隔 */
  intervalMs?: number;
  /** watch 模式：值得监听的路径 */
  watchPaths?: (ctx: CollectContext) => string[];
  collect(ctx: CollectContext): Promise<Omit<Collection, 'collector' | 'collectedAt'>>;
}

export function makeContext(
  config: ConsoleConfig,
  overrides?: Partial<Pick<CollectContext, 'exec' | 'now'>>
): CollectContext {
  return {
    config,
    paths: {
      home: config.home,
      devforge: config.devforge,
      claude: `${config.home}/.claude`,
      multicaWorkspaces: `${config.home}/multica_workspaces`,
    },
    now: overrides?.now ?? new Date(),
    exec:
      overrides?.exec ??
      (async (cmd, args, timeoutMs) => {
        const { execCapture } = await import('./util.js');
        return execCapture(cmd, args, timeoutMs);
      }),
    diagnostics: [],
  };
}

export function asset(partial: {
  id: string;
  kind: Asset['kind'];
  name: string;
  source: Asset['source'];
  summary?: string;
  attach: Asset['attach'];
  applies?: Asset['applies'];
  enforcement?: Asset['enforcement'];
  platforms?: string[];
  provenance?: Asset['provenance'];
  tags?: string[];
  enabled?: boolean;
  owner?: string;
  payload?: Record<string, unknown>;
}): Asset {
  return {
    id: partial.id,
    kind: partial.kind,
    name: partial.name,
    summary: partial.summary ?? '',
    attach: partial.attach,
    applies: partial.applies,
    enforcement: partial.enforcement ?? 'derived',
    platforms: partial.platforms ?? ['claude-code'],
    provenance: partial.provenance ?? 'first-party',
    tags: partial.tags ?? [],
    enabled: partial.enabled ?? true,
    owner: partial.owner,
    source: partial.source,
    payload: partial.payload ?? {},
  };
}

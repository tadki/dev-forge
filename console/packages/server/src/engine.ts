import type { Asset, Collection } from '@forge/schema';
import {
  applyRegistryOverlay,
  builtinCollectors,
  loadRegistryEntries,
  computeDriftGroups,
  loadConfig,
  makeContext,
  mergeCollections,
  runCollectors,
  type ConsoleConfig,
  type Collector,
  type RegistryState,
} from '@forge/collectors';
import { fixtureCollector } from '@forge/collectors';
import { loadExternalCollectors } from '@forge/collectors';
import { watch } from 'chokidar';
import { join } from 'node:path';
import type { SSEBus } from './sse.js';

export interface EngineOptions {
  config: ConsoleConfig;
  sse: SSEBus;
  /** 测试注入：替换内置采集器 */
  collectorsOverride?: Collector[];
  watchEnabled?: boolean;
  intervalMs?: number;
}

export class Engine {
  state: RegistryState = { assets: [], relations: [], diagnostics: [], driftGroups: [], collectorStatus: [], lastCollectedAt: '' };
  private collectors: Collector[];
  private timer?: ReturnType<typeof setInterval>;
  private watchers: Array<{ close: () => void }> = [];
  private running = false;
  private sse: SSEBus;
  private config: ConsoleConfig;
  private watchEnabled: boolean;
  private intervalMs: number;

  constructor(opts: EngineOptions) {
    this.config = opts.config;
    this.sse = opts.sse;
    this.watchEnabled = opts.watchEnabled ?? true;
    this.intervalMs = opts.intervalMs ?? 90_000;
    this.collectors = opts.collectorsOverride ?? this.resolveCollectors();
  }

  private resolveCollectors(): Collector[] {
    if (this.config.fixturesDir) {
      return [fixtureCollector(this.config.fixturesDir)];
    }
    const builtins = this.config.enabledCollectors
      ? builtinCollectors.filter((c) => this.config.enabledCollectors!.includes(c.name))
      : builtinCollectors;
    return builtins;
  }

  /** console/collectors.d/ 外部采集器（启动时扫一次；投放/删除后 restart 生效） */
  private async withExternal(collectors: Collector[]): Promise<Collector[]> {
    const dir = join(this.config.devforge, 'console', 'collectors.d');
    const external = await loadExternalCollectors(dir);
    return [...collectors, ...external];
  }

  async start(): Promise<void> {
    this.collectors = await this.withExternal(this.collectors);
    await this.collectNow();
    if (this.watchEnabled) this.setupWatchers();
    this.timer = setInterval(() => void this.collectNow(), this.intervalMs);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    for (const w of this.watchers) w.close();
    this.watchers = [];
  }

  pushAssets(assets: Asset[], collector: string): void {
    const collection: Collection = {
      collector,
      collectedAt: new Date().toISOString(),
      assets,
      relations: [],
      diagnostics: [],
    };
    const existing = this.state.assets.filter((a) => !assets.some((n) => n.id === a.id) && a.source.collector !== collector);
    const merged = mergeCollections([{ collector: 'base', collectedAt: '', assets: existing, relations: this.state.relations, diagnostics: [] }, collection]);
    this.state = {
      ...this.state,
      assets: merged.assets,
      relations: merged.relations,
      driftGroups: computeDriftGroups(merged.assets),
      lastCollectedAt: new Date().toISOString(),
    };
    this.sse.broadcast('registry', { reason: 'push', total: this.state.assets.length });
  }

  async collectNow(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      const ctx = makeContext(this.config);
      let state = await runCollectors(ctx, this.collectors);
      const registryDir = this.config.registryDir ?? join(this.config.devforge, 'console', 'registry.d');
      state = applyRegistryOverlay(state, await loadRegistryEntries(registryDir));
      // 保留 push 型自定义资产
      const pushed = this.state.assets.filter((a) => a.source.collector === 'push');
      if (pushed.length > 0) {
        const merged = mergeCollections([
          { collector: 'base', collectedAt: '', assets: state.assets, relations: state.relations, diagnostics: state.diagnostics },
          { collector: 'push', collectedAt: '', assets: pushed, relations: [], diagnostics: [] },
        ]);
        state.assets = merged.assets;
      }
      this.state = state;
      this.sse.broadcast('registry', {
        reason: 'collect',
        total: state.assets.length,
        drift: state.driftGroups.length,
        failed: state.collectorStatus.filter((s) => !s.ok).map((s) => s.name),
      });
    } finally {
      this.running = false;
    }
  }

  private setupWatchers(): void {
    const ctx = makeContext(this.config);
    const paths = new Set<string>();
    for (const c of this.collectors) {
      if (c.mode !== 'watch' || !c.watchPaths) continue;
      for (const p of c.watchPaths(ctx)) paths.add(p);
    }
    for (const p of paths) {
      const is9p = p.startsWith('/mnt/');
      const w = watch(p, {
        ignoreInitial: true,
        ignored: /node_modules|\.git(\/|$)|__pycache__|unified\/state|hook-fire\.log|\.log(\.\d+)?$/,
        usePolling: is9p,
        interval: is9p ? 4000 : undefined,
        depth: is9p ? 4 : 6,
      });
      let timer: ReturnType<typeof setTimeout> | null = null;
      w.on('all', () => {
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => void this.collectNow(), 3000);
      });
      this.watchers.push({ close: () => w.close() });
    }
  }
}

export { loadConfig, fixtureCollector };
